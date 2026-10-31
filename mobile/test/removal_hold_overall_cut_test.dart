// D68 review follow-ups: only a read the server says it cut at its overall
// cap keeps unlisted holds; one conversation over its own cap must not hold
// every other conversation.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // conv_a is held; then its removal is committed and applied (local epoch
  // past the hold) and the server stops listing it, while conv_b is listed
  // with a removal over its own per-conversation cap.
  Future<_Harness> appliedHoldBesideBigGroup({bool? listCut}) async {
    final h = await _Harness.start(
        pendingRemovals: {'conv_a'},
        fakes: (api, crypto) =>
            crypto.stageFailures.addAll({'conv_a', 'conv_b'}));
    addTearDown(h.state.dispose);
    await _waitFor(() => h.state.sendHeldForRemoval('conv_a'));
    h.api
      ..listCut = listCut
      ..truncatedItems.add('conv_b')
      ..pendingRemovals.remove('conv_a')
      ..pendingRemovals.add('conv_b');
    h.crypto
      ..epochs['conv_a'] = 4
      ..removalApplied.add('conv_a');
    return h;
  }

  test(
      'a conversation over its own cap does not hold an applied removal '
      'elsewhere', () async {
    final h = await appliedHoldBesideBigGroup(listCut: false);
    await h.frames(const Duration(milliseconds: 300));
    await _waitFor(() => !h.state.sendHeldForRemoval('conv_a'));
    expect(h.state.sendHeldForRemoval('conv_b'), isTrue);
  });

  test('a read the server says it cut releases no unlisted hold', () async {
    final h = await appliedHoldBesideBigGroup(listCut: true);
    final reads = h.api.pendingChangeCalls;
    await h.frames(const Duration(milliseconds: 400));
    expect(h.api.pendingChangeCalls, greaterThan(reads + 1));
    expect(h.state.sendHeldForRemoval('conv_a'), isTrue);
  });

  test('without the flag, an all-truncated read still releases nothing',
      () async {
    // An older server: no response-level flag, every listed item truncated.
    final h = await appliedHoldBesideBigGroup();
    final reads = h.api.pendingChangeCalls;
    await h.frames(const Duration(milliseconds: 400));
    expect(h.api.pendingChangeCalls, greaterThan(reads + 1));
    expect(h.state.sendHeldForRemoval('conv_a'), isTrue,
        reason: 'fail closed when the server does not say');
  });
}

const _origin = 'https://example.test';
const _session = Session(
  baseUrl: _origin,
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
  deviceSecret: 'secret',
);
const _bob = (accountId: 'acct_bob', deviceId: 'dev_bob');
const _conversationIds = <String>['conv_a', 'conv_b', 'conv_c'];

class _Harness {
  _Harness(this.state, this.api, this.crypto, this.store, this.sync);

  final AppState state;
  final _Api api;
  final _Crypto crypto;
  final _CountingStore store;
  final _Sync sync;

  static Future<_Harness> start({
    Set<String> pendingRemovals = const <String>{},
    _CountingStore? store,
    _Crypto? crypto,
    void Function(_Api api, _Crypto crypto)? fakes,
    bool awaitRestore = true,
  }) async {
    final local = store ?? _CountingStore();
    await local.saveSession(_session);
    final api = _Api()..pendingRemovals.addAll(pendingRemovals);
    final mls = crypto ?? _Crypto(local);
    fakes?.call(api, mls);
    final sync = _Sync();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: mls,
      localStore: local,
      syncServiceFactory: (_, __) => sync,
    )..conversations = <Conversation>[
        for (final id in _conversationIds) Conversation(id: id, kind: 'group'),
      ];
    final restore = state.tryRestoreSession();
    if (awaitRestore) await restore;
    return _Harness(state, api, mls, local, sync);
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

/// A server that lists a removal of `dev_bob` for each conversation in
/// [pendingRemovals] until a commit bundle for it is accepted.
class _Api extends ApiClient {
  _Api() : super(baseUrl: _origin);

