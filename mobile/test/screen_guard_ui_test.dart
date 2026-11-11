import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _NoopSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _Api implements ApiClient {
  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[];

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppState _createState(FakeScreenGuard screenGuard, MemoryLocalStore store) {
  final api = _Api();
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: store,
    screenGuard: screenGuard,
    syncServiceFactory: (_, __) => _NoopSync(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'https://localhost',
      token: 'token',
      accountId: 'acct_1',
      deviceId: 'dev_1',
    )
    ..devicesLoaded = true
    ..conversations = <Conversation>[
      Conversation(id: 'conv_1', kind: 'direct'),
    ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'ChatScreen mounts and unmounts, toggling screen guard active views',
      (tester) async {
    final guard = FakeScreenGuard();
    final store = MemoryLocalStore();
    final state = _createState(guard, store);

    expect(state.activeChatViewsForTesting, 0);
    expect(state.isScreenGuardActive, isFalse);
    expect(await guard.isSecure(), isFalse);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatScreen(state: state, conversationId: 'conv_1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(state.activeChatViewsForTesting, 1);
    expect(state.isScreenGuardActive, isTrue);
    expect(await guard.isSecure(), isTrue);

    // Unmount ChatScreen
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    expect(state.activeChatViewsForTesting, 0);
    expect(state.isScreenGuardActive, isFalse);
    expect(await guard.isSecure(), isFalse);

    state.dispose();
  });

  testWidgets(
      'SettingsScreen shows screen guard toggle on Android and toggles setting',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    try {
      final guard = FakeScreenGuard();
      final store = MemoryLocalStore();
      final state = _createState(guard, store);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SettingsScreen(state: state)),
        ),
      );
      await tester.pump();

      final tileKey = const ValueKey<String>('settings-screen-guard');
      final tileFinder = find.byKey(tileKey);
      expect(tileFinder, findsOneWidget);

      final switchTile = tester.widget<SwitchListTile>(tileFinder);
      expect(switchTile.value, isTrue);
      expect(find.text('Screen guard'), findsOneWidget);
      expect(
          find.text(
              'Block screenshots and AI-assistant screen reading in chats.'),
          findsOneWidget);

      // Tap to toggle off
      await tester.tap(tileFinder);
      await tester.pump();

      expect(state.screenGuardChats, isFalse);
      expect(await store.loadSetting('screen_guard_chats'), 'false');
      final switchTileOff = tester.widget<SwitchListTile>(tileFinder);
      expect(switchTileOff.value, isFalse);

      // Tap to toggle on
      await tester.tap(tileFinder);
      await tester.pump();

      expect(state.screenGuardChats, isTrue);
      expect(await store.loadSetting('screen_guard_chats'), 'true');
      final switchTileOn = tester.widget<SwitchListTile>(tileFinder);
      expect(switchTileOn.value, isTrue);

      state.dispose();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('SettingsScreen hides screen guard toggle on non-Android',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final guard = FakeScreenGuard();
      final store = MemoryLocalStore();
      final state = _createState(guard, store);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SettingsScreen(state: state)),
        ),
      );
      await tester.pump();

      final tileKey = const ValueKey<String>('settings-screen-guard');
      expect(find.byKey(tileKey), findsNothing);

      state.dispose();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
