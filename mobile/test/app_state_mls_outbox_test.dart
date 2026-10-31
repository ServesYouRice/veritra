// MLS outbox and membership reconcile (I34, I51): refused commit bundles back
// off and are reconciled again by a wake timer (TASK-029); accepted items
// whose local finish failed are retried (TASK-030); storage failures in the
// outbox workers are contained and retried with backoff (TASK-042); a drained
// revocation commit is not made twice (TASK-051); durable local failures are
// terminal and labelled (TASK-052); one failing revocation or change neither
// stops the others nor re-claims on every catch-up (TASK-035).
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a refused membership bundle', () {
    for (final status in <int>[422, 403, 400]) {
      test('$status: is not claimed or restaged again before its backoff',
          () async {
        final h = await _Harness.start(
            refuse: () => ApiException(status, '{"error":"invalid_input"}'));
        await _waitFor(() => h.api.bundles.isNotEmpty);
        // Sync frames keep asking for catch-ups, as on a busy connection.
        await h.frames(const Duration(milliseconds: 2500));
        // Default backoff: attempts at 0 s, 1 s, 3 s. One of slack for timing.
        expect(h.api.claims.length, inInclusiveRange(1, 3));
        expect(h.api.bundles.length, inInclusiveRange(1, 3));
        expect(h.crypto.abandoned, h.api.bundles.length,
            reason: 'every refused bundle is still dropped');
        h.state.dispose();
      });
    }

    test('409 at an unchanged epoch is rate-limited too', () async {
      final h = await _Harness.start(
          refuse: () => ApiException(409, '{"error":"mls_change_pending"}'));
      await _waitFor(() => h.api.bundles.isNotEmpty);
      await h.frames(const Duration(milliseconds: 2500));
      expect(h.api.claims.length, inInclusiveRange(1, 3));
      expect(h.api.bundles.length, inInclusiveRange(1, 3));
      h.state.dispose();
    });

    test('keeps retrying on the capped schedule, with no terminal pause',
        () async {
      final h = await _Harness.start(
          refuse: () => ApiException(422, '{"error":"invalid_input"}'),
          configure: (state) => state
            ..mlsRetryBase = const Duration(milliseconds: 200)
            ..mlsRetryCap = const Duration(milliseconds: 400));
      await _waitFor(() => h.api.bundles.isNotEmpty);
      await h.frames(const Duration(seconds: 3));
      // Attempts at 0, 0.2, 0.6, 1.0, 1.4 ... s: about eight in 3 s.
      expect(h.api.claims.length, inInclusiveRange(4, 10));
      expect(h.api.bundles.length, h.api.claims.length);
      expect(h.state.mlsConversationFailed('conv_a'), isFalse);
      h.state.dispose();
    });

    test('409 at a new epoch restages without waiting', () async {
      var first = true;
      final h = await _Harness.start(
          fakes: (api, crypto) => api.onBundle = (conversationId, bundle) {
                if (!first) return;
                first = false;
                // Another member's commit won epoch 3; catching up applies
                // it.
                api.serverEpochs[conversationId] = 4;
                crypto.epochs[conversationId] = 4;
                throw ApiException(
                    409, '{"error":"mls_epoch_conflict","epoch":4}');
              },
          configure: (state) =>
              state.mlsRetryBase = const Duration(seconds: 30));
      await _waitFor(() => h.crypto.completed == 1,
          timeout: const Duration(seconds: 5));
      expect(h.api.bundles, hasLength(2));
      expect(h.crypto.abandoned, 1);
      h.state.dispose();
    });

    test('a staged bundle still in flight does not spin the wake', () async {
      final h = await _Harness.start(
          refuseOnce: <Object>[ApiException(422, '{"error":"invalid_input"}')],
          configure: (state) =>
              state.mlsRetryBase = const Duration(milliseconds: 200));
      await _waitFor(() => h.api.bundles.isNotEmpty);
      // The next bundle never gets an answer.
      h.api.hangBundles = true;
      await _waitFor(() => h.api.bundles.length == 2);
      final catchUps = h.syncCalls;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(h.syncCalls - catchUps, lessThanOrEqualTo(1));
      h.state.dispose();
    });

    test('is reconciled again by the wake alone once its backoff expires',
        () async {
      // An idle connected session: no sync frames, no resume, nothing new
      // queued. The first bundle is refused, the next one accepted.
      final h = await _Harness.start(refuseOnce: <Object>[
        ApiException(422, '{"error":"invalid_input"}'),
      ]);
      await _waitFor(() => h.api.bundles.isNotEmpty);
      // The refusal's own catch-up succeeds before the deadline; it must
      // neither restage at once nor cancel the wake.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(h.api.claims, hasLength(1));
      expect(h.api.bundles, hasLength(1));
      expect(h.syncCalls, greaterThan(1),
          reason: 'the refusal asks for a catch-up');

      await _waitFor(() => h.crypto.completed == 1,
          timeout: const Duration(seconds: 5));
      expect(h.api.claims, hasLength(2));
      expect(h.api.bundles, hasLength(2));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(h.api.claims, hasLength(2));
      expect(h.api.bundles, hasLength(2));
      h.state.dispose();
    });

    test('wakes nothing after dispose', () async {
      final h = await _Harness.start(refuseOnce: <Object>[
        ApiException(422, '{"error":"invalid_input"}'),
      ]);
      await _waitFor(() => h.api.bundles.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      h.state.dispose();
      final claims = h.api.claims.length;
      final bundles = h.api.bundles.length;
      final pendingChanges = h.api.pendingChangeCalls;
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(h.api.claims.length, claims);
      expect(h.api.bundles.length, bundles);
      expect(h.api.pendingChangeCalls, pendingChanges);
    });

    test('wakes nothing after sign-out', () async {
      final h = await _Harness.start(refuseOnce: <Object>[
        ApiException(422, '{"error":"invalid_input"}'),
      ]);
      await _waitFor(() => h.api.bundles.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await h.state.logout();
      expect(h.state.session, isNull);
      final claims = h.api.claims.length;
      final bundles = h.api.bundles.length;
      final pendingChanges = h.api.pendingChangeCalls;
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(h.api.claims.length, claims);
      expect(h.api.bundles.length, bundles);
      expect(h.api.pendingChangeCalls, pendingChanges);
      h.state.dispose();
    });
  });

  group('an accepted control message that fails to finish locally', () {
    test('a commit that fails to merge is finished by the retry timer',
        () async {
      final h = await _Harness.start(pending: const <String>{});
      await _settle();
      // The failure comes after startup, with the connection already
      // online, so no later wake would pick the bundle up.
      h.crypto.completeFailures.add(StateError('merge failed'));
      await h.state.addConversationMember('conv_a', 'acct_bob');
      await _waitFor(() => h.crypto.completeCalls == 1);
      await _waitFor(() => h.crypto.completed == 1,
          timeout: const Duration(seconds: 6));
      expect(h.api.bundles, hasLength(1),
          reason: 'the accepted bundle is finished, not sent again');
      expect(h.crypto.abandoned, 0, reason: 'an accepted commit is kept');
      expect(await h.store.pendingMlsMessages(), isEmpty);
      h.state.dispose();
    });

    test('a sent message whose removal fails is removed by the retry timer',
        () async {
      final store = _FlakyStore();
      final h = await _Harness.start(pending: const <String>{}, store: store);
      await _settle();
      store.removeFailures = 1;
      await _queue(store, <PendingMlsMessage>[_message('c1', 'conv_a')]);
      h.sync.frame();
      await _waitFor(() => h.api.messages.isNotEmpty);
      await _waitFor(() async => (await store.pendingMlsMessages()).isEmpty,
          timeout: const Duration(seconds: 6));
      expect(h.api.messages, <String>['c1']);
      h.state.dispose();
    });

    test('a failed finish is retried with growing backoff', () async {
      final h = await _Harness.start(pending: const <String>{});
      await _settle();
      h.crypto.completeFailures
          .addAll(List<Object>.generate(50, (_) => StateError('stuck')));
      await h.state.addConversationMember('conv_a', 'acct_bob');
      await _waitFor(() => h.crypto.completeCalls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 4500));
      // 1 s, then 2 s: three tries in 4.5 s, one more of slack.
      expect(h.crypto.completeCalls, inInclusiveRange(2, 4));
      expect(h.api.bundles, hasLength(1));
      expect(h.crypto.abandoned, 0);
      expect(h.state.mlsConversationFailed('conv_a'), isFalse);
      h.state.dispose();
    });

    test('a queue read failure while scheduling still arms a retry', () async {
      final store = _FlakyStore();
      final h = await _Harness.start(pending: const <String>{}, store: store);
      await _settle();
      await _queue(store, <PendingMlsMessage>[_message('c1', 'conv_a')]);
      // The worker's read and the scheduler's read both fail.
      store.mlsReadFailures = 2;
      h.sync.frame();
      await _waitFor(() => store.mlsReadFailures == 0);
      await _waitFor(() => h.api.messages.contains('c1'),
          timeout: const Duration(seconds: 6));
      await _waitFor(() async => (await store.pendingMlsMessages()).isEmpty);
      h.state.dispose();
    });
  });

  group('storage failures in the outbox workers', () {
    test('a store that keeps failing is retried with backoff, not spun',
        () async {
      final store = _FlakyStore();
      final h = await _Harness.start(pending: const <String>{}, store: store);
      await _settle();
      await _queue(store, <PendingMlsMessage>[_message('c1', 'conv_a')]);
      store.mlsReadFailures = 1000;
      h.sync.frame();
      await _waitFor(() => store.mlsReads > 0);
      final reads = store.mlsReads;
      await Future<void>.delayed(const Duration(seconds: 3));
      // Fallback timers at 2 s and then 8 s; a 100 ms spin would read ~60
      // times.
      expect(store.mlsReads - reads, lessThanOrEqualTo(8));
      store.mlsReadFailures = 0;
      h.state.dispose();
    });

    Future<(AppState, _Api, List<Object>)> appOutbox(
        _FlakyStore store, int failures) async {
      final api = _Api();
      final errors = <Object>[];
      late AppState state;
      await runZonedGuarded(() async {
        state = AppState(
          apiClientFactory: (_) => api,
          cryptoService: TestOnlyCryptoService(),
          localStore: store,
          syncServiceFactory: (_, __) => _Sync(),
        )
          ..api = api
          ..session = _session
          ..conversations = <Conversation>[
            Conversation(id: 'conv_a', kind: 'group'),
          ];
        await store.enqueueEnvelope(MessageEnvelope(
          conversationId: 'conv_a',
          idempotencyKey: 'app_1',
          ciphertext: const <int>[1],
          cryptoProtocol: 'test-only-not-production',
        ));
        store.envelopeReadFailures = failures;
        // A resume flushes the outbox; its first read fails.
        state.handleAppLifecycleState(AppLifecycleState.resumed);
      }, (error, _) => errors.add(error));
      return (state, api, errors);
    }

    test('an outbox read failure is contained and retried', () async {
      final store = _FlakyStore();
      final (state, api, errors) = await appOutbox(store, 1);
      await _waitFor(() => store.envelopeReadFailures == 0);
      await _waitFor(() => api.envelopes.contains('app_1'),
          timeout: const Duration(seconds: 6));
      expect(errors, isEmpty, reason: 'no storage error escapes the worker');
      state.dispose();
    });

    test('a read failure in the retry scheduler still arms a retry', () async {
      final store = _FlakyStore();
      // The worker's read and then the scheduler's read fail.
      final (state, api, errors) = await appOutbox(store, 2);
      await _waitFor(() => store.envelopeReadFailures == 0);
      await _waitFor(() => api.envelopes.contains('app_1'),
          timeout: const Duration(seconds: 8));
      expect(errors, isEmpty);
      state.dispose();
    });

    test('an outbox that keeps failing is retried with backoff, not spun',
        () async {
      final store = _FlakyStore();
      final (state, api, errors) = await appOutbox(store, 1000);
      await _waitFor(() => store.envelopeReads > 0);
      final reads = store.envelopeReads;
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(store.envelopeReads - reads, lessThanOrEqualTo(8));
      expect(api.envelopes, isEmpty);
      expect(errors, isEmpty);
      store.envelopeReadFailures = 0;
      state.dispose();
    });
  });

  group('a revocation this device coordinates', () {
    MlsRevocation revocation(String state) => MlsRevocation(
          conversationId: 'conv_a',
          revokedDeviceId: 'dev_gone',
          revokedAccountId: 'acct_me',
          coordinatorDeviceId: 'dev_me',
          state: state,
          commitMessageId: state == 'pending' ? null : 'mls_rev1',
          requestedAt: DateTime.utc(2026, 10, 31),
        );

    /// From the next fetch on, the server lists one revocation and [queued]
    /// waits in the outbox before it, as after a restart. The revocation
    /// moves to `commit_submitted` once `rev1` (its commit) is delivered.
    void listRevocation(_Harness h, PendingMlsMessage queued) {
      var listed = false;
      h.api.revocationsHook = () async {
        if (!listed) {
          listed = true;
          await _queue(h.store, <PendingMlsMessage>[queued]);
        }
        return <MlsRevocation>[
          revocation(
              h.api.messages.contains('rev1') ? 'commit_submitted' : 'pending'),
        ];
      };
    }

    test('makes no second commit after draining its queued one', () async {
      final h = await _Harness.start(pending: const <String>{});
      await _settle();
      listRevocation(
          h,
          PendingMlsMessage(
            idempotencyKey: 'rev1',
            conversationId: 'conv_a',
            kind: 'commit',
            payload: const <int>[1],
            revocationDeviceId: 'dev_gone',
          ));
      h.state.handleAppLifecycleState(AppLifecycleState.paused);
      h.state.handleAppLifecycleState(AppLifecycleState.resumed);
      await _waitFor(() => h.api.messages.contains('rev1'));
      await _settle();
      expect(h.crypto.revocationCommits, 0,
          reason: 'the server already has this revocation\'s commit');
      expect(h.api.messages, <String>['rev1']);
      h.state.dispose();
    });

    test('still commits when the drained work was something else', () async {
      final h = await _Harness.start(pending: const <String>{});
      await _settle();
      listRevocation(h, _message('other', 'conv_a'));
      h.state.handleAppLifecycleState(AppLifecycleState.paused);
      h.state.handleAppLifecycleState(AppLifecycleState.resumed);
      await _waitFor(() => h.crypto.revocationCommits == 1);
      await _waitFor(() => h.api.messages.contains('rev1'));
      expect(h.api.messages, <String>['other', 'rev1']);
      await _settle();
      expect(h.crypto.revocationCommits, 1);
      h.state.dispose();
    });
  });

  group('a local MLS outbox failure', () {
    Future<(PendingMlsMessage, bool)> fail(
        PendingMlsMessage message, Object? error) async {
      final h = await _Harness.start(pending: const <String>{});
      await _settle();
      if (error != null) h.api.messageFailures[message.idempotencyKey] = error;
      await _queue(h.store, <PendingMlsMessage>[message]);
      h.sync.frame();
      await _waitFor(() async =>
          (await h.store.pendingMlsMessages()).single.attemptCount == 1);
      final recorded = (await h.store.pendingMlsMessages()).single;
      await _waitFor(
          () => h.state.mlsConversationFailed('conv_a') == recorded.terminal);
      final failed = h.state.mlsConversationFailed('conv_a');
      h.state.dispose();
      return (recorded, failed);
    }

    test('an undecodable bundle is terminal and pauses its conversation',
        () async {
      final (recorded, failed) = await fail(
          const PendingMlsMessage(
            idempotencyKey: 'b1',
            conversationId: 'conv_a',
            kind: MlsCommitBundle.kind,
            payload: <int>[1],
          ),
          null);
      expect(recorded.terminal, isTrue);
      expect(recorded.failureClass, 'terminal:local:FormatException');
      expect(recorded.nextAttemptAt, isNull);
      expect(failed, isTrue);
    });

    test('an argument error is terminal', () async {
      final (recorded, failed) =
          await fail(_message('c1', 'conv_a'), ArgumentError('bad payload'));
      expect(recorded.terminal, isTrue);
      expect(recorded.failureClass, 'terminal:local:ArgumentError');
      expect(failed, isTrue);
    });

    test('a durable storage error is terminal', () async {
      final (recorded, failed) = await fail(
          _message('c1', 'conv_a'),
          const FileSystemException(
              'open failed', '/data/x', OSError('No such file', 2)));
      expect(recorded.terminal, isTrue);
      expect(recorded.failureClass, 'terminal:local:FileSystemException');
      expect(failed, isTrue);
    });

    test('a transient storage error retries, labelled local', () async {
      final (recorded, failed) = await fail(
          _message('c1', 'conv_a'),
          const FileSystemException(
              'write failed', '/data/x', OSError('No space left', 28)));
      expect(recorded.terminal, isFalse);
      expect(recorded.failureClass, 'retryable:local');
      expect(recorded.nextAttemptAt, isNotNull);
      expect(failed, isFalse);
    });

    test('a network error still retries, labelled network', () async {
      final (recorded, failed) =
          await fail(_message('c1', 'conv_a'), const SocketException('down'));
      expect(recorded.terminal, isFalse);
      expect(recorded.failureClass, 'retryable:network');
      expect(recorded.nextAttemptAt, isNotNull);
      expect(failed, isFalse);
    });

    test('a malformed server response retries, labelled response', () async {
      // ApiResponseException is a FormatException, but the server's next
      // answer may be fine (a captive portal's page, say).
      final (recorded, failed) =
          await fail(_message('c1', 'conv_a'), const ApiResponseException());
      expect(recorded.terminal, isFalse);
      expect(recorded.failureClass, 'retryable:response');
      expect(failed, isFalse);
    });

    test('an unknown error retries, labelled unknown', () async {
      final (recorded, failed) =
          await fail(_message('c1', 'conv_a'), StateError('odd'));
      expect(recorded.terminal, isFalse);
      expect(recorded.failureClass, 'retryable:unknown');
      expect(recorded.nextAttemptAt, isNotNull);
      expect(failed, isFalse);
    });
  });

  group('MLS catch-up failures stay isolated', () {
    test('a change that fails to stage backs off; later changes still go',
        () async {
      final h = await _Harness.start(
          pending: const <String>{'conv_a', 'conv_b'},
          fakes: (api, crypto) => crypto.stageFailures.add('conv_a'));
      await _waitFor(() => h.crypto.completed == 1);
      expect(h.api.claims, <String>['conv_a', 'conv_b']);
      expect(h.api.pendingAdds, <String>{'conv_a'});
      // Catch-ups right after the failure claim nothing for it again.
      await h.frames(const Duration(milliseconds: 600));
      expect(h.api.claims.where((id) => id == 'conv_a'), hasLength(1));
      // Its backoff over, it is tried again without any other trigger.
      h.crypto.stageFailures.clear();
      await _waitFor(() => h.crypto.completed == 2,
          timeout: const Duration(seconds: 5));
      expect(h.api.claims.where((id) => id == 'conv_a'), hasLength(2));
      expect(h.api.pendingAdds, isEmpty);
      h.state.dispose();
    });

    test('a failed claim backs off too', () async {
      final h = await _Harness.start(
          fakes: (api, crypto) => api.claimFailures['conv_a'] =
              ApiException(404, '{"error":"not_found"}'));
      await _waitFor(() => h.api.claimCalls == 1);
      await h.frames(const Duration(milliseconds: 600));
      expect(h.api.claimCalls, 1);
      h.state.dispose();
    });

    test('a 401 from a claim still signs the device out', () async {
      final h = await _Harness.start(
          fakes: (api, crypto) => api.claimFailures['conv_a'] =
              ApiException(401, '{"error":"unauthorized"}'));
      await _waitFor(() => h.state.session == null);
      h.state.dispose();
    });

    MlsRevocation pendingRevocation(String conversationId) => MlsRevocation(
          conversationId: conversationId,
          revokedDeviceId: 'dev_gone',
          revokedAccountId: 'acct_me',
          coordinatorDeviceId: 'dev_me',
          state: 'pending',
          requestedAt: DateTime.utc(2026, 10, 31),
        );

    test('a failed revocation is retried on an idle session', () async {
      final h = await _Harness.start(
          pending: const <String>{},
          fakes: (api, crypto) {
            crypto.revocationFailures.add('conv_a');
            api.revocationsHook = () async => <MlsRevocation>[
                  for (final id in <String>['conv_a', 'conv_b'])
                    if (!api.revoked.contains(id)) pendingRevocation(id),
                ];
          });
      await _waitFor(() => h.api.revoked.contains('conv_b'));
      expect(h.crypto.revocationAttempts, <String>['conv_a', 'conv_b']);
      h.crypto.revocationFailures.clear();
      // No frame, resume or new work: the retry alone commits it.
      await _waitFor(() => h.api.revoked.contains('conv_a'),
          timeout: const Duration(seconds: 5));
      expect(
          h.crypto.revocationAttempts, <String>['conv_a', 'conv_b', 'conv_a']);
      h.state.dispose();
    });

    test('an unreadable revocation list does not skip reconcile', () async {
      final h = await _Harness.start(
          fakes: (api, crypto) => api.revocationsHook =
              () async => throw ApiException(503, '{"error":"unavailable"}'));
      await _waitFor(() => h.api.claims.isNotEmpty,
          timeout: const Duration(seconds: 3));
      final reads = h.api.revocationReads;
      // The failed read is tried again, with backoff.
      await _waitFor(() => h.api.revocationReads > reads,
          timeout: const Duration(seconds: 5));
      h.state.dispose();
    });

    test('a 401 from the revocation list still signs the device out', () async {
      final h = await _Harness.start(
          fakes: (api, crypto) => api.revocationsHook =
              () async => throw ApiException(401, '{"error":"unauthorized"}'));
      await _waitFor(() => h.state.session == null);
      h.state.dispose();
    });
  });
}

