// B7 S6: the account switcher UI. The app root swaps the whole MaterialApp on
// a switch (no route of one account survives into the next), shows a blocking
// overlay meanwhile, lists the accounts, warns about two accounts on one
// server, enforces the five-account cap and asks before leaving with push
// still registered.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/account_host.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/auth/connect_screen.dart';
import 'package:private_messenger/features/settings/accounts_screen.dart';
import 'package:private_messenger/main.dart' show VeritraApp;
import 'package:private_messenger/storage/account_slots.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/appearance.dart';
import 'package:private_messenger/ui/theme.dart';

import 'test_crypto_service.dart';

class _State extends AppState {
  _State()
      : super(
          apiClientFactory: (_) => throw StateError('no network in this test'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _Quiet(),
        );

  bool pushGone = true;
  Completer<void>? holdLeave;

  void signInAs(String account, String origin) {
    session = Session(
      baseUrl: origin,
      token: 't',
      accountId: account,
      username: 'user$account',
    );
    notifyListeners();
  }

  @override
  Future<bool> prepareToLeave() async {
    await holdLeave?.future;
    return pushGone;
  }

  @override
  Future<void> closeForSwitch() async => dispose();

  @override
  Future<void> logout() async {}
}

class _NoIoEraser implements SlotErasing {
  @override
  Future<void> erase(String namespace) async {}
}

class _Quiet implements SyncService {
  final _c = StreamController<Map<String, Object?>>.broadcast();
  @override
  Stream<Map<String, Object?>> get events => _c.stream;
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() => _c.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemorySlotKeyValue kv;
  late Map<String, _State> states;

  setUp(() async {
    kv = MemorySlotKeyValue();
    states = <String, _State>{};
  });

  AccountHost newHost() => AccountHost(
        registryStore: AccountRegistryStore(storage: kv),
        // File IO never completes in a widget test's fake-async zone.
        eraser: _NoIoEraser(),
        primaryNamespace: '',
        build: (ns) async {
          final state = states[ns] = _State();
          return AccountRuntime(
              namespace: ns, state: state, closeStore: () async {});
        },
      );

  Future<void> pumpAsync(WidgetTester tester, [int ms = 80]) async {
    await tester
        .runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    await tester.pump();
  }

  Future<AccountHost> openApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final host = newHost();
    await tester.runAsync(host.start);
    await tester.pumpWidget(VeritraApp(
      host: host,
      appearance: AppearanceController(MemoryAppearanceStore()),
    ));
    await pumpAsync(tester);
    return host;
  }

  /// Signs the open account in so the app shell shows chats and settings.
  Future<void> signIn(WidgetTester tester, AccountHost host, String account,
      {String origin = 'https://a.example'}) async {
    (host.runtime!.state as _State).signInAs(account, origin);
    await pumpAsync(tester);
  }

  Finder tile(String ns) => find.byKey(ValueKey<String>('account-$ns'));

  testWidgets('a fresh device opens the connect screen of the primary slot',
      (tester) async {
    final host = await openApp(tester);
    addTearDown(host.dispose);
    expect(find.text('Connect'), findsNothing,
        reason: 'no account switcher chrome before a second account exists');
    expect(find.byKey(const ValueKey<String>('connect-back')), findsNothing);
    expect(host.runtime!.namespace, '');
  });

