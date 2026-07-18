import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/errors.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

void main() {
  test('describeError maps API errors, crypto stub, and network failures', () {
    expect(
      describeError(ApiException(400, '{"error":"weak_password"}')),
      'Password must be 12–72 characters.',
    );
    expect(
      describeError(
          StateError('Production MLS/OpenMLS encryption is not integrated')),
      contains('encryption engine'),
    );
    expect(
      describeError(const SocketException('connection refused')),
      contains('Could not reach the server'),
    );
    expect(
      describeError(Exception('internal detail')),
      'Something went wrong. Please try again.',
    );
    // Never leak raw internals to the UI.
    expect(describeError(Exception('internal detail')),
        isNot(contains('internal detail')));
  });

  test('ApiException maps known server codes and falls back by status', () {
    expect(
      ApiException(409, '{"error":"already_setup"}').message,
      contains('already has an owner'),
    );
    expect(
      ApiException(400, '{"error":"invalid_invite"}').message,
      contains('invite code'),
    );
    expect(
      ApiException(500, '{"error":"storage_error"}').message,
      contains('storage problem'),
    );
    expect(
      ApiException(500, 'unmapped').message,
      'The server had a problem. Try again shortly.',
    );
    expect(ApiException(404, '').message, contains('not found'));
  });

  test('malformed timestamps do not throw during message parse', () {
    final envelope = ReceivedMessageEnvelope.fromJson(<String, Object?>{
      'id': 'msg_1',
      'conversation_id': 'conv_1',
      'sender_account_id': 'acct_1',
      'sender_device_id': 'dev_1',
      'idempotency_key': 'k1',
      'ciphertext': '',
      'crypto_protocol': 'test',
      'created_at': 'not-a-timestamp',
      'edited_at': 'also-garbage',
    });
    expect(envelope.createdAt.millisecondsSinceEpoch, 0);
    expect(envelope.editedAt, isNull);
  });

  test('loadMessages records a retryable error and recovers', () async {
    final api = _FlakyMessagesApi()..failMessages = true;
    final state = _connectedState(api);

    await state.loadMessages('conv_1');
    expect(state.isLoadingMessages('conv_1'), isFalse);
    expect(state.messageLoadError('conv_1'), contains('Could not reach'));

    api.failMessages = false;
    await state.loadMessages('conv_1');
    expect(state.messageLoadError('conv_1'), isNull);
    expect(state.messagesByConversation['conv_1'], isEmpty);
  });

  test('checkSetupRequired parses the probe and swallows failures', () async {
    final api = _FlakyMessagesApi();
    final state = _connectedState(api);

    api.setupRequired = true;
    expect(await state.checkSetupRequired('http://localhost:8080'), isTrue);

    api.setupRequired = false;
    expect(await state.checkSetupRequired('http://localhost:8080'), isFalse);

    api.failSetupStatus = true;
    expect(await state.checkSetupRequired('http://localhost:8080'), isNull);
    expect(state.error, isNull);
  });

  test('conversationsLoaded flips after first refresh, resets on logout',
      () async {
    final api = _FlakyMessagesApi();
    final state = _connectedState(api);
    expect(state.conversationsLoaded, isFalse);

    await state.refreshConversations();
    expect(state.conversationsLoaded, isTrue);

    await state.logout();
    expect(state.conversationsLoaded, isFalse);
  });

  test('session round-trips username through the local store', () async {
    final store = MemoryLocalStore();
    await store.saveSession(const Session(
      baseUrl: 'http://localhost:8080',
      token: 't',
      accountId: 'acct_1',
      deviceId: 'dev_1',
      username: 'alice',
    ));
    final restored = await store.loadSession();
    expect(restored?.username, 'alice');
  });
}

AppState _connectedState(ApiClient api) {
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _FakeSyncService(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'http://localhost:8080',
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
      username: 'owner',
    );
}

class _FlakyMessagesApi extends ApiClient {
  _FlakyMessagesApi() : super(baseUrl: 'http://localhost:8080');

  bool failMessages = false;
  bool failSetupStatus = false;
  bool setupRequired = false;

  @override
  Future<Map<String, Object?>> setupStatus() async {
    if (failSetupStatus) {
      throw const SocketException('unreachable');
    }
    return <String, Object?>{'setup_required': setupRequired};
  }

  @override
  Future<List<ReceivedMessageEnvelope>> listMessages(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
    String? after,
  }) async {
    if (failMessages) {
      throw const SocketException('unreachable');
    }
    return <ReceivedMessageEnvelope>[];
  }

  @override
  Future<List<Conversation>> conversations(String token) async {
    return <Conversation>[];
  }

  @override
  Future<List<Device>> devices(String token) async {
    return <Device>[];
  }

  @override
  Future<void> logout(String token) async {}

  @override
  Future<void> markRead(
    String token,
    String conversationId,
    String messageId,
  ) async {}
}

class _FakeSyncService implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  void dispose() {
    _controller.close();
  }
}
