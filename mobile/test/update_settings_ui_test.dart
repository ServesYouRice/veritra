import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/desktop/update_service.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

void main() {
  group('SettingsScreen updates section', () {
    testWidgets('omits updates section when UpdateSettingsScope is absent', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsScreen(state: _state()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('UPDATES'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('settings-auto-update-check')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('settings-check-for-updates')),
        findsNothing,
      );
    });

    testWidgets('renders updates section with auto-check ON by default', (
      tester,
    ) async {
      final store = MemoryUpdateSettingsStore(true);
      final settings = UpdateSettings(store);
      await settings.load();

      final client = MemoryUpdateClient();
      final service = UpdateService(
        settings: settings,
        client: client,
        currentBuild: 1,
        platform: 'windows',
        arch: 'x64',
      );

      await tester.pumpWidget(
        UpdateSettingsScope(
          settings: settings,
          service: service,
          child: MaterialApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: SettingsScreen(state: _state()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final autoCheckFinder = find.byKey(
        const ValueKey<String>('settings-auto-update-check'),
      );
      await tester.scrollUntilVisible(
        autoCheckFinder,
        200,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.text('UPDATES'), findsOneWidget);
      expect(autoCheckFinder, findsOneWidget);

      // Verify switch is ON
      final switchFinder = find.descendant(
        of: autoCheckFinder,
        matching: find.byWidgetPredicate(
          (widget) => widget is Switch && widget.value == true,
        ),
      );
      expect(switchFinder, findsOneWidget);

      // Toggle switch OFF
      await tester.tap(autoCheckFinder);
      await tester.pumpAndSettle();

      expect(settings.autoCheckEnabled, isFalse);
      expect(await store.loadAutoCheck(), isFalse);

      final switchOffFinder = find.descendant(
        of: autoCheckFinder,
        matching: find.byWidgetPredicate(
          (widget) => widget is Switch && widget.value == false,
        ),
      );
      expect(switchOffFinder, findsOneWidget);
    });

    testWidgets('manual "Check for updates" triggers service check', (
      tester,
    ) async {
      final store = MemoryUpdateSettingsStore(true);
      final settings = UpdateSettings(store);
      await settings.load();

      final updatePayload = utf8.encode(jsonEncode({
        'version': '0.2.0',
        'build': 2,
        'platform': 'windows',
        'arch': 'x64',
        'issued_at': '2026-11-10T12:00:00Z',
        'expires_at': '2026-11-20T12:00:00Z',
        'url':
            'https://github.com/ServesYouRice/veritra/releases/download/v0.2.0/Veritra-Setup-0.2.0-x64.exe',
        'sha256': 'a' * 64,
        'notes': 'New release notes',
      }));

      final client = MemoryUpdateClient(
        responseBytes: Uint8List.fromList(updatePayload),
      );
      final service = UpdateService(
        settings: settings,
        client: client,
        currentBuild: 1,
        platform: 'windows',
        arch: 'x64',
        now: () => DateTime.utc(2026, 11, 10, 13),
      );

      await tester.pumpWidget(
        UpdateSettingsScope(
          settings: settings,
          service: service,
          child: MaterialApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: SettingsScreen(state: _state()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final checkFinder = find.byKey(
        const ValueKey<String>('settings-check-for-updates'),
      );
      await tester.scrollUntilVisible(
        checkFinder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(checkFinder);
      await tester.pumpAndSettle();
      expect(checkFinder, findsOneWidget);

      await tester.tap(checkFinder);
      await tester.pumpAndSettle();

      expect(service.status.kind, UpdateStatusKind.updateAvailable);
      expect(find.textContaining('Version 0.2.0 is available'), findsOneWidget);
    });
  });
}

AppState _state() {
  final api = _Api();
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _FakeSyncService(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'https://example.test',
      token: 'token',
      accountId: 'acct_0123456789abcdef',
      deviceId: 'dev_current',
      username: 'alice',
      role: 'member',
    )
    ..devicesLoaded = true;
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');
}

class _FakeSyncService implements SyncService {
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _events.close();
}
