import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/features/auth/connect_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/theme.dart';

import 'test_crypto_service.dart';

void main() {
  testWidgets('on a fresh instance "Create owner" submits the owner form',
      (tester) async {
    // The form is a lazy ListView; lay all of it out.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = _FreshInstanceState();
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: veritraLightTheme(),
      home: ConnectScreen(state: state),
    ));
    await tester.enterText(
        find.byType(TextFormField).first, 'https://chat.example.org');
    await tester.pumpAndSettle();

    // Whatever mode the form opened in, one press finds the fresh instance
    // and shows the owner form.
    if (find.text('Create owner').evaluate().isEmpty) {
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
    }
    expect(find.text('Create owner'), findsWidgets);
    expect(state.owners, isEmpty);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), 'owner');
    await tester.enterText(fields.at(2), 'owner-password-123');
    await tester.enterText(fields.at(3), 'owner-password-123');
    await tester.enterText(fields.at(4), 'setup-token');
    await tester.pumpAndSettle();

    // The press that used to stop at "switch to owner mode" again.
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    expect(state.owners, <String>['owner/setup-token']);
  });

  group('submission', () {
    const one = 'https://one.example.org';
    const two = 'https://two.example.org';

    late _FormState state;

    /// Opens the form on a server that has users and this device linked, so
    /// it settles on sign-in: URL, username and password fields.
    Future<void> openSignIn(WidgetTester tester) async {
      // The form is a lazy ListView; lay all of it out.
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      state = _FormState();
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: veritraLightTheme(),
        home: ConnectScreen(state: state),
      ));
      await tester.enterText(find.byType(TextFormField).first, one);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(find.byType(TextFormField), findsNWidgets(3));
      await tester.enterText(find.byType(TextFormField).at(1), 'alice');
      await tester.enterText(find.byType(TextFormField).at(2), 'pw-original');
      await tester.pump();
    }

    Finder submitButton() => find.byType(FilledButton).last;

    testWidgets('editing the URL during the pre-flight sends nothing',
        (tester) async {
      await openSignIn(tester);
      final gate = Completer<void>();
      state.probeGates[one] = gate;
      await tester.tap(submitButton());
      await tester.pump();

      // The person moves to another server and types other credentials.
      await tester.enterText(find.byType(TextFormField).first, two);
      await tester.enterText(find.byType(TextFormField).at(1), 'mallory');
      await tester.enterText(find.byType(TextFormField).at(2), 'pw-other');
      await tester.pump();
      gate.complete();
      await tester.pump(const Duration(milliseconds: 100));

      expect(state.logins, isEmpty,
          reason: 'nothing may reach the server the form no longer shows');
    });

    testWidgets('editing the URL during the stored-device lookup sends nothing',
        (tester) async {
      await openSignIn(tester);
      final gate = Completer<void>();
      state.identityGates[one] = gate;
      await tester.tap(submitButton());
      await tester.pump();

      await tester.enterText(find.byType(TextFormField).first, two);
      await tester.enterText(find.byType(TextFormField).at(2), 'pw-other');
      await tester.pump();
      gate.complete();
      await tester.pump(const Duration(milliseconds: 100));

      expect(state.logins, isEmpty);
    });

    testWidgets('the credentials sent are the ones present at the tap',
        (tester) async {
      await openSignIn(tester);
      final gate = Completer<void>();
      state.probeGates[one] = gate;
      await tester.tap(submitButton());
      await tester.pump();

      await tester.enterText(find.byType(TextFormField).at(1), 'mallory');
      await tester.enterText(find.byType(TextFormField).at(2), 'pw-other');
      await tester.pump();
      gate.complete();
      await tester.pump(const Duration(milliseconds: 100));

      expect(state.logins, <String>['$one|alice|pw-original']);
    });

    testWidgets('a second tap during the pre-flight starts nothing',
        (tester) async {
      await openSignIn(tester);
      final gate = Completer<void>();
      state.probeGates[one] = gate;
      // Two taps in one frame, before the button can be rebuilt.
      await tester.tap(submitButton());
      await tester.tap(submitButton());
      await tester.pump();

      expect(tester.widget<FilledButton>(submitButton()).onPressed, isNull,
          reason: 'the button reads as disabled while submitting');
      await tester.tap(submitButton(), warnIfMissed: false);
      await tester.pump();
      gate.complete();
      await tester.pump(const Duration(milliseconds: 100));

      expect(state.logins, <String>['$one|alice|pw-original']);
      // The form is usable again afterwards.
      expect(tester.widget<FilledButton>(submitButton()).onPressed, isNotNull);
    });
  });

  group('URL listener', () {
    testWidgets('a caret move does not clear the chosen mode or re-probe',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = _FormState();
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: veritraLightTheme(),
        home: ConnectScreen(state: state),
      ));
      await tester.enterText(
          find.byType(TextFormField).first, 'https://one.example.org');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(state.probes, <String>['https://one.example.org']);
      expect(find.text('SIGN IN'), findsOneWidget);

      // The person picks another way to connect.
      await tester.tap(find.text('Other ways to connect'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Join with an invite'));
      await tester.pumpAndSettle();
      expect(find.text('JOIN WITH AN INVITE'), findsOneWidget);

      // Clicking into the field, or selecting its text, changes only the
      // selection.
      final field = tester.widget<TextField>(find.byType(TextField).first);
      field.controller!.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      field.controller!.selection =
          const TextSelection(baseOffset: 0, extentOffset: 5);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();

      expect(state.probes, <String>['https://one.example.org'],
          reason: 'no new probe for an unchanged URL');
      expect(find.text('JOIN WITH AN INVITE'), findsOneWidget,
          reason: 'the chosen mode stays');
      expect(find.text('Checking the server…'), findsNothing);
    });

    testWidgets('a real change of the URL text still probes again',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = _FormState();
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: veritraLightTheme(),
        home: ConnectScreen(state: state),
      ));
      await tester.enterText(
          find.byType(TextFormField).first, 'https://one.example.org');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      await tester.enterText(
          find.byType(TextFormField).first, 'https://two.example.org');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(state.probes,
          <String>['https://one.example.org', 'https://two.example.org']);
    });
  });
}