const _origin = 'https://localhost:8080';
const _session = Session(
  baseUrl: _origin,
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
  deviceSecret: 'secret',
);
const _bob = (accountId: 'acct_bob', deviceId: 'dev_bob');

class _Harness {
  _Harness(this.state, this.api, this.crypto, this.store, this.sync);

  final AppState state;
  final _Api api;
  final _Crypto crypto;
  final MemoryLocalStore store;
  final _Sync sync;

  int get syncCalls => api.syncCalls;

  static Future<_Harness> start({
    ApiException Function()? refuse,
    List<Object> refuseOnce = const <Object>[],
    Set<String> pending = const <String>{'conv_a'},
    MemoryLocalStore? store,
    void Function(_Api api, _Crypto crypto)? fakes,
    void Function(AppState state)? configure,
  }) async {
    final local = store ?? MemoryLocalStore();
    await local.saveSession(_session);
    final api = _Api()
      ..refuse = refuse
      ..bundleFailures.addAll(refuseOnce)
      ..pendingAdds.addAll(pending);
    final crypto = _Crypto(local);
    fakes?.call(api, crypto);
    final sync = _Sync();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: crypto,
      localStore: local,
      syncServiceFactory: (_, __) => sync,
    )..conversations = <Conversation>[
        Conversation(id: 'conv_a', kind: 'group'),
        Conversation(id: 'conv_b', kind: 'group'),
      ];
    configure?.call(state);
    await state.tryRestoreSession();
    return _Harness(state, api, crypto, local, sync);
  }

  /// Sends a sync frame every 50 ms for [length].
  Future<void> frames(Duration length) async {
    final window = Stopwatch()..start();
    while (window.elapsed < length) {
      sync.frame();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

PendingMlsMessage _message(String key, String conversationId) =>
    PendingMlsMessage(
      idempotencyKey: key,
      conversationId: conversationId,
      kind: 'commit',
      payload: const <int>[1],
    );

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 300));

