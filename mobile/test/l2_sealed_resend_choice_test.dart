import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/sealed_sender.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// L2-3, owner decision 2026-11-12 ("Ask before re-sending"): a hostile
/// server can answer 409 `sealed_not_eligible` to any sealed post it
/// chooses. The app must not answer that by sending the message identified
/// under the same key, which would tell the server who sent that post. The
/// message waits in the outbox, marked "couldn't send hidden", until the
/// person taps "Send normally" (one identified send) or "Discard" (none).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'a refused sealed post waits; nothing goes identified until the tap, '
      'then exactly once', () async {
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    await store.enqueueEnvelope(_sealedEnvelope());
    final api = _Api();
    final poster = _RefusingPoster();
    final crypto = _Crypto(store);
    var state = await _start(api, store, crypto, poster);

    await _until(() => state.outboxNeedsSealedChoice(_key));
    expect(poster.posts, 1);
    expect(state.outboxState(_key), OutboxDeliveryState.terminal);
    expect(state.outboxFailureMessage(_key), state.l10n.outboxSealedRefused);
    final record = state.outboxRecord(_key)!;
    expect(record.envelope.sealed, isTrue);
    expect(record.failureClass, sealedRefusedFailureClass);

    // Further passes, a resume and a plain retry send nothing at all.
    state.handleAppLifecycleState(AppLifecycleState.paused);
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await state.retryEnvelope(_key);
    await _settle();
    expect(api.identifiedSends, isEmpty);
    expect(poster.posts, 1);
    expect(crypto.reencrypts, 0);

    // A restart keeps the choice and still sends nothing.
    await _stop(state);
    state = await _start(api, store, crypto, poster);
    await _until(() => state.outboxNeedsSealedChoice(_key));
    await _settle();
    expect(api.identifiedSends, isEmpty);
    expect(poster.posts, 1);
    expect(crypto.reencrypts, 0);

    // The tap: one fresh identified encryption, one identified send.
    await state.sendSealedNormally(_key);
    await _until(() => api.identifiedSends.isNotEmpty);
    await _until(() => state.pendingOutbox.isEmpty);
    expect(crypto.reencrypts, 1);
    expect(api.identifiedSends, hasLength(1));
    final sent = api.identifiedSends.single;
    expect(sent.sealed, isFalse);
    expect(sent.idempotencyKey, _key);
    expect(sent.ciphertext, _identifiedCiphertext);
    expect(poster.posts, 1);

    // A second tap, and later passes, change nothing.
    await state.sendSealedNormally(_key);
    state.handleAppLifecycleState(AppLifecycleState.paused);
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await _settle();
    expect(crypto.reencrypts, 1);
    expect(api.identifiedSends, hasLength(1));
    await _stop(state);
  });

  test('discard sends nothing, identified or sealed', () async {
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    await store.enqueueEnvelope(_sealedEnvelope());
    final api = _Api();
    final poster = _RefusingPoster();
    final crypto = _Crypto(store);
    final state = await _start(api, store, crypto, poster);
    await _until(() => state.outboxNeedsSealedChoice(_key));

    await state.discardEnvelope(_key);
    expect(state.pendingOutbox, isEmpty);
    expect(await store.pendingEnvelopes(), isEmpty);
    expect(state.outboxNeedsSealedChoice(_key), isFalse);
    // "Send normally" after a discard finds nothing to send.
    await state.sendSealedNormally(_key);
    state.handleAppLifecycleState(AppLifecycleState.paused);
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await _settle();
    expect(api.identifiedSends, isEmpty);
    expect(crypto.reencrypts, 0);
    expect(poster.posts, 1);
    await _stop(state);
  });

  test('send normally waits while the chat has MLS work queued', () async {
    final store = _QueuedMls();
    await store.saveSession(_session);
    await store.enqueueEnvelope(_sealedEnvelope());
    final api = _Api();
    final poster = _RefusingPoster();
    final crypto = _Crypto(store);
    final state = await _start(api, store, crypto, poster);
    await _until(() => state.outboxNeedsSealedChoice(_key));

    store.pending = <PendingMlsMessage>[
      const PendingMlsMessage(
          idempotencyKey: 'mls_1',
          conversationId: _conversation,
          kind: 'update',
          payload: <int>[1]),
    ];
    await state.sendSealedNormally(_key);
    expect(state.errorFor(Ops.send), state.l10n.outboxSealedResendHeld);
    expect(crypto.reencrypts, 0);
    expect(api.identifiedSends, isEmpty);
    // Still waiting for the choice.
    expect(state.outboxNeedsSealedChoice(_key), isTrue);
    store.pending = const <PendingMlsMessage>[];
    await _stop(state);
  });
}

