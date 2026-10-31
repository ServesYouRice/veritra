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

class _Harness {
  _Harness(this.state, this.api, this.crypto, this.store, this.sync);

  final AppState state;
  final _Api api;
  final _Crypto crypto;
  final _CountingStore store;
  final _Sync sync;

  static Future<_Harness> start(
      {Set<String> pendingRemovals = const <String>{}}) async {
    final local = _CountingStore();
    await local.saveSession(_session);
    final api = _Api()..pendingRemovals.addAll(pendingRemovals);
    final crypto = _Crypto(local);
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

  int epochOf(String conversationId) => serverEpochs[conversationId] ?? 3;

  @override
  void close() {}

  @override
  Future<void> logout(String token) async {}

  @override
  Future<void> removeConversationMember(
      String token, String conversationId, String accountId) async {
    await _network();
    pendingRemovals.add(conversationId);
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
    return <MlsPendingChange>[
      for (final conversationId in pendingRemovals.toList()..sort())
        MlsPendingChange(
          conversationId: conversationId,
          epoch: epochOf(conversationId),
          add: const <MlsDeviceRef>[],
          remove: const <MlsDeviceRef>[_bob],
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
    final gate = bundleGate;
    if (gate != null) await gate.future;
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
  int staged = 0;

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

  @override
  Future<List<PendingMlsMessage>> pendingMlsMessages() async {
    mlsReads++;
    return super.pendingMlsMessages();
  }
}
