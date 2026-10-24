import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/auth/qr_scan_screen.dart';
import 'package:private_messenger/features/settings/device_link_screen.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/main.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/about.dart';
import 'package:private_messenger/ui/appearance.dart';
import 'package:private_messenger/ui/confirm.dart';
import 'package:private_messenger/ui/format.dart';
import 'package:private_messenger/ui/validation.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'test_crypto_service.dart';

void main() {
  group('appearance', () {
    test('a saved choice is restored and a new one is persisted', () async {
      final store = MemoryAppearanceStore(ThemeMode.dark);
      final controller = AppearanceController(store);
      expect(controller.mode, ThemeMode.system);
      await controller.load();
      expect(controller.mode, ThemeMode.dark);

      await controller.setMode(ThemeMode.light);
      expect(store.value, ThemeMode.light);
      final restored = AppearanceController(store);
      await restored.load();
      expect(restored.mode, ThemeMode.light);
    });

    test(
      'a choice made before the saved one loads is not overwritten',
      () async {
        final store = _SlowStore(ThemeMode.dark);
        final controller = AppearanceController(store);
        final loading = controller.load();
        await controller.setMode(ThemeMode.light);
        store.release.complete();
        await loading;
        expect(controller.mode, ThemeMode.light);
      },
    );

    test('unknown stored values fall back to the system', () {
      expect(themeModeFromName('sepia'), isNull);
      expect(themeModeFromName(null), isNull);
      expect(themeModeFromName('dark'), ThemeMode.dark);
    });

    testWidgets('settings switches System/Light/Dark and the app follows', (
      tester,
    ) async {
      final store = MemoryAppearanceStore();
      final controller = AppearanceController(store);
      await tester.pumpWidget(_App(appearance: controller, state: _state()));
      await tester.scrollUntilVisible(find.text('Dark'), 200);
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(store.value, ThemeMode.dark);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      expect(
        Theme.of(tester.element(find.byType(SettingsScreen))).brightness,
        Brightness.dark,
      );
    });
  });

  group('about', () {
    testWidgets('settings exposes About and the license page', (tester) async {
      await tester.pumpWidget(_App(state: _state()));
      await tester.scrollUntilVisible(find.text('Open-source licenses'), 200);
      await tester.ensureVisible(find.text('Open-source licenses'));
      await tester.pumpAndSettle();
      expect(find.text('About Veritra'), findsOneWidget);
      expect(
        find.text('Version $veritraVersion · AGPL-3.0-or-later'),
        findsOneWidget,
      );
      await tester.tap(find.text('Open-source licenses'));
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
      expect(find.text('Veritra'), findsWidgets);
      expect(find.textContaining('ServesYouRice/Veritra'), findsWidgets);
    });

    testWidgets('the About dialog names the product, version and license', (
      tester,
    ) async {
      await tester.pumpWidget(_App(state: _state()));
      await tester.scrollUntilVisible(find.text('About Veritra'), 200);
      await tester.ensureVisible(find.text('About Veritra'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About Veritra'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutDialog), findsOneWidget);
      expect(find.text(veritraVersion), findsOneWidget);
      expect(find.textContaining('AGPL-3.0-or-later'), findsWidgets);
    });
  });

  group('destructive confirmations', () {
    testWidgets('sign out asks first and cancelling keeps the session', (
      tester,
    ) async {
      final state = _state();
      await tester.pumpWidget(_App(state: state));
      await tester.scrollUntilVisible(find.text('Sign out'), 200);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.session, isNotNull);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();
      expect(state.session, isNull);
    });

    testWidgets('confirmAction resolves false when dismissed', (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await confirmAction(
                  context,
                  title: 'Revoke invite?',
                  message: 'It stops working.',
                  confirmLabel: 'Revoke',
                  destructive: true,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });
  });

  group('localization', () {
    testWidgets('the app provides its strings and Material localizations', (
      tester,
    ) async {
      await tester.pumpWidget(
        VeritraApp(
          state: _state(),
          appearance: AppearanceController(MemoryAppearanceStore()),
        ),
      );
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.localizationsDelegates, contains(AppLocalizations.delegate));
      expect(
        app.localizationsDelegates,
        contains(GlobalMaterialLocalizations.delegate),
      );
      expect(app.supportedLocales, contains(const Locale('en')));
      final context = tester.element(find.byType(Scaffold).first);
      expect(AppLocalizations.of(context), isNotNull);
      expect(
        formatListTime(
          context,
          DateTime(2026, 10, 21, 12),
          now: DateTime(2026, 10, 22, 12),
        ),
        AppLocalizations.of(context)!.listTimeYesterday,
      );
    });

    testWidgets('widgets outside the app fall back to English', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(AppLocalizations.of(context), isNull);
      expect(context.l10n.listTimeYesterday, 'Yesterday');
      expect(displayNameError('', groupName: true), 'Enter a group name.');
    });
  });

  group('device-link URI', () {
    testWidgets('the approving device never renders the safety code', (
      tester,
    ) async {
      final state = _state()
        ..activeDeviceLink = DeviceLink(
          id: 'dl_1',
          state: 'claimed',
          verificationCode: '12345678',
          expiresAt: DateTime.utc(2030),
          code: 'PAIRCODE',
        );
      await tester.pumpWidget(
        MaterialApp(home: DeviceLinkScreen(state: state)),
      );
      expect(find.textContaining('12345678'), findsNothing);
      expect(find.text('VERIFICATION CODE'), findsNothing);
    });

    test('the QR payload is built locally and round-trips the scanner', () {
      final payload = deviceLinkQrPayload(' AB CD+1 ')!;
      expect(payload, startsWith('veritra://device-link?code='));
      expect(parseDeviceLinkCode(payload), 'AB CD+1');
      expect(parseDeviceLinkOrigin(payload), isNull);
      expect(deviceLinkQrPayload(null), isNull);
      expect(deviceLinkQrPayload('  '), isNull);
    });

    testWidgets('the link screen never offers the server URI as a link', (
      tester,
    ) async {
      final state = _state()
        ..activeDeviceLink = DeviceLink(
          id: 'dl_1',
          state: 'pending',
          verificationCode: '123456',
          expiresAt: DateTime.utc(2030),
          code: 'PAIRCODE',
          linkUri: 'veritra://device-link?code=OTHER'
              '&origin=https://attacker.example',
        );
      await tester.pumpWidget(
        MaterialApp(home: DeviceLinkScreen(state: state)),
      );
      expect(find.text('LINK URI'), findsNothing);
      expect(find.textContaining('attacker'), findsNothing);
      final qr = tester.widget<QrImageView>(find.byType(QrImageView));
      expect(qr.key, ValueKey<String>(deviceLinkQrPayload('PAIRCODE')!));
    });
  });
}

class _App extends StatelessWidget {
  const _App({required this.state, this.appearance});

  final AppState state;
  final AppearanceController? appearance;

  @override
  Widget build(BuildContext context) {
    final controller =
        appearance ?? AppearanceController(MemoryAppearanceStore());
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => AppearanceScope(
        controller: controller,
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          darkTheme: ThemeData(brightness: Brightness.dark),
          themeMode: controller.mode,
          home: Scaffold(body: SettingsScreen(state: state)),
        ),
      ),
    );
  }
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

  @override
  Future<void> logout(String token) async {}
}

class _SlowStore implements AppearanceStore {
  _SlowStore(this.value);

  final ThemeMode value;
  final release = Completer<void>();

  @override
  Future<ThemeMode?> load() async {
    await release.future;
    return value;
  }

  @override
  Future<void> save(ThemeMode mode) async {}
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
