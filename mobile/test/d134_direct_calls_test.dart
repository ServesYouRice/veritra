// D56/D134: calls stay relay-only unless a Settings switch allows direct
// connections. The switch is stored with the other privacy settings.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _NoSync implements SyncService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[];
}

AppState _state(MemoryLocalStore store) {
  final api = _Api();
  final state = AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: store,
    syncServiceFactory: (_, __) => _NoSync(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'https://localhost:8080',
      token: 'token',
      accountId: 'acct_me',
      deviceId: 'dev_me',
    );
  addTearDown(state.dispose);
  return state;
}

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void main() {
  const key = ValueKey<String>('settings-calls-relay');

  testWidgets('Settings has the direct-calls switch, off by default', (
    tester,
  ) async {
    final store = MemoryLocalStore();
    final state = _state(store);
    state.devicesLoaded = true;
    expect(state.allowDirectCalls, isFalse);
    await tester.pumpWidget(_app(Scaffold(body: SettingsScreen(state: state))));
    await tester.pump();
    await tester.scrollUntilVisible(find.byKey(key), 300);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(find.byKey(key)).value, isFalse);
    expect(find.text(englishL10n.settingsDirectCallsNote), findsOneWidget);

    await tester.tap(find.byKey(key));
    await tester.pump();
    expect(state.allowDirectCalls, isTrue);
    expect(await store.loadSetting('d134.direct_calls'), 'true');
    expect(tester.widget<SwitchListTile>(find.byKey(key)).value, isTrue);
  });

  test('the setting survives a restart, and off stays the default', () async {
    final store = MemoryLocalStore();
    final first = _state(store);
    await first.refreshConversations();
    expect(first.allowDirectCalls, isFalse);

    await first.setAllowDirectCalls(true);
    final second = _state(store);
    expect(second.allowDirectCalls, isFalse, reason: 'not loaded yet');
    await second.refreshConversations();
    expect(second.allowDirectCalls, isTrue);

    await second.setAllowDirectCalls(false);
    final third = _state(store);
    await third.refreshConversations();
    expect(third.allowDirectCalls, isFalse);

    // Anything but the exact value `true` keeps calls relay-only.
    await store.saveSetting('d134.direct_calls', 'yes');
    final fourth = _state(store);
    await fourth.refreshConversations();
    expect(fourth.allowDirectCalls, isFalse);
  });
}
