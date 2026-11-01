import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/errors.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'k0_recovery_fakes.dart';

/// K0 R3 (recovery key setup) and R4 (recovery when every device is lost)
/// through AppState against a fake server (docs/designs/K0-recovery-
/// enrollment.md).
void main() {
  final l10n = englishL10n;
  late K0Server server;
  late MemoryLocalStore store;
  late K0Crypto crypto;
  late List<K0Api> apis;
  late AppState state;

  setUp(() {
    server = K0Server();
    store = MemoryLocalStore();
    crypto = K0Crypto();
    apis = <K0Api>[];
    state = k0App(server, store, crypto, apis: apis);
  });

  tearDown(() => state.dispose());

  Future<void> signIn() async {
    await store.saveSession(k0SignedIn);
    await state.tryRestoreSession();
    expect(state.session?.token, 'tok_old');
  }

  Future<void> waitFor(Future<bool> Function() done) async {
    for (var i = 0; i < 200; i++) {
      if (await done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('condition not reached');
  }

  Future<PendingAccountRecovery?> persisted() async =>
      PendingAccountRecovery.decode(
          await store.loadSetting('k0.pending_recovery'));

  Future<void> claim({String key = k0Display}) async {
    final ok = await state.startAccountRecovery(
      baseUrl: k0Origin,
      username: ' alice ',
      password: 'pw',
      recoveryKey: key,
    );
    expect(ok, isTrue, reason: state.errorFor(Ops.accountRecovery));
  }

  group('R3 recovery key setup', () {
    test('generate, confirm by typing, then PUT only the public values',
        () async {
      await signIn();
      expect(state.recoveryAvailable, isTrue);
      final draft = await state.createRecoveryKeyDraft();
      expect(draft.display, k0Display);
      expect(await state.recoveryKeyMatches(draft, 'nope'), isFalse);
      // Written in groups, with tabs and a line break, in lower case.
      final typed = 'abcd-efgh\tjkmn pqrs\r\ntvwx–yz01 2345-6789-abcd'
          'efghjkmnpqrstvwx';
      expect(await state.recoveryKeyMatches(draft, typed), isTrue);
      // The decoded copy was wiped.
      expect(crypto.handedOut.last, everyElement(0));

      expect(await state.saveRecoveryKey(draft),
          RecoveryActionResult.needsRecentAuth);
      expect(server.puts, isEmpty);
      expect(await state.reauthenticate('pw'), isTrue);
      expect(await state.saveRecoveryKey(draft), RecoveryActionResult.done);
      expect(server.puts.single['rk_auth_pub'], List<int>.filled(32, 0xA1));
      expect(server.puts.single['rk_id'], List<int>.filled(16, 0xB2));
      expect(state.recoveryKeyStatus?.configured, isTrue);

      draft.dispose();
      expect(crypto.handedOut.first, everyElement(0));
    });

    test('a build without the native engine offers nothing (fails closed)',
        () async {
      final closed = k0App(server, store, UnavailableCryptoService());
      addTearDown(closed.dispose);
      expect(closed.recoveryAvailable, isFalse);
      await expectLater(
          closed.createRecoveryKeyDraft(), throwsA(isA<UserFacingException>()));
      expect(
          await closed.startAccountRecovery(
              baseUrl: k0Origin,
              username: 'alice',
              password: 'pw',
              recoveryKey: k0Display),
          isFalse);
      expect(
          closed.errorFor(Ops.accountRecovery), l10n.recoveryUnavailableHere);
      expect(server.reserved, isEmpty);
    });
  });

  group('R4 claim', () {
    test('signs over the canonical origin and keeps the claim', () async {
      final ok = await state.startAccountRecovery(
        baseUrl: 'HTTPS://Chat.Example.ORG:443/',
        username: ' alice ',
        password: 'pw',
        recoveryKey: ' abcd—efgh-jkmn-pqrs-tvwx-yz01-2345-6789-abcd-efgh-'
            'jkmn-pqrs-tvwx\n',
      );
      expect(ok, isTrue, reason: state.errorFor(Ops.accountRecovery));
      // Byte for byte the origin the app talks to.
      expect(apis.last.baseUrl, k0Origin);
      expect(crypto.signedOrigins, <String>[k0Origin]);
      expect(crypto.signedChallenges.single, <int>[9, 8, 7]);
      expect(crypto.decodedTexts.single, k0Display.toLowerCase());
      expect(server.reserved, <String>['alice']);
      final body = server.claims.single;
      expect(body.keys, isNot(contains('username')));
      expect(body['recovery_signature'], List<int>.filled(64, 0x5E));
      expect(crypto.seals, 1);
      expect(crypto.handedOut.single, everyElement(0));

      final pending = state.pendingAccountRecovery!;
      expect(pending.requestId, 'arr_1');
      expect(pending.deviceId, 'dev_new');
      expect(pending.origin, k0Origin);
      final saved = (await persisted())!;
      expect(saved.claimToken, 'claim_tok');
      expect(saved.deviceSecret, 'secret_new');
      expect(saved.mlsState.sealedState, <int>[4, 4, 4]);
      expect(saved.mlsState.changes.single.sealed, <int>[5]);
    });

    test('a key that does not decode never reaches the network', () async {
      expect(
          await state.startAccountRecovery(
              baseUrl: k0Origin,
              username: 'alice',
              password: 'pw',
              recoveryKey: 'ABCD-EFGH'),
          isFalse);
      expect(state.errorFor(Ops.accountRecovery), l10n.recoveryKeyUnreadable);
      expect(apis, isEmpty);
      expect(server.reserved, isEmpty);
    });

    test('a restored backup of another account stops before the claim',
        () async {
      await store.saveSession(restoredAccountSession(
          baseUrl: k0Origin, accountId: 'acct_other', username: 'alice'));
      expect(
          await state.startAccountRecovery(
              baseUrl: k0Origin,
              username: 'alice',
              password: 'pw',
              recoveryKey: k0Display),
          isFalse);
      expect(
          state.errorFor(Ops.accountRecovery), l10n.recoveryBackupOtherAccount);
      expect(crypto.enrollments, 0);
      expect(server.claims, isEmpty);
      expect(crypto.handedOut.single, everyElement(0));
    });

    test('a refused claim says so and drops the new identity', () async {
      server.claimFailure = k0Error(401, 'invalid_credentials');
      expect(
          await state.startAccountRecovery(
              baseUrl: k0Origin,
              username: 'alice',
              password: 'wrong',
              recoveryKey: k0Display),
          isFalse);
      expect(state.errorFor(Ops.accountRecovery), l10n.recoveryClaimRefused);
      expect(crypto.abandons, 1);
      expect(state.pendingAccountRecovery, isNull);
      expect(await persisted(), isNull);
    });

    test('the server backoff is shown as such', () async {
      server.claimFailure = k0Error(429, 'recovery_backoff');
      expect(
          await state.startAccountRecovery(
              baseUrl: k0Origin,
              username: 'alice',
              password: 'pw',
              recoveryKey: k0Display),
          isFalse);
      expect(state.errorFor(Ops.accountRecovery), l10n.apiErrorRecoveryBackoff);
    });

    test('the claim survives a restart and is polled again', () async {
      await claim();
      state.dispose();
      final polls = server.recoveryPolls;
      state = k0App(server, store, crypto, apis: apis);
      await state.tryRestoreSession();
      expect(state.pendingAccountRecovery?.requestId, 'arr_1');
      await pumpEventQueue();
      expect(server.recoveryPolls, greaterThan(polls));
      expect(state.session, isNull);
    });
  });

  group('R4 wait and completion', () {
    test('a waiting answer moves ready_at', () async {
      await claim();
      server.statusAnswers.add(AccountRecoveryStatus(
          phase: AccountRecoveryPhase.waiting,
          readyAt: DateTime.utc(2026, 11, 9)));
      expect(await state.checkAccountRecovery(), isTrue);
      expect(state.pendingAccountRecovery!.readyAt, DateTime.utc(2026, 11, 9));
      expect((await persisted())!.readyAt, DateTime.utc(2026, 11, 9));
    });

    test('cancelled by the owner: the claim is dropped', () async {
      await claim();
      server.statusAnswers.add(k0Error(410, 'recovery_cancelled'));
      expect(await state.checkAccountRecovery(), isFalse);
      expect(state.errorFor(Ops.accountRecovery), l10n.recoveryRequestEnded);
      expect(state.pendingAccountRecovery, isNull);
      expect(await persisted(), isNull);
      expect(crypto.abandons, 1);
    });

    test('a network failure keeps the claim', () async {
      await claim();
      server.statusAnswers.add(k0Error(503, 'storage_unavailable'));
      expect(await state.checkAccountRecovery(), isFalse);
      expect(state.pendingAccountRecovery, isNotNull);
      expect(await persisted(), isNotNull);
    });

    test('completion enrolls this device with the claimed identity', () async {
      await store.saveSession(restoredAccountSession(
          baseUrl: k0Origin, accountId: 'acct_me', username: 'alice'));
      await claim();
      server.statusAnswers.add(const AccountRecoveryStatus(
        phase: AccountRecoveryPhase.completed,
        accountId: 'acct_me',
        deviceId: 'dev_new',
        username: 'alice',
        role: 'member',
        token: 'tok_new',
      ));
      expect(await state.checkAccountRecovery(), isTrue,
          reason: state.errorFor(Ops.accountRecovery));
      final session = state.session!;
      expect(session.token, 'tok_new');
      expect(session.deviceId, 'dev_new');
      expect(session.deviceSecret, 'secret_new');
      expect((await store.loadSession())!.token, 'tok_new');
      expect(crypto.resumed.single.sealedState, <int>[4, 4, 4]);
      expect(crypto.activated.last.deviceId, 'dev_new');
      expect(await store.loadSyncCursor(), 0);
      expect(state.pendingAccountRecovery, isNull);
      expect(await persisted(), isNull);
      expect(state.recoveryFollowUp, RecoveryFollowUpStep.recoveryKey);
    });

    test('a substituted device is refused', () async {
      await claim();
      server.statusAnswers.add(const AccountRecoveryStatus(
        phase: AccountRecoveryPhase.completed,
        accountId: 'acct_me',
        deviceId: 'dev_attacker',
        token: 'tok_new',
      ));
      expect(await state.checkAccountRecovery(), isFalse);
      expect(state.session, isNull);
      expect(state.pendingAccountRecovery, isNotNull);
    });

    test('a lost answer finishes with the password and the claim secret',
        () async {
      await claim();
      server.statusAnswers.add(const AccountRecoveryStatus(
        phase: AccountRecoveryPhase.completedWithoutToken,
        accountId: 'acct_me',
        deviceId: 'dev_new',
      ));
      expect(await state.checkAccountRecovery(), isTrue);
      expect(state.pendingAccountRecovery!.needsLogin, isTrue);
      expect((await persisted())!.needsLogin, isTrue);

      expect(await state.finishAccountRecoveryWithPassword('bad'), isFalse);
      expect(
          state.errorFor(Ops.accountRecovery), l10n.apiErrorInvalidCredentials);
      expect(state.session, isNull);

      expect(await state.finishAccountRecoveryWithPassword('pw'), isTrue);
      expect(server.logins.last, <String, Object?>{
        'username': 'alice',
        'password': 'pw',
        'device_id': 'dev_new',
        'device_secret': 'secret_new',
      });
      expect(state.session!.token, 'tok_login');
      expect(state.recoveryFollowUp, RecoveryFollowUpStep.recoveryKey);
    });

    test('the forced follow-up survives a restart and ends with a password',
        () async {
      await claim();
      server.statusAnswers.add(const AccountRecoveryStatus(
        phase: AccountRecoveryPhase.completed,
        accountId: 'acct_me',
        deviceId: 'dev_new',
        token: 'tok_new',
      ));
      await state.checkAccountRecovery();
      expect(state.recoveryFollowUp, RecoveryFollowUpStep.recoveryKey);

      // Killed here: the next start opens the follow-up again.
      state.dispose();
      state = k0App(server, store, crypto, apis: apis);
      await state.tryRestoreSession();
      expect(state.recoveryFollowUp, RecoveryFollowUpStep.recoveryKey);

      final draft = await state.createRecoveryKeyDraft();
      expect(await state.saveRecoveryKey(draft),
          RecoveryActionResult.needsRecentAuth);
      await state.reauthenticate('pw');
      expect(await state.saveRecoveryKey(draft), RecoveryActionResult.done);
      draft.dispose();
      expect(state.recoveryFollowUp, RecoveryFollowUpStep.password);

      state.dispose();
      state = k0App(server, store, crypto, apis: apis);
      await state.tryRestoreSession();
      expect(state.recoveryFollowUp, RecoveryFollowUpStep.password);
      await state.changePassword('a new long password');
      expect(server.passwords.single, 'a new long password');
      expect(state.recoveryFollowUp, isNull);
      expect(await store.loadSetting('k0.recovery_follow_up'), '');
    });

    test('a crash between session and MLS state reopens the identity',
        () async {
      await claim();
      // As if the app stopped right after saving the session.
      await store.saveSession(server.session());
      state.dispose();
      final before = crypto.resumed.length;
      state = k0App(server, store, crypto, apis: apis);
      await state.tryRestoreSession();
      expect(crypto.resumed.length, before + 1);
      expect(crypto.activated.first.deviceId, 'dev_new');
      expect(await persisted(), isNull);
    });

    test('abandoning drops the claim locally', () async {
      await claim();
      await state.abandonAccountRecovery();
      expect(state.pendingAccountRecovery, isNull);
      expect(await persisted(), isNull);
      expect(crypto.abandons, 1);
    });
  });

  group('notices on a signed-in device', () {
    SyncEvent event(int id, String type, Object? payload) => SyncEvent(
        id: id,
        type: type,
        payload: payload,
        createdAt: DateTime.now().toUtc());

    test('a pending recovery is read from the server and can be cancelled',
        () async {
      server.status = RecoveryKeyStatus(
        available: true,
        configured: true,
        setAt: DateTime.utc(2026, 10, 1),
        pending: PendingRecoveryRequest(
            id: 'arr_9',
            deviceName: 'Unknown phone',
            readyAt: DateTime.utc(2026, 11, 8)),
      );
      await signIn();
      expect(state.recoveryKeyStatus?.pending?.id, 'arr_9');

      expect(await state.cancelAccountRecoveryRequest('arr_9'),
          RecoveryActionResult.needsRecentAuth);
      expect(server.cancels, isEmpty);
      await state.reauthenticate('pw');
      expect(await state.cancelAccountRecoveryRequest('arr_9'),
          RecoveryActionResult.done);
      expect(server.cancels, <String>['arr_9']);
      expect(state.recoveryKeyStatus?.pending, isNull);
      // Signed in still: the 403 never ended the session.
      expect(state.session, isNotNull);
    });

    test('account events from sync refresh the status and raise the warning',
        () async {
      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      server.events.addAll(<SyncEvent>[
        event(1, 'account.recovery.pending', <String, Object?>{
          'request_id': 'arr_2',
          'device_name': 'Phone',
          'ready_at': '2026-11-08T10:00:00Z',
        }),
        event(2, 'account.password_leak_suspected',
            <String, Object?>{'day': today}),
      ]);
      await signIn();
      final reads = server.statusReads;
      await waitFor(() async => await store.loadSyncCursor() == 2);
      await waitFor(() async => server.statusReads > reads);
      expect(state.passwordLeakWarningDay, today);
      await waitFor(() async => state.passwordLeakWarningDay == today);

      await state.dismissPasswordLeakWarning();
      expect(state.passwordLeakWarningDay, isNull);
      // Still dismissed after a restart.
      state.dispose();
      state = k0App(server, store, crypto, apis: apis);
      await state.tryRestoreSession();
      expect(state.passwordLeakWarningDay, isNull);
    });

    test('an old leak warning replayed from cursor 0 stays hidden', () async {
      server.events.add(event(1, 'account.password_leak_suspected',
          <String, Object?>{'day': '2025-01-01'}));
      await signIn();
      await waitFor(() async => await store.loadSyncCursor() == 1);
      expect(state.passwordLeakWarningDay, isNull);
    });

    test('a password change ends the warning', () async {
      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      server.events.add(event(1, 'account.password_leak_suspected',
          <String, Object?>{'day': today}));
      await signIn();
      await waitFor(() async => state.passwordLeakWarningDay == today);
      await state.changePassword('a new long password');
      expect(state.passwordLeakWarningDay, isNull);
    });
  });
}
