import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/auth/account_recovery_screen.dart';
import 'package:private_messenger/features/auth/connect_screen.dart';
import 'package:private_messenger/features/auth/recovery_follow_up_screen.dart';
import 'package:private_messenger/features/settings/recovery_key_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/ui/theme.dart';
import 'package:private_messenger/ui/widgets/account_recovery_banner.dart';

import 'k0_recovery_fakes.dart';
import 'test_crypto_service.dart';

/// K0 R3 and R4 screens: the recovery key setup, "Lost all your devices?",
/// the waiting screen, the forced follow-up and the notices on a signed-in
/// device.
void main() {
  late K0Server server;
  late MemoryLocalStore store;
  late K0Crypto crypto;

  setUp(() {
    server = K0Server();
    store = MemoryLocalStore();
    crypto = K0Crypto();
  });

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  AppState signedIn() => k0App(server, store, crypto)
    ..session = k0SignedIn
    ..api = K0Api(server);

  Widget app(Widget home) =>
      MaterialApp(theme: veritraLightTheme(), home: home);

  Future<void> confirmPassword(WidgetTester tester) async {
    expect(find.text('Confirm your password'), findsOneWidget);
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        'pw');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  testWidgets('R3: create, write down, type back, confirm the password',
      (tester) async {
    tall(tester);
    final state = signedIn();
    await tester.pumpWidget(app(RecoveryKeyScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.text('Not set'), findsOneWidget);

    await tester.tap(find.text('Create a recovery key'));
    await tester.pumpAndSettle();
    expect(find.text('Write down your recovery key'), findsOneWidget);
    expect(find.textContaining('ABCD EFGH JKMN PQRS'), findsOneWidget);

    await tester.tap(find.text('I wrote it down'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey<String>('recovery-key-confirm-field')),
        'ABCD-WRONG');
    await tester.tap(find.text('Save recovery key'));
    await tester.pumpAndSettle();
    expect(
        find.text('That is not the key shown. Check your paper and try '
            'again.'),
        findsOneWidget);
    expect(server.puts, isEmpty);

    await tester.enterText(
        find.byKey(const ValueKey<String>('recovery-key-confirm-field')),
        'abcd efgh jkmn pqrs\ttvwx yz01 2345 6789\nabcd efgh jkmn pqrs tvwx');
    await tester.tap(find.text('Save recovery key'));
    await tester.pumpAndSettle();
    // The server wants the password again before it takes the key.
    await confirmPassword(tester);
    expect(server.puts, hasLength(1));
    expect(find.text('Recovery key saved.'), findsOneWidget);
    // Every entropy copy was wiped once used.
    for (final copy in crypto.handedOut) {
      expect(copy, everyElement(0));
    }
    state.dispose();
  });

  testWidgets('R3: replacing names the old key and its effect', (tester) async {
    tall(tester);
    server.status = RecoveryKeyStatus(
        available: true, configured: true, setAt: DateTime.utc(2026, 10, 1));
    final state = signedIn();
    await tester.pumpWidget(app(RecoveryKeyScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.text('Replace the recovery key'), findsOneWidget);
    expect(find.textContaining('cancels any recovery that is waiting'),
        findsOneWidget);
    state.dispose();
  });

  testWidgets('R3: a server with recovery off offers no setup', (tester) async {
    tall(tester);
    server.status =
        const RecoveryKeyStatus(available: false, configured: false);
    final state = signedIn();
    await tester.pumpWidget(app(RecoveryKeyScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.text('This server has account recovery turned off'),
        findsOneWidget);
    final button = tester.widget<FilledButton>(find.ancestor(
        of: find.text('Create a recovery key'),
        matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(button.onPressed, isNull);
    state.dispose();
  });

  testWidgets('sign-in offers "Lost all your devices?" only with the engine',
      (tester) async {
    tall(tester);
    final native = k0App(server, store, crypto);
    await tester.pumpWidget(app(ConnectScreen(state: native)));
    await tester.pumpAndSettle();
    expect(find.text('Lost all your devices?'), findsOneWidget);
    native.dispose();

    for (final closed in <CryptoService>[
      UnavailableCryptoService(),
      TestOnlyCryptoService(),
    ]) {
      final state = k0App(server, store, closed);
      await tester.pumpWidget(app(ConnectScreen(state: state)));
      await tester.pumpAndSettle();
      expect(find.text('Lost all your devices?'), findsNothing);
      state.dispose();
    }
  });

  testWidgets('R4: the recovery form claims and leaves for the wait',
      (tester) async {
    tall(tester);
    final state = k0App(server, store, crypto);
    await tester.pumpWidget(app(Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => AccountRecoveryStartScreen(
                state: state, initialServer: k0Origin))),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Recover your account'), findsOneWidget);
    expect(find.textContaining('this device joins only after 7 days'),
        findsOneWidget);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), 'alice');
    await tester.enterText(fields.at(2), 'pw');
    await tester.enterText(
        find.byKey(const ValueKey<String>('recovery-key-field')),
        'ABCD–EFGH–JKMN–PQRS–TVWX–YZ01–2345'
        '–6789–ABCD–EFGH–JKMN–PQRS–TVWX');
    await tester.tap(find.text('Start recovery'));
    await tester.pumpAndSettle();
    expect(server.claims, hasLength(1));
    expect(crypto.signedOrigins, <String>[k0Origin]);
    expect(find.text('Recover your account'), findsNothing);
    expect(state.pendingAccountRecovery, isNotNull);
    state.dispose();
  });

  testWidgets('R4: a refused claim stays on the form with the reason',
      (tester) async {
    tall(tester);
    server.claimFailure = k0Error(401, 'invalid_credentials');
    final state = k0App(server, store, crypto);
    await tester.pumpWidget(
        app(AccountRecoveryStartScreen(state: state, initialServer: k0Origin)));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), 'alice');
    await tester.enterText(fields.at(2), 'wrong');
    await tester.enterText(
        find.byKey(const ValueKey<String>('recovery-key-field')), k0Display);
    await tester.tap(find.text('Start recovery'));
    await tester.pumpAndSettle();
    expect(
        find.text('The password or recovery key is wrong, the server '
            'address differs from the one you wrote down, or this account '
            'cannot be recovered.'),
        findsOneWidget);
    expect(state.pendingAccountRecovery, isNull);
    state.dispose();
  });

  testWidgets('R4: the wait shows ready_at, checks, and can be stopped',
      (tester) async {
    tall(tester);
    final state = k0App(server, store, crypto);
    await state.startAccountRecovery(
        baseUrl: k0Origin,
        username: 'alice',
        password: 'pw',
        recoveryKey: k0Display);
    await tester.pumpWidget(app(AccountRecoveryWaitingScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.text('Recovery is waiting'), findsOneWidget);
    expect(find.text('Account: alice'), findsOneWidget);
    expect(find.textContaining('This device joins your account after'),
        findsOneWidget);

    final polls = server.recoveryPolls;
    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();
    expect(server.recoveryPolls, polls + 1);

    await tester.tap(find.text('Stop recovery'));
    await tester.pumpAndSettle();
    expect(find.text('Stop recovery on this device?'), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Stop recovery')));
    await tester.pumpAndSettle();
    expect(state.pendingAccountRecovery, isNull);
    expect(crypto.abandons, 1);
    state.dispose();
  });

  testWidgets('R4: a lost answer asks for the password', (tester) async {
    tall(tester);
    final state = k0App(server, store, crypto);
    await state.startAccountRecovery(
        baseUrl: k0Origin,
        username: 'alice',
        password: 'pw',
        recoveryKey: k0Display);
    server.statusAnswers.add(const AccountRecoveryStatus(
        phase: AccountRecoveryPhase.completedWithoutToken,
        accountId: 'acct_me',
        deviceId: 'dev_new'));
    await state.checkAccountRecovery();
    await tester.pumpWidget(app(AccountRecoveryWaitingScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to finish'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'pw');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(server.logins.single['device_secret'], 'secret_new');
    expect(state.session?.deviceId, 'dev_new');
    expect(state.recoveryFollowUp, RecoveryFollowUpStep.recoveryKey);
    state.dispose();
  });

  testWidgets('follow-up: a new password ends it', (tester) async {
    tall(tester);
    final state = signedIn()..recoveryFollowUp = RecoveryFollowUpStep.password;
    await tester.pumpWidget(app(RecoveryFollowUpScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.text('Finish recovering your account'), findsOneWidget);
    expect(find.text('Last step: choose a new password.'), findsOneWidget);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'a new long password');
    await tester.enterText(fields.at(1), 'a new long password');
    await tester.tap(find.widgetWithText(FilledButton, 'Change password'));
    await tester.pumpAndSettle();
    await confirmPassword(tester);
    expect(server.passwords, <String>['a new long password']);
    expect(state.recoveryFollowUp, isNull);
    state.dispose();
  });

  testWidgets('follow-up: the recovery key step comes first', (tester) async {
    tall(tester);
    final state = signedIn()
      ..recoveryFollowUp = RecoveryFollowUpStep.recoveryKey;
    await tester.pumpWidget(app(RecoveryFollowUpScreen(state: state)));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('replace your recovery key and then your '
            'password'),
        findsOneWidget);
    expect(find.text('Create a recovery key'), findsOneWidget);
    state.dispose();
  });

  testWidgets('a waiting recovery shows on other devices and can be cancelled',
      (tester) async {
    tall(tester);
    final state = signedIn()
      ..recoveryKeyStatus = RecoveryKeyStatus(
        available: true,
        configured: true,
        pending: PendingRecoveryRequest(
            id: 'arr_9',
            deviceName: 'Unknown phone',
            readyAt: DateTime.utc(2026, 11, 8, 10)),
      );
    await tester
        .pumpWidget(app(Scaffold(body: AccountRecoveryBanner(state: state))));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Someone is recovering your account on '
            '“Unknown phone”'),
        findsOneWidget);
    await tester.tap(find.text('Cancel recovery'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel this recovery?'), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Cancel recovery')));
    await tester.pumpAndSettle();
    await confirmPassword(tester);
    expect(server.cancels, <String>['arr_9']);
    expect(find.text('Recovery cancelled.'), findsOneWidget);
    expect(find.textContaining('Someone is recovering'), findsNothing);
    state.dispose();
  });

  testWidgets('the leaked-password warning can be dismissed', (tester) async {
    tall(tester);
    final state = signedIn();
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    const scope = '$k0Origin\u0000acct_me\u0000';
    await store.saveSetting('k0.password_leak_day', '$scope$today');
    await state.refreshRecoveryNotices();
    await tester
        .pumpWidget(app(Scaffold(body: AccountRecoveryBanner(state: state))));
    await tester.pumpAndSettle();
    expect(
        find.text('Your password was used with a wrong recovery key many '
            'times. Change your password.'),
        findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.textContaining('wrong recovery key'), findsNothing);
    expect(
        await store.loadSetting('k0.password_leak_dismissed'), '$scope$today');
    state.dispose();
  });
}
