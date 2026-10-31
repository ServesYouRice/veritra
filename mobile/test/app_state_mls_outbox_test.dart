// MLS outbox and membership reconcile (I34, I51): refused commit bundles back
// off and are reconciled again by a wake timer (TASK-029).
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

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

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

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
    messages.add(idempotencyKey);
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
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {}
}

/// Stages each membership change as a queued `bundle` item, the way the
/// native service does, and merges or drops it when told to.
class _Crypto implements MlsConversationCryptoService {
  _Crypto(this.store);

  final MemoryLocalStore store;
  final Map<String, int> epochs = <String, int>{};
  int staged = 0;
  int completed = 0;
  int abandoned = 0;

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
  Future<void> completeCommitBundle(PendingMlsMessage bundle) async {
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