Future<void> _queue(LocalStore store, List<PendingMlsMessage> messages) async {
  if (messages.isEmpty) return;
  final counter = (await store.loadCryptoState())?.counter ?? 0;
  await store.commitOutgoingMlsTransition(OutgoingMlsStateTransition(
    expectedCounter: counter,
    expectedCursor: await store.loadSyncCursor(),
    state: StoredCryptoState(
      counter: counter + 1,
      stateKey: List<int>.filled(32, 1),
      sealedState: const <int>[1],
    ),
    messages: messages,
  ));
}

/// A request yields to timers, as real I/O does; a loop of requests that
/// never waits would otherwise starve every timer in the test.
Future<void> _network() => Future<void>.delayed(Duration.zero);

Future<void> _waitFor(FutureOr<bool> Function() condition,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not reached');
}

/// A server with one pending change per conversation in [pendingAdds]:
/// add `dev_bob` at the conversation's epoch.
class _Api extends ApiClient {
  _Api() : super(baseUrl: _origin);

  final Map<String, int> serverEpochs = <String, int>{};
  final Set<String> pendingAdds = <String>{};
  ApiException Function()? refuse;
  final List<Object> bundleFailures = <Object>[];
  final List<String> claims = <String>[];
  final List<String> bundles = <String>[];
  final List<String> messages = <String>[];
  final List<String> envelopes = <String>[];
  final Map<String, Object> messageFailures = <String, Object>{};
  final Map<String, Object> claimFailures = <String, Object>{};
  final Set<String> revoked = <String>{};
  int claimCalls = 0;
  int revocationReads = 0;
  int pendingChangeCalls = 0;
  int syncCalls = 0;
  bool hangBundles = false;

