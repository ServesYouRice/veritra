import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// Card I34: ordered, durable delivery of MLS control messages.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a transient failure retries later and holds back its group only',
      () async {
    final store = await _storeWith(<PendingMlsMessage>[
      _commit('a1', 'conv_a'),
      _commit('a2', 'conv_a'),
      _commit('b1', 'conv_b'),
    ]);
    final api = _OutboxApi()..failures['a1'] = <Object>[ApiException(503, '')];
    final state = await _start(api, store);

    await _waitFor(() => api.sent.contains('b1'));
    expect(api.sent, isNot(contains('a2')));
    final pending = await store.pendingMlsMessages();
    expect(pending.map((item) => item.idempotencyKey), <String>['a1', 'a2']);
    final a1 = pending.first;
    expect(a1.attemptCount, 1);
    expect(a1.terminal, isFalse);
    expect(a1.failureClass, 'retryable:503');
    expect(a1.nextAttemptAt, isNotNull);
    expect(state.mlsConversationFailed('conv_a'), isFalse);

    // The retry timer delivers both, in order.
    await _waitFor(() => api.sent.contains('a2'),
        timeout: const Duration(seconds: 4));
    expect(api.sent.where((key) => key.startsWith('a')), <String>['a1', 'a2']);
    expect(await store.pendingMlsMessages(), isEmpty);
    state.dispose();
  });

  test('a network error is retryable, not terminal', () async {
    final store =
        await _storeWith(<PendingMlsMessage>[_commit('a1', 'conv_a')]);
    final api = _OutboxApi()
      ..failures['a1'] = <Object>[const SocketException('down')];
    final state = await _start(api, store);
    await _waitFor(() async =>
        (await store.pendingMlsMessages()).firstOrNull?.attemptCount == 1);
    final item = (await store.pendingMlsMessages()).single;
    expect(item.terminal, isFalse);
    expect(item.failureClass, 'retryable:network');
    state.dispose();
  });

  test('a rejected message fails its group closed and is kept', () async {
    final store = await _storeWith(<PendingMlsMessage>[
      _commit('a1', 'conv_a'),
      _commit('a2', 'conv_a'),
      _commit('b1', 'conv_b'),
    ]);
    final api = _OutboxApi()
      ..failures['a1'] = <Object>[
        ApiException(403, '{"error":"forbidden"}'),
      ];
    final state = await _start(api, store);

    await _waitFor(() => state.mlsConversationFailed('conv_a'));
    await _waitFor(() => api.sent.contains('b1'));
    expect(api.sent, isNot(contains('a2')));
    final pending = await store.pendingMlsMessages();
    expect(pending.map((item) => item.idempotencyKey), <String>['a1', 'a2']);
    expect(pending.first.terminal, isTrue);
    expect(pending.first.failureClass, 'terminal:403:forbidden');
    expect(state.mlsConversationFailed('conv_b'), isFalse);

    // Further passes neither resend it nor unblock the group.
    final attempts = api.attempts['a1'];
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await _settle();
    expect(api.attempts['a1'], attempts);
    expect(api.sent, isNot(contains('a2')));

    // Sending into the paused conversation is refused.
    expect(await state.sendMessageTo('conv_a', 'hello'), isFalse);
    expect(state.errorFor(Ops.send), contains('paused'));
    state.dispose();
  });

  test('queued messages survive a restart and go out once, in order', () async {
    final store = await _storeWith(<PendingMlsMessage>[
      _commit('a1', 'conv_a'),
      _commit('a2', 'conv_a'),
    ]);
    final first = _OutboxApi()..hang = true;
    final state = await _start(first, store);
    await _waitFor(() => first.attempts.containsKey('a1'));
    state.dispose();

    final second = _OutboxApi();
    final restarted = await _start(second, store);
    await _waitFor(() async => (await store.pendingMlsMessages()).isEmpty);
    expect(second.sent, <String>['a1', 'a2']);
    restarted.dispose();
  });

  test('a queued revocation commit drains before another is made', () async {
    final store = await _storeWith(<PendingMlsMessage>[
      _commit('rev1', 'conv_a', revocationDeviceId: 'dev_gone'),
    ]);
    final api = _OutboxApi()
      ..failures['rev1'] = <Object>[ApiException(503, '')]
      ..revocations = <MlsRevocation>[
        MlsRevocation(
          conversationId: 'conv_a',
          revokedDeviceId: 'dev_gone',
          revokedAccountId: 'acct_me',
          coordinatorDeviceId: 'dev_me',
          state: 'pending',
          requestedAt: DateTime.utc(2026, 9, 24),
        ),
      ];
    final crypto = _OutboxCrypto(store);
    final state = await _start(api, store, crypto: crypto);
    await _waitFor(() => api.attempts.containsKey('rev1'));
    await _settle();
    expect(crypto.revocationCommits, 0);
    expect((await store.pendingMlsMessages()).single.idempotencyKey, 'rev1');
    state.dispose();
  });

  test('a revocation commit is made once nothing is queued', () async {
    final store = await _storeWith(const <PendingMlsMessage>[]);
    final api = _OutboxApi()
      ..revocations = <MlsRevocation>[
        MlsRevocation(
          conversationId: 'conv_a',
          revokedDeviceId: 'dev_gone',
          revokedAccountId: 'acct_me',
          coordinatorDeviceId: 'dev_me',
          state: 'pending',
          requestedAt: DateTime.utc(2026, 9, 24),
        ),
      ];
    final crypto = _OutboxCrypto(store);
    final state = await _start(api, store, crypto: crypto);
    await _waitFor(() => crypto.revocationCommits == 1);
    await _waitFor(() => api.sent.contains('rev_commit_1'));
    state.dispose();
  });

  test('application messages wait behind their group control messages',
      () async {
    final store =
        await _storeWith(<PendingMlsMessage>[_commit('a1', 'conv_a')]);
    await store.enqueueEnvelope(MessageEnvelope(
      conversationId: 'conv_a',
      idempotencyKey: 'app_a',
      ciphertext: <int>[1],
      cryptoProtocol: 'mls10-openmls-v1',
    ));
    await store.enqueueEnvelope(MessageEnvelope(
      conversationId: 'conv_b',
      idempotencyKey: 'app_b',
      ciphertext: <int>[1],
      cryptoProtocol: 'mls10-openmls-v1',
    ));
    final api = _OutboxApi()..failures['a1'] = <Object>[ApiException(503, '')];
    final state = await _start(api, store);
    await _waitFor(() => api.envelopes.contains('app_b'));
    expect(api.envelopes, isNot(contains('app_a')));
    await _waitFor(() => api.envelopes.contains('app_a'),
        timeout: const Duration(seconds: 4));
    expect(api.sent.indexOf('a1'), isNonNegative);
    state.dispose();
  });
}

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
  deviceSecret: 'secret',
);