  testWidgets('switching replaces the whole app: no route of A survives in B',
      (tester) async {
    final host = await openApp(tester);
    addTearDown(host.dispose);
    await signIn(tester, host, 'one');
    await tester.runAsync(() => host.beginAdd());
    await pumpAsync(tester);
    final second = host.runtime!.namespace;
    await signIn(tester, host, 'two', origin: 'https://b.example');
    await tester.runAsync(() => host.idle());

    // Push a route in B, then switch back to A.
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('a screen of B'))));
    await tester.pumpAndSettle();
    expect(find.text('a screen of B'), findsOneWidget);

    await tester.runAsync(() => host.switchTo(''));
    await pumpAsync(tester);

    expect(find.text('a screen of B'), findsNothing);
    expect(host.runtime!.namespace, '');
    expect(identical(host.runtime!.state, states[second]), isFalse);
  });

  testWidgets('a blocking overlay shows while the switch runs', (tester) async {
    final host = await openApp(tester);
    addTearDown(host.dispose);
    await signIn(tester, host, 'one');
    final state = host.runtime!.state as _State;
    state.holdLeave = Completer<void>();

    unawaited(host.beginAdd());
    await pumpAsync(tester, 20);
    expect(host.switching, isTrue);
    expect(find.text('Switching…'), findsOneWidget);
    expect(find.byType(ModalBarrier), findsWidgets);

    state.holdLeave!.complete();
    await pumpAsync(tester);
    expect(find.text('Switching…'), findsNothing);
  });

  group('the accounts screen', () {
    Future<AccountHost> twoAccounts(WidgetTester tester,
        {String secondOrigin = 'https://b.example'}) async {
      final host = await openApp(tester);
      addTearDown(host.dispose);
      await signIn(tester, host, 'one');
      await tester.runAsync(() => host.beginAdd());
      await pumpAsync(tester);
      await signIn(tester, host, 'two', origin: secondOrigin);
      await tester.runAsync(() => host.idle());
      await tester.pump();
      await tester.runAsync(() => host.switchTo(''));
      await pumpAsync(tester);
      return host;
    }

    Future<void> openScreen(WidgetTester tester, AccountHost host) async {
      await tester.pumpWidget(MaterialApp(
        theme: veritraLightTheme(),
        home: AccountsScreen(host: host),
      ));
      await tester.pump();
    }

    testWidgets('lists both accounts with their host and marks the open one',
        (tester) async {
      final host = await twoAccounts(tester);
      await openScreen(tester, host);
      expect(find.text('userone@a.example'), findsOneWidget);
      expect(find.text('usertwo@b.example'), findsOneWidget);
      expect(find.text('Open now'), findsOneWidget);
      expect(find.byKey(const ValueKey('same-server')), findsNothing);
    });

    testWidgets('warns when two accounts share a server', (tester) async {
      final host = await twoAccounts(tester, secondOrigin: 'https://a.example');
      await openScreen(tester, host);
      expect(find.byKey(const ValueKey('same-server')), findsOneWidget);
      expect(find.textContaining('same device'), findsOneWidget);
    });

    testWidgets('taps switch accounts', (tester) async {
      final host = await twoAccounts(tester);
      final other = host.registry.slots.last.namespace;
      await openScreen(tester, host);
      await tester.tap(tile(other));
      await pumpAsync(tester);
      expect(host.runtime!.namespace, other);
    });

    testWidgets('five accounts is the most: the add button is off',
        (tester) async {
      final host = await twoAccounts(tester);
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => host.beginAdd());
        await pumpAsync(tester);
        await signIn(tester, host, 'x$i', origin: 'https://c$i.example');
        await tester.runAsync(() => host.idle());
      }
      expect(host.registry.liveCount, maxAccountSlots);
      await openScreen(tester, host);
      final button = tester.widget<FilledButton>(
          find.byKey(const ValueKey<String>('accounts-add')));
      expect(button.onPressed, isNull);
      expect(find.byKey(const ValueKey('cap-note')), findsOneWidget);
    });

    testWidgets('removing asks first; cancelling keeps the account',
        (tester) async {
      final host = await twoAccounts(tester);
      final other = host.registry.slots.last.namespace;
      await openScreen(tester, host);
      await tester.tap(find.descendant(
          of: tile(other), matching: find.byType(PopupMenuButton<String>)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from this device').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Remove usertwo@b.example'), findsOneWidget);
      expect(find.textContaining('device list'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(host.registry.slot(other), isNotNull);
      expect(host.runtime!.namespace, '');
    });

    testWidgets('push that will not go asks before switching anyway',
        (tester) async {
      final host = await twoAccounts(tester);
      final other = host.registry.slots.last.namespace;
      (host.runtime!.state as _State).pushGone = false;
      await openScreen(tester, host);
      await tester.tap(tile(other));
      await pumpAsync(tester);
      expect(find.text('Switch anyway?'), findsOneWidget);
      expect(host.runtime!.namespace, '', reason: 'nothing changed yet');
      await tester.tap(find.text('Switch anyway'));
      await pumpAsync(tester);
      expect(host.runtime!.namespace, other);
    });
  });

  testWidgets('the connect screen of a new account goes back to the old one',
      (tester) async {
    final host = await openApp(tester);
    addTearDown(host.dispose);
    await signIn(tester, host, 'one', origin: 'https://a.example');
    await tester.runAsync(() => host.beginAdd());
    await pumpAsync(tester);
    // The back button returns to the account that was open.
    expect(find.byKey(const ValueKey<String>('connect-back')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('connect-back')));
    await pumpAsync(tester);
    expect(host.runtime!.namespace, '');
    expect(host.registry.liveCount, 1, reason: 'the empty slot is removed');
  });

  testWidgets(
      'the connect screen warns when the server is already on this device',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final host = await openApp(tester);
    addTearDown(host.dispose);
    await signIn(tester, host, 'one', origin: 'https://a.example');
    await tester.runAsync(() => host.beginAdd());
    await pumpAsync(tester);
    // The new slot's own connect screen, probing the known server.
    final probing = _ProbeState();
    addTearDown(probing.dispose);
    await tester.pumpWidget(AccountHostScope(
      host: host,
      child: MaterialApp(
        theme: veritraLightTheme(),
        home: ConnectScreen(state: probing),
      ),
    ));
    await tester.enterText(
        find.byType(TextFormField).first, 'https://a.example');
    await tester.pump(const Duration(milliseconds: 700));
    await pumpAsync(tester);
    expect(find.byKey(const ValueKey<String>('connect-same-server')),
        findsOneWidget);
    probing.origin = 'https://z.example';
    await tester.enterText(
        find.byType(TextFormField).first, 'https://z.example');
    await tester.pump(const Duration(milliseconds: 700));
    await pumpAsync(tester);
    expect(find.byKey(const ValueKey<String>('connect-same-server')),
        findsNothing);
  });
}

class _ProbeState extends AppState {
  _ProbeState()
      : super(
          apiClientFactory: (_) => throw StateError('no network in this test'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _Quiet(),
        );

  String origin = 'https://a.example';

  @override
  Future<SetupProbeResult> probeSetup(String baseUrl) async => SetupProbeResult(
        state: SetupProbeState.reachable,
        setupRequired: false,
        origin: origin,
      );

  @override
  Future<bool> hasStoredDeviceIdentityForOrigin(String baseUrl) async => false;
}