  /// Runs when a bundle reaches the server, before it answers.
  void Function(String conversationId, MlsCommitBundle bundle)? onBundle;

  int epochOf(String conversationId) => serverEpochs[conversationId] ?? 3;

  @override
  void close() {}

  @override
  Future<void> logout(String token) async {}

  @override
  Future<void> addConversationMember(
    String token,
    String conversationId,
    String accountId, {
    String role = 'member',
  }) async {
    pendingAdds.add(conversationId);
  }

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[
        Conversation(id: 'conv_a', kind: 'group'),
        Conversation(id: 'conv_b', kind: 'group'),
      ];

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<List<SyncEvent>> syncEvents(String token,
      {int after = 0, int limit = 100}) async {
    await _network();
    syncCalls++;
    return const <SyncEvent>[];
  }

  Future<List<MlsRevocation>> Function()? revocationsHook;

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async {
    await _network();
    revocationReads++;
    return await revocationsHook?.call() ?? const <MlsRevocation>[];
  }

  @override
  Future<List<MlsPendingChange>> mlsPendingChanges(String token) async {
    await _network();
    pendingChangeCalls++;
    return <MlsPendingChange>[
      for (final conversationId in pendingAdds.toList()..sort())
        MlsPendingChange(
          conversationId: conversationId,
          epoch: epochOf(conversationId),
          add: const <MlsDeviceRef>[_bob],
          remove: const <MlsDeviceRef>[],
        ),
    ];
  }

