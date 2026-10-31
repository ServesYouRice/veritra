// A token rotation does not lose an armed MLS wake: the backoffs it
// serves still belong to this signed-in device.
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

  test('a token rotation keeps the MLS wake for a refused bundle', () async {
    final h = await _Harness.start(
        refuseOnce: <Object>[ApiException(422, '{"error":"invalid_input"}')],
        configure: (state) =>
            state.mlsRetryBase = const Duration(milliseconds: 800));
    await _waitFor(() => h.crypto.abandoned == 1);
    // The rotated session's own catch-up reaches the change while it still
    // backs off; only the wake brings it back.
    expect(await h.state.reauthenticate('password'), isTrue);
    expect(h.state.session!.token, isNot('token'));
    await _waitFor(() => h.crypto.completed == 1,
        timeout: const Duration(seconds: 5));
    expect(h.api.claims, hasLength(2));
    h.state.dispose();
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

  int tokens = 0;

  @override
  Future<String?> reauthenticate(
          String token, String password, String deviceSecret) async =>
      'token_${++tokens}';

  @override
  Future<Session> login({
    required String username,
    required String password,
    required String deviceId,
    required String deviceSecret,
  }) async =>
      Session(
        baseUrl: baseUrl,
        token: 'token_${++tokens}',
        accountId: 'acct_me',
        deviceId: deviceId,
        username: username,
        deviceSecret: deviceSecret,
      );

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

  /// When set, an abandon waits for it before it finishes.
  Completer<void>? abandonGate;

  @override
  Future<void> abandonCommitBundle(PendingMlsMessage bundle) async {
    abandoned++;
    await abandonGate?.future;
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