class _FreshInstanceState extends AppState {
  _FreshInstanceState()
      : super(
          apiClientFactory: (_) =>
              ApiClient(baseUrl: 'https://chat.example.org'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _QuietSync(),
        );

  final List<String> owners = <String>[];

  @override
  Future<SetupProbeResult> probeSetup(String baseUrl) async =>
      const SetupProbeResult(
          state: SetupProbeState.reachable, setupRequired: true);

  @override
  Future<bool> hasStoredDeviceIdentityForOrigin(String baseUrl) async => false;

  @override
  Future<void> createOwner(String baseUrl, String username, String password,
      String setupToken) async {
    owners.add('$username/$setupToken');
  }
}

/// A server with users, on which this device is already linked: the form
/// settles on sign-in. Probes and the stored-device lookup can be held per
/// origin to edit the form while they run.
class _FormState extends AppState {
  _FormState()
      : super(
          apiClientFactory: (_) =>
              ApiClient(baseUrl: 'https://one.example.org'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _QuietSync(),
        );

  final Map<String, Completer<void>> probeGates = <String, Completer<void>>{};
  final Map<String, Completer<void>> identityGates =
      <String, Completer<void>>{};
  final List<String> probes = <String>[];
  final List<String> logins = <String>[];

  @override
  Future<SetupProbeResult> probeSetup(String baseUrl) async {
    probes.add(baseUrl);
    await probeGates[baseUrl]?.future;
    return const SetupProbeResult(
        state: SetupProbeState.reachable, setupRequired: false);
  }

  @override
  Future<bool> hasStoredDeviceIdentityForOrigin(String baseUrl) async {
    await identityGates[baseUrl]?.future;
    return true;
  }

  @override
  Future<void> login(String baseUrl, String username, String password) async {
    logins.add('$baseUrl|$username|$password');
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