  final Map<String, int> serverEpochs = <String, int>{};
  final Set<String> pendingRemovals = <String>{};
  final List<String> bundles = <String>[];
  final List<String> envelopes = <String>[];
  int pendingChangeCalls = 0;

  /// While true, every read is flagged truncated, as the server does when
  /// it cut the whole list at its cap.
  bool truncateReads = false;

  /// Conversations whose item is over its own per-conversation cap.
  final Set<String> truncatedItems = <String>{};

  /// The response-level overall-cut flag; null answers a plain list, as an
  /// older server without the flag does.
  bool? listCut;

  /// Run one per sync fetch, in order: what lands on the server, or what a
  /// fetched commit applies locally, at that fetch.
  final List<void Function()> fetchSteps = <void Function()>[];

  /// When false, a removal is never listed: another device committed it at
  /// once. [stepsOnRemove] are queued as [fetchSteps] when it is made.
  bool listRemovals = true;
  List<void Function()> stepsOnRemove = <void Function()>[];

  /// While set and not completed, a bundle's answer waits for it.
  Completer<void>? bundleGate;

  /// While set and not completed, a pending-changes read answers with the
  /// list as it was when the read started, once the gate opens.
  Completer<void>? readGate;

  /// Refuses every commit bundle with this error when set.
  ApiException Function()? refuseBundle;

  /// Server roster per conversation; Bob is a member until removed.
  final Map<String, Set<String>> members = <String, Set<String>>{};

  Set<String> membersOf(String conversationId) => members.putIfAbsent(
      conversationId, () => <String>{'acct_me', _bob.accountId});

  int epochOf(String conversationId) => serverEpochs[conversationId] ?? 3;

  @override
  void close() {}

  @override
  Future<void> logout(String token) async {}

  @override
  Future<void> removeConversationMember(
      String token, String conversationId, String accountId) async {
    await _network();
    if (accountId == 'me') {
      members.remove(conversationId);
      return;
    }
    membersOf(conversationId).remove(accountId);
    if (listRemovals) pendingRemovals.add(conversationId);
    fetchSteps.addAll(stepsOnRemove);
  }

  @override
  Future<List<ConversationMember>> conversationMembers(
      String token, String conversationId) async {
    await _network();
    return <ConversationMember>[
      for (final account in membersOf(conversationId))
        ConversationMember(accountId: account, role: 'member'),
    ];
  }

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[
        for (final id in _conversationIds) Conversation(id: id, kind: 'group'),
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
    if (fetchSteps.isNotEmpty) fetchSteps.removeAt(0)();
    return const <SyncEvent>[];
  }

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async {
    await _network();
    return const <MlsRevocation>[];
  }

  @override
  Future<List<MlsPendingChange>> mlsPendingChanges(String token) async {
    await _network();
    pendingChangeCalls++;
    final answer = <MlsPendingChange>[
      for (final conversationId in pendingRemovals.toList()..sort())
        MlsPendingChange(
          conversationId: conversationId,
          epoch: epochOf(conversationId),
          add: const <MlsDeviceRef>[],
          remove: const <MlsDeviceRef>[_bob],
          truncated:
              truncateReads || truncatedItems.contains(conversationId),
        ),
    ];
    final gate = readGate;
    if (gate != null) await gate.future;
    final cut = listCut;
    return cut == null ? answer : MlsPendingChanges(answer, cut: cut);
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
    final gate = bundleGate;
    if (gate != null) await gate.future;
    final refusal = refuseBundle;
    if (refusal != null) throw refusal();
    serverEpochs[conversationId] = bundle.epoch + 1;
    pendingRemovals.remove(conversationId);
    return bundle.epoch + 1;
  }

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    await _network();
    envelopes.add(envelope.idempotencyKey);
  }
}

