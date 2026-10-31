// D68 / TASK-039: after a member removal, application sends to that
// conversation wait, unencrypted, until the MLS removal commit is applied
// locally; then they go out in order. Other conversations are unaffected,
// the wait never busy-loops, and a session that ends releases it without
// encrypting anything.
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

  test('sends after a removal are encrypted only after the removal commit',
      () async {
    final h = await _Harness.start();
    addTearDown(h.state.dispose);
    h.api.bundleGate = Completer<void>();

    expect(await h.state.removeConversationMember('conv_a', _bob.accountId),
        isTrue);
    final text = h.state.sendMessageTo('conv_a', 'after removal');
    final reaction = h.state.react('conv_a', 'msg_1', '👍');
    // The coordinator stages the removal and the bundle reaches the server,
    // which has not answered yet.
    await _waitFor(() => h.api.bundles.isNotEmpty);
    await h.frames(const Duration(milliseconds: 400));
    expect(h.crypto.encrypted, isEmpty,
        reason: 'nothing may be encrypted while the removed devices are '
            'still in the group');

    // Another conversation is not held.
    expect(await h.state.sendMessageTo('conv_b', 'elsewhere'), isTrue);
    expect(h.crypto.encrypted.map((e) => e.conversationId), ['conv_b']);

    h.api.bundleGate!.complete();
    expect(await text, isTrue);
    expect(await reaction, isTrue);
    final held = h.crypto.encrypted.where((e) => e.conversationId == 'conv_a');
    expect(
        held.map((e) => e.type), [AppPayloadType.text, AppPayloadType.reaction],
        reason: 'held sends go out in the order they were made');
    expect(held.every((e) => e.removalApplied), isTrue);
    await _waitFor(() => h.api.envelopes.length == 3);
  });

  test('a send made while others wait queues behind them', () async {
    final h = await _Harness.start();
    addTearDown(h.state.dispose);
    h.api.bundleGate = Completer<void>();
    await h.state.removeConversationMember('conv_a', _bob.accountId);
    final first = h.state.sendMessageTo('conv_a', 'one');
    await _waitFor(() => h.api.bundles.isNotEmpty);
    final second = h.state.deleteMessage('conv_a', 'msg_1');
    h.api.bundleGate!.complete();
    final third = h.state.sendMessageTo('conv_a', 'three');
    expect(await Future.wait([first, second, third]), [true, true, true]);
    expect(h.crypto.encrypted.map((e) => e.type), [
      AppPayloadType.text,
      AppPayloadType.delete,
      AppPayloadType.text,
    ]);
    expect(
        h.crypto.encrypted.map((e) => e.body['text']), ['one', null, 'three']);
  });

  test('a held send does not poll while it waits', () async {
    final h = await _Harness.start();
    addTearDown(h.state.dispose);
    h.api.bundleGate = Completer<void>();
    await h.state.removeConversationMember('conv_a', _bob.accountId);
    unawaited(h.state.sendMessageTo('conv_a', 'held'));
    await _waitFor(() => h.api.bundles.isNotEmpty);
    final reads = h.api.pendingChangeCalls;
    final mlsReads = h.store.mlsReads;
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(h.api.pendingChangeCalls - reads, lessThan(3));
    expect(h.store.mlsReads - mlsReads, lessThan(5));
    expect(h.crypto.encrypted, isEmpty);
  });

  test('a session that ends releases held sends without encrypting', () async {
    final h = await _Harness.start();
    h.api.bundleGate = Completer<void>();
    await h.state.removeConversationMember('conv_a', _bob.accountId);
    final held = h.state.sendMessageTo('conv_a', 'held');
    await _waitFor(() => h.api.bundles.isNotEmpty);
    h.state.dispose();
    expect(await held.timeout(const Duration(seconds: 5)), isFalse);
    expect(h.crypto.encrypted, isEmpty);
    expect(await h.store.pendingEnvelopes(), isEmpty);
  });

  test('a removal pending on the server holds sends after a restart', () async {
    // Another device (or this one before a restart) removed Bob; the server
    // still lists the removal.
    final h = await _Harness.start(pendingRemovals: {'conv_a'});
    addTearDown(h.state.dispose);
    h.api.bundleGate = Completer<void>();
    await _waitFor(() => h.api.bundles.isNotEmpty);
    final held = h.state.sendMessageTo('conv_a', 'held');
    await h.frames(const Duration(milliseconds: 300));
    expect(h.crypto.encrypted, isEmpty);
    h.api.bundleGate!.complete();
    expect(await held, isTrue);
    expect(h.crypto.encrypted.single.removalApplied, isTrue);
  });

  test('sends without a pending removal are not held', () async {
    final h = await _Harness.start();
    addTearDown(h.state.dispose);
    expect(await h.state.sendMessageTo('conv_a', 'plain'), isTrue);
    expect(h.crypto.encrypted.single.removalApplied, isFalse);
    expect(h.api.bundles, isEmpty);
  });

  test('a pending-changes read taken before the removal does not lift it',
      () async {
    final store = _CountingStore();
    final h = await _Harness.start(
        store: store,
        awaitRestore: false,
        fakes: (api, _) => api
          ..readGate = Completer<void>()
          ..bundleGate = Completer<void>());
    addTearDown(h.state.dispose);
    // The startup reconcile has read the (empty) list and waits.
    await _waitFor(() => h.api.pendingChangeCalls == 1);
    final removed = h.state.removeConversationMember('conv_a', _bob.accountId);
    await _waitFor(() => h.api.pendingRemovals.contains('conv_a'));
    final held = h.state.sendMessageTo('conv_a', 'after removal');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // The stale, empty answer arrives after the removal.
    h.api.readGate!.complete();
    h.api.readGate = null;
    expect(await removed, isTrue);
    await _waitFor(() => h.api.bundles.isNotEmpty);
    await h.frames(const Duration(milliseconds: 300));
    expect(h.crypto.encrypted, isEmpty,
        reason: 'a read older than the removal must not release it');
    h.api.bundleGate!.complete();
    expect(await held, isTrue);
    expect(h.crypto.encrypted.single.removalApplied, isTrue);
  });

  test('a send queued before a hold appeared still goes before later ones',
      () async {
    final h = await _Harness.start(
        pendingRemovals: {'conv_c'},
        fakes: (api, crypto) => crypto.stageFailures.add('conv_c'));
    addTearDown(h.state.dispose);
    // conv_c keeps a removal listed, so every catch-up reconciles.
    await _waitFor(() => h.state.sendHeldForRemoval('conv_c'));
    h.store.capacityGate = Completer<void>();
    h.api.bundleGate = Completer<void>();
    final slow = h.state.sendMessageTo('conv_b', 'slow');
    final first = h.state.sendMessageTo('conv_a', 'A');
    // Another device removed Bob from conv_a meanwhile.
    h.api.pendingRemovals.add('conv_a');
    h.sync.frame();
    await _waitFor(() => h.state.sendHeldForRemoval('conv_a'));
    final second = h.state.sendMessageTo('conv_a', 'B');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    h.store.capacityGate!.complete();
    expect(await slow, isTrue);
    await _waitFor(() => h.api.bundles.contains('conv_a'));
    h.api.bundleGate!.complete();
    expect(await Future.wait([first, second]), [true, true]);
    expect(
        h.crypto.encrypted
            .where((e) => e.conversationId == 'conv_a')
            .map((e) => e.body['text']),
        ['A', 'B']);
  });

  test('a removal the server withdraws at the same epoch releases the hold',
      () async {
    final h = await _Harness.start(
        pendingRemovals: {'conv_a'},
        fakes: (api, crypto) {
          crypto.stageFailures.add('conv_a');
          api.membersOf('conv_a').remove(_bob.accountId);
        });
    addTearDown(h.state.dispose);
    await _waitFor(() => h.state.sendHeldForRemoval('conv_a'));
    final held = h.state.sendMessageTo('conv_a', 'held');
    await h.frames(const Duration(milliseconds: 200));
    expect(h.crypto.encrypted, isEmpty);
    // Bob is added back before any commit removed him: the epoch is still
    // the one the removal was listed at.
    h.api.pendingRemovals.remove('conv_a');
    h.api.membersOf('conv_a').add(_bob.accountId);
    h.sync.frame();
    expect(await held.timeout(const Duration(seconds: 5)), isTrue);
    expect(h.state.sendHeldForRemoval('conv_a'), isFalse);
  });

  test('an abandoned revocation bundle does not hold sends', () async {
    final h = await _Harness.start(
        fakes: (api, _) => api
          ..bundleGate = Completer<void>()
          ..refuseBundle =
              () => ApiException(409, '{"error":"mls_epoch_conflict"}'));
    addTearDown(h.state.dispose);
    final counter = (await h.store.loadCryptoState())?.counter ?? 0;
    await h.store.commitOutgoingMlsTransition(OutgoingMlsStateTransition(
      expectedCounter: counter,
      expectedCursor: await h.store.loadSyncCursor(),
      state: StoredCryptoState(
        counter: counter + 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: const <int>[1],
      ),
      messages: <PendingMlsMessage>[
        PendingMlsMessage(
          idempotencyKey: 'revocation_1',
          conversationId: 'conv_a',
          kind: MlsCommitBundle.kind,
          payload: const MlsCommitBundle(
            epoch: 3,
            commit: <int>[1],
            removed: <MlsDeviceRef>[_bob],
            revocationDeviceId: 'dev_bob',
          ).encode(),
        ),
      ],
    ));
    h.sync.frame();
    await _waitFor(() => h.api.bundles.isNotEmpty);
    final sent = h.state.sendMessageTo('conv_a', 'after revocation');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    h.api.bundleGate!.complete();
    await _waitFor(() async => (await h.store.pendingMlsMessages()).isEmpty);
    h.sync.frame();
    expect(await sent.timeout(const Duration(seconds: 5)), isTrue);
  });

  test('leaving a conversation ends a held send', () async {
    final h = await _Harness.start();
    addTearDown(h.state.dispose);
    h.api.bundleGate = Completer<void>();
    await h.state.removeConversationMember('conv_a', _bob.accountId);
    final held = h.state.sendMessageTo('conv_a', 'held');
    await _waitFor(() => h.api.bundles.isNotEmpty);
    expect(await h.state.leaveConversation('conv_a'), isTrue);
    expect(await held.timeout(const Duration(seconds: 5)), isFalse);
    expect(h.state.sendHeldForRemoval('conv_a'), isFalse);
    expect(h.crypto.encrypted, isEmpty);
  });

  test('a hold whose group is gone locally is dropped', () async {
    final h = await _Harness.start(
        pendingRemovals: {'conv_a'},
        fakes: (api, crypto) => crypto.stageFailures.add('conv_a'));
    addTearDown(h.state.dispose);
    await _waitFor(() => h.state.sendHeldForRemoval('conv_a'));
    // A skipped Welcome (D74) leaves no group, and the server drops it.
    h.crypto.noGroup.add('conv_a');
    h.api.pendingRemovals.remove('conv_a');
    h.sync.frame();
    await _waitFor(() => !h.state.sendHeldForRemoval('conv_a'));
  });

  test('this device\'s removal holds sends again after a restart', () async {
    final store = _CountingStore();
    final crypto = _Crypto(store)..stageFailures.add('conv_a');
    final first = await _Harness.start(store: store, crypto: crypto);
    await first.state.removeConversationMember('conv_a', _bob.accountId);
    await _waitFor(() => first.api.pendingChangeCalls >= 2);
    first.state.dispose();
    await first.state.backgroundWorkIdle;

    // After the restart the first pending-changes read has not answered.
    final h = await _Harness.start(
        store: store,
        crypto: crypto,
        pendingRemovals: {'conv_a'},
        awaitRestore: false,
        fakes: (api, _) => api
          ..readGate = Completer<void>()
          ..membersOf('conv_a').remove(_bob.accountId));
    addTearDown(h.state.dispose);
    await _waitFor(() => h.api.pendingChangeCalls == 1);
    final held = h.state.sendMessageTo('conv_a', 'held');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(crypto.encrypted, isEmpty,
        reason: 'the hold was kept on this device');
    crypto.stageFailures.clear();
    h.api.readGate!.complete();
    h.api.readGate = null;
    await h.frames(const Duration(milliseconds: 200));
    expect(await held.timeout(const Duration(seconds: 5)), isTrue);
    expect(crypto.encrypted.single.removalApplied, isTrue);
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
    pendingRemovals.add(conversationId);
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
        ),
    ];
    final gate = readGate;
    if (gate != null) await gate.future;
    return answer;
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
  int staged = 0;

  int epochOf(String conversationId) => epochs[conversationId] ?? 3;

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<({int epoch, bool pending})?> groupEpoch(
          String conversationId) async =>
      noGroup.contains(conversationId)
          ? null
          : (epoch: epochOf(conversationId), pending: false);

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
    return super.pendingMlsMessages();
  }
}
