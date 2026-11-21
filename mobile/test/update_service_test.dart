import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/desktop/update_installer.dart';
import 'package:private_messenger/desktop/update_service.dart';
import 'package:private_messenger/desktop/update_trust.dart';
import 'update_test_support.dart';

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

    test('rejects url with empty host', () {
      final invalid = Map<String, Object?>.from(validJson)
        ..['url'] = 'https:///installer.exe';
      expect(() => UpdateInfo.fromJson(invalid), throwsFormatException);
    });

    test('rejects inverted issue and expiry dates', () {
      final invalid = Map<String, Object?>.from(validJson)
        ..['issued_at'] = '2026-11-20T12:00:00Z'
        ..['expires_at'] = '2026-11-10T12:00:00Z';
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

    test('concurrent load calls share single execution', () async {
      final store = MemoryUpdateSettingsStore(false);
      final settings = UpdateSettings(store);
      final future1 = settings.load();
      final future2 = settings.load();
      expect(identical(future1, future2), isTrue);
      await future1;
      expect(settings.autoCheckEnabled, isFalse);
    });
  });

  group('UpdateService', () {
    final now = DateTime.utc(2026, 11, 10, 15);
    final updatePayload = utf8.encode(
      jsonEncode(<String, Object?>{
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
      }),
    );

    test('skips checking when auto-check is disabled unless forced', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(false));
      await settings.load();
      final client = MemoryUpdateClient(
        responseBytes: Uint8List.fromList(updatePayload),
      );
      final service = UpdateService(
        settings: settings,
        verifier: const AcceptingUpdateVerifier(),
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
      final client = MemoryUpdateClient(
        responseBytes: Uint8List.fromList(updatePayload),
      );
      final service = UpdateService(
        settings: settings,
        verifier: const AcceptingUpdateVerifier(),
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
      final client = MemoryUpdateClient(
        responseBytes: Uint8List.fromList(updatePayload),
      );
      final service = UpdateService(
        settings: settings,
        verifier: const AcceptingUpdateVerifier(),
        client: client,
        currentBuild: 2, // Same build as payload
        now: () => now,
      );

      final status = await service.checkForUpdates();
      expect(status.kind, UpdateStatusKind.upToDate);
    });

    test('rejects expired update metadata', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(true));
      final client = MemoryUpdateClient(
        responseBytes: Uint8List.fromList(updatePayload),
      );
      final service = UpdateService(
        settings: settings,
        verifier: const AcceptingUpdateVerifier(),
        client: client,
        currentBuild: 1,
        now: () => DateTime.utc(2026, 12, 1), // Past expires_at
      );

      final status = await service.checkForUpdates();
      expect(status.kind, UpdateStatusKind.error);
      expect(status.errorMessage, contains('expired'));
    });

    test('rejects a feed for another platform', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(true));
      final decoded =
          jsonDecode(utf8.decode(updatePayload)) as Map<String, Object?>;
      decoded['platform'] = 'linux'; // App is windows, payload is linux
      final client = MemoryUpdateClient(
        responseBytes: Uint8List.fromList(utf8.encode(jsonEncode(decoded))),
      );
      final service = UpdateService(
        settings: settings,
        verifier: const AcceptingUpdateVerifier(),
        client: client,
        currentBuild: 1,
        now: () => now,
      );

      final status = await service.checkForUpdates();
      expect(status.kind, UpdateStatusKind.error);
      expect(status.errorMessage, contains('platform'));
    });

    test('this build has no usable verifier, so it never fetches a feed',
        () async {
      // The shipped default accepts nothing: with no verification of the
      // feed's signature the channel stays off, key or no key. A manual
      // (forced) check changes nothing. Removing this guard makes the
      // placeholder's old behaviour (trust any non-empty signature) possible
      // again, so this test must fail then.
      var fetches = 0;
      final settings = UpdateSettings(MemoryUpdateSettingsStore(true));
      final service = UpdateService(
        settings: settings,
        client: _TrackingUpdateClient(
          onFetch: () => fetches++,
          responseBytes: Uint8List.fromList(updatePayload),
        ),
        currentBuild: 1,
        now: () => now,
      );
      expect(service.status.kind, UpdateStatusKind.unavailable);
      expect(
        (await service.checkForUpdatesIfEnabled()).kind,
        UpdateStatusKind.unavailable,
      );
      expect(
        (await service.checkForUpdates(force: true)).kind,
        UpdateStatusKind.unavailable,
      );
      expect(fetches, 0);
      expect(updateFeedPublicKeyHex, isEmpty);
      expect(const FailClosedUpdateSignatureVerifier().isConfigured, isFalse);
      expect(
        await const FailClosedUpdateSignatureVerifier().verify(
          data: updatePayload,
          signature: List<int>.filled(64, 1),
        ),
        isFalse,
      );
    });

    test('only the Windows channel exists', () async {
      var fetches = 0;
      final service = UpdateService(
        settings: UpdateSettings(MemoryUpdateSettingsStore(true)),
        verifier: const AcceptingUpdateVerifier(),
        client: _TrackingUpdateClient(
          onFetch: () => fetches++,
          responseBytes: Uint8List.fromList(updatePayload),
        ),
        platform: 'unsupported',
        currentBuild: 1,
        now: () => now,
      );
      expect(
        (await service.checkForUpdates(force: true)).kind,
        UpdateStatusKind.unavailable,
      );
      expect(fetches, 0);
    });

    group('download and install', () {
      late _FakeInstallerParts parts;
      late UpdateService service;
      var quit = 0;

      Future<void> available() async {
        await service.checkForUpdates();
        expect(service.status.kind, UpdateStatusKind.updateAvailable);
      }

      setUp(() {
        parts = _FakeInstallerParts();
        quit = 0;
        service = UpdateService(
          settings: UpdateSettings(MemoryUpdateSettingsStore(true)),
          verifier: const AcceptingUpdateVerifier(),
          client: MemoryUpdateClient(
            responseBytes: Uint8List.fromList(updatePayload),
          ),
          installer: UpdateInstaller(
            downloader: parts,
            digester: parts,
            launcher: parts,
          ),
          onQuitForUpdate: () => quit++,
          currentBuild: 1,
          now: () => now,
        );
      });

      test('nothing downloads or installs before the user asks', () async {
        await available();
        expect(parts.downloads, 0);
        expect(parts.launches, 0);
        // Not offered yet: install does nothing from updateAvailable.
        await service.installUpdate();
        expect(parts.launches, 0);
        expect(quit, 0);
      });

      test('download, then a second tap installs and quits', () async {
        await available();
        parts.digest = 'b' * 64; // what the signed feed names
        await service.downloadUpdate();
        expect(service.status.kind, UpdateStatusKind.readyToInstall);
        expect(parts.launches, 0);
        await service.installUpdate();
        expect(parts.launches, 1);
        expect(quit, 1);
      });

      test('a download that differs from the signed digest never runs',
          () async {
        await available();
        parts.digest = 'c' * 64;
        await service.downloadUpdate();
        expect(service.status.kind, UpdateStatusKind.downloadFailed);
        expect(service.status.errorMessage, contains('signed digest'));
        await service.installUpdate();
        expect(parts.launches, 0);
        expect(quit, 0);
      });

      test('a file swapped after the download is caught before it runs',
          () async {
        await available();
        parts.digest = 'b' * 64;
        await service.downloadUpdate();
        parts.digest = 'd' * 64; // the file changed on disk
        await service.installUpdate();
        expect(parts.launches, 0);
        expect(quit, 0);
        expect(service.status.kind, UpdateStatusKind.downloadFailed);
      });
    });

    test('rejects architecture mismatch', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(true));
      final client = MemoryUpdateClient(
        responseBytes: Uint8List.fromList(updatePayload),
      );
      final service = UpdateService(
        settings: settings,
        verifier: const AcceptingUpdateVerifier(),
        client: client,
        arch: 'arm64', // App is arm64, payload is x64
        currentBuild: 1,
        now: () => now,
      );

      final status = await service.checkForUpdates();
      expect(status.kind, UpdateStatusKind.error);
      expect(status.errorMessage, contains('architecture'));
    });

    test(
      'startup check awaits settings load and respects disabled setting',
      () async {
        final completer = Completer<bool?>();
        final slowStore = _SlowSettingsStore(completer.future);
        final settings = UpdateSettings(slowStore);
        unawaited(settings.load());

        var fetchCalled = false;
        final client = _TrackingUpdateClient(
          onFetch: () => fetchCalled = true,
          responseBytes: Uint8List.fromList(updatePayload),
        );
        final service = UpdateService(
          settings: settings,
          verifier: const AcceptingUpdateVerifier(),
          client: client,
          currentBuild: 1,
          now: () => now,
        );

        final checkFuture = service.checkForUpdatesIfEnabled();
        completer.complete(false);
        final status = await checkFuture;

        expect(status.kind, UpdateStatusKind.disabled);
        expect(
          fetchCalled,
          isFalse,
          reason: 'Must not contact network when setting is disabled',
        );
      },
    );

    test('rejects invalid signature', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(true));
      final client = MemoryUpdateClient(
        responseBytes: Uint8List.fromList(updatePayload),
      );
      final service = UpdateService(
        settings: settings,
        client: client,
        verifier: _AlwaysRejectVerifier(),
        currentBuild: 1,
        now: () => now,
      );

      final status = await service.checkForUpdates();
      expect(status.kind, UpdateStatusKind.error);
      expect(status.errorMessage, contains('signature is invalid'));
    });

    test('handles malformed json payload', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(true));
      final client = MemoryUpdateClient(
        responseBytes: Uint8List.fromList(utf8.encode('not-a-json')),
      );
      final service = UpdateService(
        settings: settings,
        verifier: const AcceptingUpdateVerifier(),
        client: client,
        currentBuild: 1,
        now: () => now,
      );

      final status = await service.checkForUpdates();
      expect(status.kind, UpdateStatusKind.error);
    });

    test('handles network error', () async {
      final settings = UpdateSettings(MemoryUpdateSettingsStore(true));
      final client = MemoryUpdateClient(
        error: const HttpException('Failed to connect'),
      );
      final service = UpdateService(
        settings: settings,
        verifier: const AcceptingUpdateVerifier(),
        client: client,
        currentBuild: 1,
        now: () => now,
      );

      final status = await service.checkForUpdates();
      expect(status.kind, UpdateStatusKind.error);
      expect(status.errorMessage, contains('Failed to connect'));
    });

    test('reacts to settings change from idle to disabled and back', () async {
      final store = MemoryUpdateSettingsStore(true);
      final settings = UpdateSettings(store);
      final service = UpdateService(
        settings: settings,
        verifier: const AcceptingUpdateVerifier(),
        client: MemoryUpdateClient(),
        currentBuild: 1,
      );
      expect(service.status.kind, UpdateStatusKind.idle);

      await settings.setAutoCheckEnabled(false);
      expect(service.status.kind, UpdateStatusKind.disabled);

      await settings.setAutoCheckEnabled(true);
      expect(service.status.kind, UpdateStatusKind.idle);
      service.dispose();
    });
  });

  group('signed feed test vector (scripts/update-feed.py)', () {
    const dir = 'test/fixtures/update-feed';

    test('the committed feed parses as the app reads it', () {
      final feed = jsonDecode(File('$dir/update.json').readAsStringSync())
          as Map<String, Object?>;
      final info = UpdateInfo.fromJson(feed);
      expect(info.version, '0.2.0');
      expect(info.build, 2);
      expect(info.platform, 'windows');
      expect(info.arch, 'x64');
      expect(info.url, startsWith('https://'));
      expect(info.sha256, hasLength(64));
      expect(info.expiresAt.isAfter(info.issuedAt), isTrue);
    });

    test('the signature and key have the Ed25519 sizes', () {
      expect(File('$dir/update.json.sig').lengthSync(), 64);
      expect(
          File('$dir/public-key.hex').readAsStringSync().trim(), hasLength(64));
      // The vector's key is not the one the app trusts (none is set yet).
      expect(updateFeedPublicKeyHex, isEmpty);
    });
  });

  group('UpdateInstaller', () {
    late Directory temp;
    late _FakeInstallerParts parts;
    late UpdateInstaller installer;
    final info = UpdateInfo(
      version: '0.2.0',
      build: 2,
      platform: 'windows',
      arch: 'x64',
      issuedAt: DateTime.utc(2026, 11, 10),
      expiresAt: DateTime.utc(2026, 11, 20),
      url: 'https://example.com/Veritra-Setup-0.2.0-x64.exe',
      sha256: 'b' * 64,
      notes: '',
    );

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('veritra-update-test-');
      parts = _FakeInstallerParts()..digest = 'b' * 64;
      installer = UpdateInstaller(
        downloader: parts,
        digester: parts,
        launcher: parts,
        tempRoot: temp,
      );
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test('keeps a matching download under a name the app chose', () async {
      final file = await installer.download(info);
      expect(file.path, startsWith(temp.path));
      expect(file.path, endsWith('Veritra-Setup-0.2.0-x64.exe'));
      expect(await file.exists(), isTrue);
    });

    test('deletes a download whose digest differs', () async {
      parts.digest = 'e' * 64;
      await expectLater(
        installer.download(info),
        throwsA(isA<UpdateDigestMismatch>()),
      );
      expect(await temp.list().toList(), isEmpty);
    });

    test('refuses a non-https url and a version that is not plain', () async {
      await expectLater(
        installer.download(_Target(url: 'http://example.com/x.exe')),
        throwsFormatException,
      );
      await expectLater(
        installer.download(_Target(version: r'..\..\evil')),
        throwsFormatException,
      );
      expect(parts.downloads, 0);
    });

    test('removes the folder when the download itself fails', () async {
      parts.failWith = const HttpException('boom');
      await expectLater(
        installer.download(info),
        throwsA(isA<HttpException>()),
      );
      expect(await temp.list().toList(), isEmpty);
    });
  });

  group('HttpUpdateDownloader', () {
    test('refuses an http url before any request', () async {
      const downloader = HttpUpdateDownloader();
      final dir = Directory.systemTemp.createTempSync('veritra-dl-test-');
      addTearDown(() => dir.deleteSync(recursive: true));
      await expectLater(
        downloader.download(
          Uri.parse('http://example.com/x.exe'),
          File('${dir.path}/x.exe'),
          maxBytes: 100,
        ),
        throwsFormatException,
      );
    });
  });
  group('HttpUpdateClient', () {
    test('rejects non-https feed uri', () async {
      const client = HttpUpdateClient();
      expect(
        () => client.fetchUpdate(Uri.parse('http://example.com/update.json')),
        throwsFormatException,
      );
    });

    test('rejects feed uri with empty host', () async {
      const client = HttpUpdateClient();
      expect(
        () => client.fetchUpdate(Uri.parse('https:///update.json')),
        throwsFormatException,
      );
    });
  });
}