typedef _Encrypted = ({
  String conversationId,
  AppPayloadType type,
  Map<String, Object?> body,
  bool removalApplied,
});

/// Stages membership changes as queued bundles, as the native service does,
/// and records for every encrypted payload whether the removal commit of
/// its conversation had been applied.
class _Crypto implements MlsConversationCryptoService {
  _Crypto(this.store);

  final MemoryLocalStore store;
  final Map<String, int> epochs = <String, int>{};
  final Set<String> removalApplied = <String>{};
  final List<_Encrypted> encrypted = <_Encrypted>[];
  final Set<String> stageFailures = <String>{};
  final Set<String> noGroup = <String>{};
  final Set<String> epochFailures = <String>{};
  int staged = 0;

  int epochOf(String conversationId) => epochs[conversationId] ?? 3;

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<({int epoch, bool pending})?> groupEpoch(String conversationId) async {
    if (epochFailures.remove(conversationId)) {
      throw StateError('group state unreadable');
    }
    return noGroup.contains(conversationId)
        ? null
        : (epoch: epochOf(conversationId), pending: false);
  }

  @override
  Future<void> stageMembershipChange(
    String conversationId, {
    List<DeviceKeyPackage> adds = const <DeviceKeyPackage>[],
    List<MlsDeviceRef> removes = const <MlsDeviceRef>[],
  }) async {
    if (stageFailures.contains(conversationId)) {
      throw StateError('cannot stage');
    }
    staged++;
    final counter = (await store.loadCryptoState())?.counter ?? 0;
    await store.commitOutgoingMlsTransition(OutgoingMlsStateTransition(
      expectedCounter: counter,
      expectedCursor: await store.loadSyncCursor(),
      state: StoredCryptoState(
        counter: counter + 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: const <int>[1],
      ),
      messages: <PendingMlsMessage>[
        PendingMlsMessage(
          idempotencyKey: 'bundle_$staged',
          conversationId: conversationId,
          kind: MlsCommitBundle.kind,
          payload: MlsCommitBundle(
            epoch: epochOf(conversationId),
            commit: const <int>[1],
            removed: removes,
          ).encode(),
        ),
      ],
    ));
  }

  @override
  Future<void> completeCommitBundle(PendingMlsMessage bundle) async {
    epochs[bundle.conversationId] = epochOf(bundle.conversationId) + 1;
    if (MlsCommitBundle.decode(bundle.payload).removed.isNotEmpty) {
      removalApplied.add(bundle.conversationId);
    }
    await store.removePendingMlsMessage(bundle.idempotencyKey);
  }

  @override
  Future<void> abandonCommitBundle(PendingMlsMessage bundle) async {
    await store.removePendingMlsMessage(bundle.idempotencyKey);
  }

  @override
  Future<MessageEnvelope> encryptPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    List<String> attachmentRefs = const <String>[],
    String? draftText,
  }) async {
    encrypted.add((
      conversationId: conversationId,
      type: type,
      body: body,
      removalApplied: removalApplied.contains(conversationId),
    ));
    return MessageEnvelope(
      conversationId: conversationId,
      idempotencyKey: 'app_${encrypted.length}',
      ciphertext: const <int>[1],
      cryptoProtocol: 'mls10-openmls-v1',
    );
  }

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

class _CountingStore extends MemoryLocalStore {
  int mlsReads = 0;

  /// While true, every read of the MLS outbox fails.
  bool failMlsReads = false;

  /// While set and not completed, the outbox capacity check waits for it:
  /// a slow operation at the head of the session queue.
  Completer<void>? capacityGate;

  @override
  Future<bool> hasOutboxCapacity() async {
    final gate = capacityGate;
    if (gate != null) await gate.future;
    return super.hasOutboxCapacity();
  }

  @override
  Future<List<PendingMlsMessage>> pendingMlsMessages() async {
    mlsReads++;
    if (failMlsReads) throw StateError('database is locked');
    return super.pendingMlsMessages();
  }
}
