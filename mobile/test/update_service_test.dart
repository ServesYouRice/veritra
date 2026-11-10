import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/desktop/update_service.dart';

void main() {
  group('UpdateInfo', () {
    final validJson = <String, Object?>{
      'version': '0.2.0',
      'build': 2,
      'platform': 'windows',
      'arch': 'x64',
      'issued_at': '2026-11-10T12:00:00Z',
      'expires_at': '2026-11-20T12:00:00Z',
      'url':
          'https://github.com/ServesYouRice/veritra/releases/download/v0.2.0/Veritra-Setup-0.2.0-x64.exe',
      'sha256': 'a' * 64,
      'notes': 'Security updates and performance improvements.',
    };

    test('parses valid update json', () {
      final info = UpdateInfo.fromJson(validJson);
      expect(info.version, '0.2.0');
      expect(info.build, 2);
      expect(info.platform, 'windows');
      expect(info.arch, 'x64');
      expect(info.issuedAt, DateTime.utc(2026, 11, 10, 12));
      expect(info.expiresAt, DateTime.utc(2026, 11, 20, 12));
      expect(info.url, startsWith('https://'));
      expect(info.sha256, 'a' * 64);
      expect(info.notes, 'Security updates and performance improvements.');
    });

    test('rejects non-https url', () {
      final invalid = Map<String, Object?>.from(validJson)
        ..['url'] = 'http://example.com/installer.exe';
      expect(() => UpdateInfo.fromJson(invalid), throwsFormatException);
    });

    test('rejects invalid sha256', () {
      final invalid = Map<String, Object?>.from(validJson)
        ..['sha256'] = 'not-a-hash';
      expect(() => UpdateInfo.fromJson(invalid), throwsFormatException);
    });

    test('rejects invalid build number', () {
      final invalid = Map<String, Object?>.from(validJson)..['build'] = 0;
      expect(() => UpdateInfo.fromJson(invalid), throwsFormatException);
    });

    test('expiration check', () {
      final info = UpdateInfo.fromJson(validJson);
      expect(info.isExpired(now: DateTime.utc(2026, 11, 15)), isFalse);
      expect(info.isExpired(now: DateTime.utc(2026, 11, 25)), isTrue);
    });

    test('platform and architecture matching', () {
      final info = UpdateInfo.fromJson(validJson);
      expect(info.matchesPlatform('windows'), isTrue);
      expect(info.matchesPlatform('WINDOWS'), isTrue);
      expect(info.matchesPlatform('linux'), isFalse);

      expect(info.matchesArch('x64'), isTrue);
      expect(info.matchesArch('arm64'), isFalse);
    });

    test('build number monotonicity (downgrade prevention)', () {
      final info = UpdateInfo.fromJson(validJson); // build 2
      expect(info.isNewer(1), isTrue);
      expect(info.isNewer(2), isFalse);
      expect(info.isNewer(3), isFalse);
    });
  });

  group('UpdateSettings', () {
    test('is ON by default', () async {
      final store = MemoryUpdateSettingsStore();
      final settings = UpdateSettings(store);
      expect(settings.autoCheckEnabled, isTrue);

      await settings.load();
      expect(settings.autoCheckEnabled, isTrue);
    });

    test('can be turned off and persisted', () async {
      final store = MemoryUpdateSettingsStore();
      final settings = UpdateSettings(store);

      var notified = false;
      settings.addListener(() => notified = true);

      await settings.setAutoCheckEnabled(false);
      expect(settings.autoCheckEnabled, isFalse);
      expect(store.autoCheck, isFalse);
      expect(notified, isTrue);

      // Reloading from store keeps it off
      final reloaded = UpdateSettings(store);
      await reloaded.load();
      expect(reloaded.autoCheckEnabled, isFalse);
    });
  });

  group('UpdateService', () {
    final now = DateTime.utc(2026, 11, 10, 15);
    final updatePayload = utf8.encode(jsonEncode(<String, Object?>{
      'version': '0.2.0',
      'build': 2,
      'platform': 'windows',
      'arch': 'x64',
      'issued_at': '2026-11-10T12:00:00Z',
      'expires_at': '2026-11-20T12:00:00Z',
      'url':
          'https://github.com/ServesYouRice/veritra/releases/download/v0.2.0/Veritra-Setup-0.2.0-x64.exe',
      'sha256': 'b' * 64,
      'notes': 'Version 0.2.0 notes',
    }));

    test('skips checking when auto-check is disabled unless forced', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(false));
      await settings.load();
      final client =
          MemoryUpdateClient(responseBytes: Uint8List.fromList(updatePayload));
      final service = UpdateService(
        settings: settings,
        client: client,
        currentBuild: 1,
        now: () => now,
      );

      final status = await service.checkForUpdatesIfEnabled();
      expect(status.kind, UpdateStatusKind.disabled);

      // Force check proceeds even when disabled
      final forced = await service.checkForUpdates(force: true);
      expect(forced.kind, UpdateStatusKind.updateAvailable);
      expect(forced.update?.version, '0.2.0');
    });

    test('detects available update when build is newer', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(true));
      final client =
          MemoryUpdateClient(responseBytes: Uint8List.fromList(updatePayload));
      final service = UpdateService(
        settings: settings,
        client: client,
        currentBuild: 1,
        now: () => now,
      );

      final status = await service.checkForUpdates();
      expect(status.kind, UpdateStatusKind.updateAvailable);
      expect(status.update?.version, '0.2.0');
      expect(status.update?.build, 2);
    });

    test('reports upToDate when running current or newer build', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(true));
      final client =
          MemoryUpdateClient(responseBytes: Uint8List.fromList(updatePayload));
      final service = UpdateService(
        settings: settings,
        client: client,
        currentBuild: 2, // Same build as payload
        now: () => now,
      );

      final status = await service.checkForUpdates();
      expect(status.kind, UpdateStatusKind.upToDate);
    });

    test('rejects expired update metadata', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(true));
      final client =
          MemoryUpdateClient(responseBytes: Uint8List.fromList(updatePayload));
      final service = UpdateService(
        settings: settings,
        client: client,
        currentBuild: 1,
        now: () => DateTime.utc(2026, 12, 1), // Past expires_at
      );

      final status = await service.checkForUpdates();
      expect(status.kind, UpdateStatusKind.error);
      expect(status.errorMessage, contains('expired'));
    });

    test('rejects platform mismatch', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(true));
      final client =
          MemoryUpdateClient(responseBytes: Uint8List.fromList(updatePayload));
      final service = UpdateService(
        settings: settings,
        client: client,
        platform: 'linux', // App is linux, payload is windows
        currentBuild: 1,
        now: () => now,
      );

      final status = await service.checkForUpdates();
      expect(status.kind, UpdateStatusKind.error);
      expect(status.errorMessage, contains('platform'));
    });

    test('rejects architecture mismatch', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(true));
      final client =
          MemoryUpdateClient(responseBytes: Uint8List.fromList(updatePayload));
      final service = UpdateService(
        settings: settings,
        client: client,
        arch: 'arm64', // App is arm64, payload is x64
        currentBuild: 1,
        now: () => now,
      );

      final status = await service.checkForUpdates();
      expect(status.kind, UpdateStatusKind.error);
      expect(status.errorMessage, contains('architecture'));
    });
  });
}
