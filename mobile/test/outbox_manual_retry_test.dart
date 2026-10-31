// A retry the person tapped that fails in local storage shows an error
// under Ops.send; the delivery worker never throws, so retryEnvelope cannot
// learn it any other way (TASK-042).

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
  token: 'owner-token',
  accountId: 'acct_owner',
  deviceId: 'dev_owner',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a tapped retry that fails locally reports it under Ops.send', () async {
    final store = _FailingStore();
    await store.enqueueEnvelope(MessageEnvelope(
      conversationId: 'conv_1',
      idempotencyKey: 'env_1',
      ciphertext: const <int>[1],
      cryptoProtocol: 'test-only-not-production',
    ));
    final api = _Api();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _NoopSync(),
    )
      ..api = api
      ..session = _session;

    store.failRecording = true;
    await state.retryEnvelope('env_1');

    expect(api.sent, <String>['env_1']);
    expect(state.errorFor(Ops.send), isNotNull);
    expect(state.session, isNotNull);
    state.dispose();
  });
}

class _FailingStore extends MemoryLocalStore {
  bool failRecording = false;

  @override
  Future<void> recordOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  }) async {
    if (failRecording) throw StateError('database is locked');
    return super.recordOutboxFailure(idempotencyKey,
        failureClass: failureClass,
        terminal: terminal,
        nextAttemptAt: nextAttemptAt);
  }
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  final List<String> sent = <String>[];

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    sent.add(envelope.idempotencyKey);
    throw ApiException(503, '{"error":"unavailable"}');
  }
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