class _SlowSettingsStore implements UpdateSettingsStore {
  _SlowSettingsStore(this._future);
  final Future<bool?> _future;

  @override
  Future<bool?> loadAutoCheck() => _future;

  @override
  Future<void> saveAutoCheck(bool value) async {}
}

class _TrackingUpdateClient implements UpdateClient {
  _TrackingUpdateClient({required this.onFetch, required this.responseBytes});
  final VoidCallback onFetch;
  final Uint8List responseBytes;

  @override
  Future<({Uint8List jsonBytes, Uint8List? signatureBytes})> fetchUpdate(
    Uri feedUri,
  ) async {
    onFetch();
    return (jsonBytes: responseBytes, signatureBytes: null);
  }
}

class _AlwaysRejectVerifier implements UpdateSignatureVerifier {
  @override
  bool get isConfigured => true;

  @override
  Future<bool> verify({
    required List<int> data,
    required List<int>? signature,
  }) async =>
      false;
}

/// One fake for the installer's three collaborators. [digest] is what the
/// "file on disk" hashes to; change it to model a swapped file.
class _FakeInstallerParts
    implements UpdateDownloader, FileDigester, InstallerLauncher {
  String digest = '';
  Object? failWith;
  int downloads = 0;
  int launches = 0;

  @override
  Future<void> download(
    Uri url,
    File destination, {
    required int maxBytes,
  }) async {
    downloads++;
    if (failWith != null) throw failWith!;
    await destination.writeAsBytes(<int>[1, 2, 3]);
  }

  @override
  Future<String> sha256Hex(File file) async => digest;

  @override
  Future<void> launch(File installer) async => launches++;
}

class _Target implements UpdateInstallTarget {
  _Target({
    this.version = '0.2.0',
    this.url = 'https://example.com/x.exe',
  });

  @override
  final String version;
  @override
  final String url;
  @override
  final String sha256 = 'b';
}