const _conversation = 'conv_1';
const _key = 'idem-aaaaaaaaaaaaaaaaaaaaaaaa';
const _identifiedCiphertext = <int>[4, 5, 6];

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
  deviceSecret: 'secret',
);

MessageEnvelope _sealedEnvelope() => MessageEnvelope(
      conversationId: _conversation,
      idempotencyKey: _key,
      ciphertext: utf8.encode('sealed-ciphertext'),
      cryptoProtocol: 'mls10-openmls-v1',
      cryptoMetadata: const <String, Object?>{
        'protocol_version': 1,
        'group_id': _conversation,
        'content_type': 'application',
        'payload_version': 1,
        'mls_epoch': 3,
      },
      frankCommit: List<int>.filled(32, 4),
      sealedToken: SealedToken(
        conversationId: _conversation,
        keyId: 'a' * 32,
        epoch: sealedUtcDay(DateTime.now()),
        nonce: List<int>.generate(32, (i) => i),
        output: List<int>.filled(64, 1),
      ),
    );

Future<AppState> _start(
    _Api api, LocalStore store, _Crypto crypto, _RefusingPoster poster) async {
  final state = AppState(
    apiClientFactory: (_) => api,
    cryptoService: crypto,
    localStore: store,
    syncServiceFactory: (_, __) => _QuietSync(),
  )..sealedPostClientFactory = (_) => poster;
  await state.tryRestoreSession();
  return state;
}

Future<void> _stop(AppState state) async {
  state.dispose();
  await state.backgroundWorkIdle;
}

Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<void> _until(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('condition not reached');
}

/// Answers every sealed post with 409 `sealed_not_eligible`, as a hostile
/// server may for a post it chooses.
class _RefusingPoster extends SealedPostClient {
  _RefusingPoster() : super(baseUrl: 'https://localhost:8080');

  int posts = 0;

  @override
  Future<void> post(MessageEnvelope envelope) async {
    posts++;
    throw ApiException(409, '{"error":"sealed_not_eligible"}');
  }
}

class _QueuedMls extends MemoryLocalStore {
  List<PendingMlsMessage> pending = const <PendingMlsMessage>[];

  @override
  Future<List<PendingMlsMessage>> pendingMlsMessages() async => pending;
}

class _Api extends ApiClient with LegacySyncPageFake {
  _Api() : super(baseUrl: 'https://localhost:8080');

  /// Every identified (session) send, in order.
  final List<MessageEnvelope> identifiedSends = <MessageEnvelope>[];

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    // The real client refuses a sealed envelope here too.
    if (envelope.sealed) throw StateError('sealed envelope on session route');
    identifiedSends.add(envelope);
  }

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[Conversation(id: _conversation, kind: 'dm')];

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<Map<String, Object?>> setupStatus() async =>
      const <String, Object?>{'sealed_sender': true};

  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      const <SyncEvent>[];

  @override
  Future<List<MlsMessage>> mlsMessages(String token,
          {int after = 0, int limit = 100}) async =>
      const <MlsMessage>[];

  @override
  Future<void> publishDeviceKeyPackages(
    String token,
    List<List<int>> keyPackages, {
    Duration lifetime = const Duration(days: 14),
  }) async {}
}

/// An MLS crypto service that can send sealed: its re-encryption puts a
/// fresh identified copy in the sealed entry's place, as the native one
/// does.
class _Crypto
    implements MlsConversationCryptoService, SealedSendingCryptoService {
  _Crypto(this.store);

  final LocalStore store;
  int reencrypts = 0;

  @override
  set sealedTokenSource(SealedTokenSource? source) {}

  @override
  Future<MessageEnvelope?> reencryptSealedAsIdentified(
      MessageEnvelope sealed) async {
    reencrypts++;
    final identified = MessageEnvelope(
      conversationId: sealed.conversationId,
      idempotencyKey: sealed.idempotencyKey,
      ciphertext: _identifiedCiphertext,
      cryptoProtocol: sealed.cryptoProtocol,
      cryptoMetadata: sealed.cryptoMetadata,
    );
    await store.removePendingEnvelope(sealed.idempotencyKey);
    await store.enqueueEnvelope(identified);
    return identified;
  }

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<List<List<int>>> createReplenishmentKeyPackages(
          {int count = 5}) async =>
      <List<int>>[
        for (var i = 0; i < count; i++) <int>[i]
      ];

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
  Future<void> dispose() => _controller.close();
}
