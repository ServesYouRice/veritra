import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

const owner = Session(
    baseUrl: 'https://example.test',
    token: 'old-token',
    accountId: 'alice',
    deviceId: 'dev');
const other = Session(
    baseUrl: 'https://example.test',
    token: 'new-token',
    accountId: 'bob',
    deviceId: 'other');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('queued old plaintext cannot capture a newer session', () async {
    final store = _HeldCapacityStore(), crypto = _Mls();
    final state = AppState(
        apiClientFactory: (_) => _Api(),
        syncServiceFactory: (_, __) => _QuietSync(),
        localStore: store,
        cryptoService: crypto);
    addTearDown(state.dispose);
    state.session = owner;
    state.api = _Api();
    state.conversations = [
      Conversation(id: 'conv', kind: 'group', createdBy: 'alice')
    ];
    final first = state.sendMessageTo('conv', 'first');
    await store.entered.future;
    final second = state.sendMessageTo('conv', 'queued private text');
    state.session = other;
    store.release.complete();
    expect(await first, false);
    expect(await second, false);
    expect(crypto.calls, 0);
    expect(await store.pendingEnvelopes(), isEmpty);
  });

  test('forward stops after first destination changes session', () async {
    final store = MemoryLocalStore(), crypto = _Mls();
    final state = AppState(
        apiClientFactory: (_) => _Api(),
        syncServiceFactory: (_, __) => _QuietSync(),
        localStore: store,
        cryptoService: crypto);
    addTearDown(state.dispose);
    state.session = owner;
    state.api = _Api();
    state.conversations = [
      for (final id in ['source', 'dest1', 'dest2'])
        Conversation(id: id, kind: 'group', createdBy: 'alice')
    ];
    await store.saveCryptoState(
        StoredCryptoState(
            counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
        0);
    await store.commitMlsTransition(MlsStateTransition(
        messageId: 'seed',
        conversationId: 'source',
        expectedCounter: 1,
        expectedCursor: 0,
        state: StoredCryptoState(
            counter: 2, stateKey: List.filled(32, 1), sealedState: [2]),
        cursor: 1,
        messageEffects: [
          const InsertMessageEffect(
              key: 'dev:source',
              conversationId: 'source',
              senderAccountId: 'alice',
              senderDeviceId: 'dev',
              kind: 'text',
              body: 'private source',
              createdAt: 1,
              state: 'received')
        ]));
    await state.refreshHistory('source');
    crypto.afterEncrypt = () => state.session = other;
    expect(
        await state.forwardMessage(
            state.historyFor('source').forKey('dev:source')!,
            ['dest1', 'dest2']),
        false);
    expect(crypto.calls, 1);
    expect(await store.pendingEnvelopes(), isEmpty);
  });
}

class _HeldCapacityStore extends MemoryLocalStore {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<bool> hasOutboxCapacity() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return true;
  }
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');
  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {}
}

class _Mls implements MlsConversationCryptoService {
  int calls = 0;
  void Function()? afterEncrypt;
  @override
  Future<MessageEnvelope> encryptPayload(
      String conversationId, AppPayloadType type, Map<String, Object?> body,
      {List<String> attachmentRefs = const [], String? draftText}) async {
    calls++;
    afterEncrypt?.call();
    return MessageEnvelope(
        conversationId: conversationId,
        idempotencyKey: 'action-$calls',
        ciphertext: [1],
        cryptoProtocol: 'test');
  }

  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}
