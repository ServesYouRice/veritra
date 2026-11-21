// U20: the signed-out app opens on two choices, the second of which asks
// how the person signs in; the big logo shows on the first step only, and the
// path picked is never changed by the setup probe.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/features/auth/connect_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/theme.dart';
import 'package:private_messenger/ui/widgets/veritra_mark.dart';

import 'test_crypto_service.dart';

void main() {
  Finder key(String value) => find.byKey(ValueKey<String>(value));

  Future<_State> open(
    WidgetTester tester, {
    bool storedIdentity = false,
    bool linkedHere = false,
    bool fresh = false,
  }) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = _State(
      storedIdentity: storedIdentity,
      linkedHere: linkedHere,
      fresh: fresh,
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: veritraLightTheme(),
        home: ConnectScreen(state: state),
      ),
    );
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets('the first screen offers two choices and the big logo', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('I have an invite'), findsOneWidget);
    expect(find.text('I already have an account'), findsOneWidget);
    expect(find.byType(VeritraMark), findsOneWidget);
    expect(
      find.byType(TextFormField),
      findsNothing,
      reason: 'no form before the person has chosen',
    );
    expect(key('connect-step-back'), findsNothing);
  });

  testWidgets(
      'the second screen asks new device, signed in before; '
      'the logo does not show again', (tester) async {
    await open(tester);
    await tester.tap(key('welcome-account'));
    await tester.pumpAndSettle();
    expect(find.text('This is a new device'), findsOneWidget);
    expect(find.text("I've signed in here before"), findsOneWidget);
    // Recovery needs the native engine; k0_recovery_screens_test pins the
    // third choice with it.
    expect(find.text('I lost all my devices'), findsNothing);
    expect(find.byType(VeritraMark), findsNothing);

    await tester.tap(key('welcome-new-device'));
    await tester.pumpAndSettle();
    expect(find.text('LINK THIS DEVICE'), findsOneWidget);
    expect(find.byType(VeritraMark), findsNothing);

    await tester.tap(key('connect-step-back'));
    await tester.pumpAndSettle();
    expect(find.text("I've signed in here before"), findsOneWidget);
    await tester.tap(key('welcome-signed-in-before'));
    await tester.pumpAndSettle();
    expect(find.text('SIGN IN'), findsOneWidget);
    expect(find.byType(VeritraMark), findsNothing);
  });

  testWidgets(
    'both choice screens meet the tap-target and contrast guidelines',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester);
      Future<void> check() async {
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      }

      await check();
      await tester.tap(key('welcome-account'));
      await tester.pumpAndSettle();
      await check();
      // Each choice reads as one button named by its words.
      expect(
        tester.getSemantics(key('welcome-new-device')),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'This is a new device\nAdd it using a device you already use.',
        ),
      );
      semantics.dispose();
    },
  );

  testWidgets('back and the system back gesture step back through the flow', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(key('welcome-account'));
    await tester.pumpAndSettle();
    await tester.tap(key('welcome-signed-in-before'));
    await tester.pumpAndSettle();
    expect(find.text('SIGN IN'), findsOneWidget);

    await tester.tap(key('connect-step-back'));
    await tester.pumpAndSettle();
    expect(find.text("I've signed in here before"), findsOneWidget);

    // Android back: handled by the screen, not by leaving the app.
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(find.text('I have an invite'), findsOneWidget);
  });

  testWidgets(
      'a device that signed in before opens on sign-in, back reaches '
      'the choices', (tester) async {
    await open(tester, storedIdentity: true);
    expect(find.text('SIGN IN'), findsOneWidget);
    expect(find.text('I have an invite'), findsNothing);
    await tester.tap(key('connect-step-back'));
    await tester.pumpAndSettle();
    expect(find.text("I've signed in here before"), findsOneWidget);
    await tester.tap(key('connect-step-back'));
    await tester.pumpAndSettle();
    expect(find.text('I have an invite'), findsOneWidget);
  });

  testWidgets('the probe never changes the path the person chose', (
    tester,
  ) async {
    // Sign-in chosen on a server this device has no identity for: the probe
    // used to switch the form to joining.
    final state = await open(tester);
    await tester.tap(key('welcome-account'));
    await tester.pumpAndSettle();
    await tester.tap(key('welcome-signed-in-before'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'https://one.example.org',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(state.probes, <String>['https://one.example.org']);
    expect(find.text('SIGN IN'), findsOneWidget);
  });

  testWidgets('a new server offers its setup from the chosen path', (
    tester,
  ) async {
    await open(tester, fresh: true);
    await tester.tap(key('welcome-account'));
    await tester.pumpAndSettle();
    await tester.tap(key('welcome-signed-in-before'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'https://new.example.org',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text('SIGN IN'), findsOneWidget);
    await tester.tap(key('connect-set-up-this-server'));
    await tester.pumpAndSettle();
    expect(find.text('CREATE THE OWNER ACCOUNT'), findsOneWidget);
  });
}

class _State extends AppState {
  _State({
    required this.storedIdentity,
    required this.linkedHere,
    required this.fresh,
  }) : super(
          apiClientFactory: (_) =>
              ApiClient(baseUrl: 'https://one.example.org'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _QuietSync(),
        );

  final bool storedIdentity;
  final bool linkedHere;
  final bool fresh;
  final List<String> probes = <String>[];

  @override
  Future<bool> hasStoredDeviceIdentity() async => storedIdentity;

  @override
  Future<bool> hasStoredDeviceIdentityForOrigin(String baseUrl) async =>
      linkedHere;

  @override
  Future<SetupProbeResult> probeSetup(String baseUrl) async {
    probes.add(baseUrl);
    return SetupProbeResult(
      state: SetupProbeState.reachable,
      setupRequired: fresh,
    );
  }
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