  @override
  Future<List<DeviceKeyPackage>> claimDeviceKeyPackages(
      String token, String conversationId, List<String> deviceIds) async {
    await _network();
    claimCalls++;
    final failure = claimFailures[conversationId];
    if (failure != null) throw failure;
    claims.add(conversationId);
    return <DeviceKeyPackage>[
      DeviceKeyPackage(
        id: 'kp_${claims.length}',
        deviceId: _bob.deviceId,
        accountId: _bob.accountId,
        keyPackage: const <int>[1],
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      ),
    ];
  }

  @override
  Future<int> sendMlsCommitBundle(
    String token,
    String conversationId, {
    required String idempotencyKey,
    required MlsCommitBundle bundle,
  }) async {
    await _network();
    bundles.add(conversationId);
    if (hangBundles) await Completer<void>().future;
    onBundle?.call(conversationId, bundle);
    final refusal = refuse;
    if (refusal != null) throw refusal();
    if (bundleFailures.isNotEmpty) throw bundleFailures.removeAt(0);
    serverEpochs[conversationId] = bundle.epoch + 1;
    pendingAdds.remove(conversationId);
    return bundle.epoch + 1;
  }

  @override
  Future<MlsMessage> sendMlsMessage(
    String token,
    String conversationId, {
    required String kind,
    required List<int> payload,
    required String idempotencyKey,
    String? recipientDeviceId,
    String? revocationDeviceId,
  }) async {
    final failure = messageFailures.remove(idempotencyKey);
    if (failure != null) throw failure;
    messages.add(idempotencyKey);
    if (revocationDeviceId != null) revoked.add(conversationId);
    return MlsMessage(
      id: 'mls_$idempotencyKey',
      conversationId: conversationId,
      senderAccountId: 'acct_me',
      senderDeviceId: 'dev_me',
      kind: kind,
      payload: payload,
      idempotencyKey: idempotencyKey,
      syncEventId: messages.length,
      createdAt: DateTime.utc(2026, 10, 31),
    );
  }

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    envelopes.add(envelope.idempotencyKey);
  }
}

