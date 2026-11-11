// B7 S3 screens: the connect button, the settings tile and screen, and the
// sync notice banner, driven by a fake PasskeyClient.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/passkeys.dart';
import 'package:private_messenger/features/auth/connect_screen.dart';
import 'package:private_messenger/features/settings/passkeys_screen.dart';
import 'package:private_messenger/ui/theme.dart';
import 'package:private_messenger/ui/widgets/account_recovery_banner.dart';

import 'b7_passkey_fakes.dart';

/// Connect-screen state: the probe says whatever [info] says.
class _ConnectState extends AppState {
  _ConnectState({
    required this.info,
    required this.linked,
    required super.passkeyClient,
    required PasskeyPlatform platform,
    List<String> domains = const <String>[],
  }) : super(
          apiClientFactory: (_) => PkApi(),
          cryptoService: PkApi.crypto(),
          localStore: PkApi.store(),
          syncServiceFactory: (_, __) => PkQuietSync(),
          passkeyPlatform: platform,
          passkeyAppleDomains: domains,
        );

  final PasskeyServerInfo? info;
  final bool linked;
  final List<String> passkeySignIns = <String>[];
  int passwordLogins = 0;

  @override
  Future<SetupProbeResult> probeSetup(String baseUrl) async => SetupProbeResult(
        state: SetupProbeState.reachable,
        setupRequired: false,
        passkeys: info,
        origin: 'https://chat.example.com',
      );

  @override
  Future<bool> hasStoredDeviceIdentityForOrigin(String baseUrl) async => linked;

  @override
  Future<void> login(String baseUrl, String username, String password) async {
    passwordLogins++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_ConnectState> openConnect(
    WidgetTester tester, {
    PasskeyServerInfo? info = pkInfo,
    bool linked = true,
    bool supported = true,
    PasskeyPlatform platform = PasskeyPlatform.android,
    List<String> domains = const <String>[],
  }) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = _ConnectState(
      info: info,
      linked: linked,
      passkeyClient: FakePasskeys(supported: supported),
      platform: platform,
      domains: domains,
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: veritraLightTheme(),
      home: ConnectScreen(state: state),
    ));
    await tester.enterText(
        find.byType(TextFormField).first, 'https://chat.example.com');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    return state;
  }

  final button = find.byKey(const ValueKey<String>('connect-passkey'));

  group('the connect screen', () {
    testWidgets('shows the passkey button on an enrolled Android phone',
        (tester) async {
      await openConnect(tester);
      expect(button, findsOneWidget);
      expect(find.text('Sign in with a passkey'), findsOneWidget);
    });

    testWidgets('hides it on Linux', (tester) async {
      await openConnect(tester,
          supported: false, platform: PasskeyPlatform.linux);
      expect(button, findsNothing);
    });

    testWidgets('hides it on an iOS host that is not in the build list',
        (tester) async {
      await openConnect(tester, platform: PasskeyPlatform.ios);
      expect(button, findsNothing);
    });

    testWidgets('shows it on iOS for a host in the build list', (tester) async {
      await openConnect(tester,
          platform: PasskeyPlatform.ios,
          domains: const <String>['chat.example.com']);
      expect(button, findsOneWidget);
    });

    testWidgets('hides it where the server reports no passkeys',
        (tester) async {
      await openConnect(tester, info: null);
      expect(button, findsNothing);
    });

    testWidgets('hides it where the operator left the platform out',
        (tester) async {
      await openConnect(tester,
          info: const PasskeyServerInfo(
              rpId: 'chat.example.com', android: false, apple: true));
      expect(button, findsNothing);
    });

    testWidgets('hides it on a device that is not enrolled', (tester) async {
      await openConnect(tester, linked: false);
      expect(button, findsNothing);
    });
  });

  group('settings', () {
    Future<PkHarness> signedIn(WidgetTester tester) async {
      final h = PkHarness();
      await h.enrolled();
      await tester.runAsync(() async {
        await h.state.signInWithPasskey(pkOrigin);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      addTearDown(h.dispose);
      return h;
    }

    testWidgets('lists passkeys and adds one after the password check',
        (tester) async {
      final h = await signedIn(tester);
      h.api.records = <PasskeyRecord>[
        PasskeyRecord(
            id: 'pk_1',
            name: 'Work phone',
            createdAt: DateTime.utc(2026, 11, 1),
            synced: true),
      ];
      await tester.pumpWidget(MaterialApp(
        theme: veritraLightTheme(),
        home: PasskeysScreen(state: h.state),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.text('Work phone'), findsOneWidget);
      expect(find.textContaining('Backed up'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('passkeys-add')));
      await tester.pump();
      // The password check comes first; nothing is registered before it.
      expect(h.passkeys.created, isEmpty);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'owner-password');
      await tester.tap(find.text('Continue'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(h.passkeys.created, hasLength(1));
      expect(h.api.trace, contains('register:cer_reg:Passkey 1'));
    });

    testWidgets('says so when this server offers none here', (tester) async {
      final h = await signedIn(tester);
      h.api.status = <String, Object?>{'setup_required': false};
      await tester.pumpWidget(MaterialApp(
        theme: veritraLightTheme(),
        home: PasskeysScreen(state: h.state),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.byKey(const ValueKey('off')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('passkeys-add')), findsNothing);
    });
  });

  testWidgets('the banner shows and dismisses a passkey notice',
      (tester) async {
    final h = PkHarness();
    addTearDown(h.dispose);
    await h.enrolled();
    h.api.events.add(SyncEvent(
      id: 1,
      type: 'account.passkey_added',
      createdAt: DateTime.utc(2026, 11, 8),
      payload: <String, Object?>{'passkey_id': 'pk_other'},
    ));
    await tester.runAsync(() async {
      await h.state.signInWithPasskey(pkOrigin);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpWidget(MaterialApp(
      theme: veritraLightTheme(),
      home: Scaffold(body: AccountRecoveryBanner(state: h.state)),
    ));
    expect(h.state.passkeyNotice, PasskeyNotice.added);
    expect(find.textContaining('A passkey was added'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(find.textContaining('A passkey was added'), findsNothing);
    expect(h.state.passkeyNotice, isNull);
  });
}
