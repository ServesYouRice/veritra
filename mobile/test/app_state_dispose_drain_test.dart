// backgroundWorkIdle completes only after the outbox work a disposed
// AppState started without awaiting has finished, not merely when no store
// call happens to be in flight (TASK-113).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('waits for an outbox pass held between two store calls', () async {
    final store = _GatedStore();
    final api = _Api();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _NoopSync(),
    )
      ..api = api
      ..session = _session
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group'),
      ];

    expect(await state.sendMessageTo('conv_1', 'hello'), isTrue);
    // The pass sent the envelope and now waits to remove it.
    for (var i = 0; i < 200 && !store.removeStarted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(store.removeStarted, isTrue);
    expect(store.inFlight, 1);

    state.dispose();
    var idle = false;
    unawaited(state.backgroundWorkIdle.then((_) => idle = true));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(idle, isFalse, reason: 'the held pass has not finished');

    store.gate.complete();
    await state.backgroundWorkIdle.timeout(const Duration(seconds: 10));
    expect(idle, isTrue);
    store.closed = true;
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(store.callsAfterClose, 0);
  });
}

class _GatedStore extends MemoryLocalStore {
  final Completer<void> gate = Completer<void>();
  bool removeStarted = false;
  bool closed = false;
  int inFlight = 0;
  int callsAfterClose = 0;

  void _touch() {
    if (closed) callsAfterClose++;
  }

  @override
  Future<void> removePendingEnvelope(String idempotencyKey) async {
    _touch();
    removeStarted = true;
    inFlight++;
    try {
      await gate.future;
      await super.removePendingEnvelope(idempotencyKey);
    } finally {
      inFlight--;
    }
  }

  @override
  Future<List<PendingEnvelopeRecord>> pendingEnvelopeRecords() async {
    _touch();
    return super.pendingEnvelopeRecords();
  }

  @override
  Future<List<PendingMlsMessage>> pendingMlsMessages() async {
    _touch();
    return super.pendingMlsMessages();
  }
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {}

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);
}

class _NoopSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