/// Stages each membership change as a queued `bundle` item, the way the
/// native service does, and merges or drops it when told to.
class _Crypto implements MlsConversationCryptoService {
  _Crypto(this.store);

  final MemoryLocalStore store;
  final Map<String, int> epochs = <String, int>{};
  int staged = 0;
  int completed = 0;
  int completeCalls = 0;
  int abandoned = 0;
  int revocationCommits = 0;
  final List<String> revocationAttempts = <String>[];
  final Set<String> revocationFailures = <String>{};
  final Set<String> stageFailures = <String>{};
  final List<Object> completeFailures = <Object>[];

  int epochOf(String conversationId) => epochs[conversationId] ?? 3;

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<({int epoch, bool pending})?> groupEpoch(
          String conversationId) async =>
      (epoch: epochOf(conversationId), pending: false);

  @override
  Future<void> stageMembershipChange(
    String conversationId, {
    List<DeviceKeyPackage> adds = const <DeviceKeyPackage>[],
    List<MlsDeviceRef> removes = const <MlsDeviceRef>[],
  }) async {
    if (stageFailures.contains(conversationId)) {
      throw StateError('invalid key package');
    }
    staged++;
    await _queue(store, <PendingMlsMessage>[
      PendingMlsMessage(
        idempotencyKey: 'bundle_$staged',
        conversationId: conversationId,
        kind: MlsCommitBundle.kind,
        payload: MlsCommitBundle(
          epoch: epochOf(conversationId),
          commit: const <int>[1],
          welcome: adds.isEmpty ? const <int>[] : const <int>[1],
          added: <MlsDeviceRef>[
            for (final item in adds)
              (accountId: item.accountId, deviceId: item.deviceId),
          ],
          removed: removes,
        ).encode(),
      ),
    ]);
  }

