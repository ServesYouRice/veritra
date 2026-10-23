// Card I31: concurrent flush requests coalesce into one delivery worker, and
// each rejection status follows its terminal or authentication behaviour
// with accurate, actionable copy.

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

  AppState stateFor(MemoryLocalStore store, _DeliveryApi api) => AppState(
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

  Future<void> settle(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('overlapping flush requests coalesce into one sender', () async {
    final store = MemoryLocalStore();
    final api = _DeliveryApi()..gate = Completer<void>();
    final state = stateFor(store, api);

    // The first send holds the worker; the next two sends ask for another
    // pass while it is still running.
    expect(await state.sendMessageTo('conv_1', 'one'), isTrue);
    await settle(() => api.inFlight == 1);
    expect(api.inFlight, 1);
    expect(await state.sendMessageTo('conv_1', 'two'), isTrue);
    expect(await state.sendMessageTo('conv_1', 'three'), isTrue);
    expect(api.peak, 1);
    api.gate!.complete();

    var remaining = 3;
    for (var i = 0; i < 200; i++) {
      remaining = (await store.pendingEnvelopes()).length;
      if (remaining == 0) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(remaining, 0);
    expect(api.peak, 1, reason: 'two flushes ran at the same time');
    expect(api.sent, hasLength(3));
    expect(api.sent.toSet(), hasLength(3),
        reason: 'an envelope was sent twice');
    state.dispose();
  });

  test('99 queued: the 100th send is accepted, the 101st refused unencrypted',
      () async {
    final store = MemoryLocalStore();
    for (var index = 0; index < maxPendingEnvelopes - 1; index++) {
      await store.enqueueEnvelope(_envelope('queued_$index'));
    }
    final api = _DeliveryApi()..gate = Completer<void>();
    final crypto = _CountingCrypto();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: crypto,
      localStore: store,
      syncServiceFactory: (_, __) => _NoopSync(),
    )
      ..api = api
      ..session = _session
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group'),
      ];

    expect(await state.sendMessageTo('conv_1', 'hundredth'), isTrue);
    expect(await store.pendingEnvelopes(), hasLength(maxPendingEnvelopes));
    expect(crypto.encryptCalls, 1);
    expect(await state.sendMessageTo('conv_1', 'one too many'), isFalse);
    expect(crypto.encryptCalls, 1, reason: 'encrypted past the bound');
    final keys =
        (await store.pendingEnvelopes()).map((item) => item.idempotencyKey);
    expect(keys, hasLength(maxPendingEnvelopes));
    expect(keys, contains('queued_0'));
    api.gate!.complete();
    state.dispose();
  });

  for (final status in <int>[404, 409, 413, 422, 507]) {
    test('$status is terminal: kept for copy or discard, never resent',
        () async {
      final store = MemoryLocalStore();
      await store.enqueueEnvelope(_envelope('terminal_$status'),
          draftText: 'draft $status');
      final api = _DeliveryApi()
        ..failure = ApiException(
            status,
            status == 507
                ? '{"error":"storage_quota_exceeded"}'
                : '{"error":"rejected"}');
      final state = stateFor(store, api);

      await state.retryEnvelope('terminal_$status');

      expect(api.sent, <String>['terminal_$status']);
      expect(
          state.outboxState('terminal_$status'), OutboxDeliveryState.terminal);
      final record = (await store.pendingEnvelopeRecords()).single;
      expect(record.terminal, isTrue);
      expect(record.draftText, 'draft $status');
      expect(state.session, isNotNull, reason: 'a rejection is not a logout');
      expect(
        state.outboxFailureMessage('terminal_$status'),
        status == 507
            ? state.l10n.apiErrorStorageFull
            : state.l10n.outboxSendFailed,
      );

      // A terminal item is not retried, by the worker or by the user.
      await state.retryEnvelope('terminal_$status');
      expect(api.sent, hasLength(1));

      await state.discardEnvelope('terminal_$status');
      expect(await store.pendingEnvelopes(), isEmpty);
      state.dispose();
    });
  }

  test('quota copy names the cause and the fix', () {
    final state = stateFor(MemoryLocalStore(), _DeliveryApi());
    final copy = state.l10n.apiErrorStorageFull.toLowerCase();
    expect(copy, contains('storage'));
    expect(copy, anyOf(contains('delete'), contains('administrator')));
    expect(state.l10n.outboxSendFailed.toLowerCase(),
        allOf(contains('copy'), contains('discard')));
    state.dispose();
  });

  test('401 signs out but keeps the accepted envelope for reauthentication',
      () async {
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    await store.enqueueEnvelope(_envelope('auth_401'), draftText: 'draft');
    final api = _DeliveryApi()
      ..failure = ApiException(401, '{"error":"unauthorized"}');
    final state = stateFor(store, api);

    await state.retryEnvelope('auth_401');

    expect(api.sent, <String>['auth_401']);
    expect(state.session, isNull);
    final record = (await store.pendingEnvelopeRecords()).single;
    expect(record.envelope.idempotencyKey, 'auth_401');
    expect(record.terminal, isFalse);
    expect(record.failureClass, 'auth');
    expect(record.draftText, 'draft');
    state.dispose();
  });
}

MessageEnvelope _envelope(String key) => MessageEnvelope(
      conversationId: 'conv_1',
      idempotencyKey: key,
      ciphertext: <int>[1, 2, 3],
      cryptoProtocol: 'test-only-not-production',
    );

class _DeliveryApi extends ApiClient {
  _DeliveryApi() : super(baseUrl: 'https://localhost:8080');

  Completer<void>? gate;
  ApiException? failure;
  final List<String> sent = <String>[];
  int inFlight = 0;
  int peak = 0;

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    sent.add(envelope.idempotencyKey);
    inFlight++;
    if (inFlight > peak) peak = inFlight;
    try {
      final hold = gate;
      if (hold != null && !hold.isCompleted) await hold.future;
      final error = failure;
      if (error != null) throw error;
    } finally {
      inFlight--;
    }
  }

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);
}

class _CountingCrypto extends TestOnlyCryptoService {
  int encryptCalls = 0;

  @override
  Future<MessageEnvelope> encrypt(String conversationId, String plaintext) {
    encryptCalls++;
    return super.encrypt(conversationId, plaintext);
  }
}

class _NoopSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}