PendingMlsMessage _commit(String key, String conversationId,
        {String? revocationDeviceId}) =>
    PendingMlsMessage(
      idempotencyKey: key,
      conversationId: conversationId,
      kind: 'commit',
      payload: const <int>[1],
      revocationDeviceId: revocationDeviceId,
    );

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

Future<MemoryLocalStore> _storeWith(List<PendingMlsMessage> messages) async {
  final store = MemoryLocalStore();
  await store.saveSession(_session);
  await _queue(store, messages);
  return store;
}

Future<AppState> _start(_OutboxApi api, MemoryLocalStore store,
    {_OutboxCrypto? crypto}) async {
  final state = AppState(
    apiClientFactory: (_) => api,
    cryptoService: crypto ?? _OutboxCrypto(store),
    localStore: store,
    syncServiceFactory: (_, __) => _QuietSync(),
  )..conversations = <Conversation>[
      Conversation(id: 'conv_a', kind: 'group'),
      Conversation(id: 'conv_b', kind: 'group'),
    ];
  await state.tryRestoreSession();
  return state;
}

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitFor(FutureOr<bool> Function() condition,
    {Duration timeout = const Duration(seconds: 1)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not reached');
}

class _OutboxApi extends ApiClient {
  _OutboxApi() : super(baseUrl: 'https://localhost:8080');

  final Map<String, List<Object>> failures = <String, List<Object>>{};
  final Map<String, int> attempts = <String, int>{};
  final List<String> sent = <String>[];
  final List<String> envelopes = <String>[];
  List<MlsRevocation> revocations = <MlsRevocation>[];
  bool hang = false;

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[
        Conversation(id: 'conv_a', kind: 'group'),
        Conversation(id: 'conv_b', kind: 'group'),
      ];

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      const <SyncEvent>[];

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async => revocations;

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    envelopes.add(envelope.idempotencyKey);
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
    attempts[idempotencyKey] = (attempts[idempotencyKey] ?? 0) + 1;
    if (hang) await Completer<void>().future;
    final queued = failures[idempotencyKey];
    if (queued != null && queued.isNotEmpty) throw queued.removeAt(0);
    sent.add(idempotencyKey);
    return MlsMessage(
      id: 'mls_$idempotencyKey',
      conversationId: conversationId,
      senderAccountId: 'acct_me',
      senderDeviceId: 'dev_me',
      kind: kind,
      payload: payload,
      idempotencyKey: idempotencyKey,
      syncEventId: sent.length,
      createdAt: DateTime.utc(2026, 9, 24),
    );
  }
}

class _OutboxCrypto implements MlsConversationCryptoService {
  _OutboxCrypto(this.store);

  final MemoryLocalStore store;
  int revocationCommits = 0;

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<void> createRevocationCommit(MlsRevocation revocation) async {
    revocationCommits++;
    await _queue(store, <PendingMlsMessage>[
      _commit('rev_commit_$revocationCommits', revocation.conversationId,
          revocationDeviceId: revocation.revokedDeviceId),
    ]);
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

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  void dispose() => _controller.close();
}