  @override
  Future<void> createRevocationCommit(MlsRevocation revocation) async {
    revocationAttempts.add(revocation.conversationId);
    if (revocationFailures.contains(revocation.conversationId)) {
      throw StateError('no leaf for the revoked device');
    }
    revocationCommits++;
    await _queue(store, <PendingMlsMessage>[
      PendingMlsMessage(
        idempotencyKey: 'rev$revocationCommits',
        conversationId: revocation.conversationId,
        kind: 'commit',
        payload: const <int>[1],
        revocationDeviceId: revocation.revokedDeviceId,
      ),
    ]);
  }

  @override
  Future<void> completeCommitBundle(PendingMlsMessage bundle) async {
    completeCalls++;
    if (completeFailures.isNotEmpty) throw completeFailures.removeAt(0);
    completed++;
    epochs[bundle.conversationId] = epochOf(bundle.conversationId) + 1;
    await store.removePendingMlsMessage(bundle.idempotencyKey);
  }

  @override
  Future<void> abandonCommitBundle(PendingMlsMessage bundle) async {
    abandoned++;
    await store.removePendingMlsMessage(bundle.idempotencyKey);
  }

  @override
  Future<MessageEnvelope> encrypt(
          String conversationId, String plaintext) async =>
      MessageEnvelope(
        conversationId: conversationId,
        idempotencyKey: 'app_${DateTime.now().microsecondsSinceEpoch}',
        ciphertext: const <int>[1],
        cryptoProtocol: 'mls10-openmls-v1',
      );

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Sync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  void frame() {
    if (!_controller.isClosed) {
      _controller.add(<String, Object?>{'type': 'sync.available'});
    }
  }

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}

/// A store whose MLS queue reads and removals can be made to fail.
class _FlakyStore extends MemoryLocalStore {
  int mlsReadFailures = 0;
  int mlsReads = 0;
  int removeFailures = 0;
  int envelopeReadFailures = 0;
  int envelopeReads = 0;

  @override
  Future<List<PendingEnvelopeRecord>> pendingEnvelopeRecords() async {
    envelopeReads++;
    if (envelopeReadFailures > 0) {
      envelopeReadFailures--;
      throw StateError('database is locked');
    }
    return super.pendingEnvelopeRecords();
  }

  @override
  Future<List<PendingMlsMessage>> pendingMlsMessages() async {
    mlsReads++;
    if (mlsReadFailures > 0) {
      mlsReadFailures--;
      throw StateError('database is locked');
    }
    return super.pendingMlsMessages();
  }

  @override
  Future<void> removePendingMlsMessage(String idempotencyKey) async {
    if (removeFailures > 0) {
      removeFailures--;
      throw StateError('database is locked');
    }
    await super.removePendingMlsMessage(idempotencyKey);
  }
}
