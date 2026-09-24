import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// Two real OpenMLS devices exchanging every message payload type through
/// [NativeCryptoService], with the server's role played by the test.
void main() {
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final skip = libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false;

  test('decrypted history is kept for text, reply, edit, reaction, delete',
      () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);

    final hello = await alice
        .send(AppPayloadType.text, <String, Object?>{'text': 'hello'});
    final helloKey = messageKey('dev_alice', hello.idempotencyKey);
    expect((await alice.history()).single.state, LocalMessageState.pending);
    await bob.receive(alice, hello);
    await alice.receive(alice, hello);
    expect((await alice.history()).single.state, LocalMessageState.sent);
    expect((await bob.history()).single.body, 'hello');

    final reply = await bob.send(AppPayloadType.reply,
        <String, Object?>{'text': 'hi back', 'reply_to_id': helloKey});
    await alice.receive(bob, reply);
    expect((await alice.history()).last.replyTo, helloKey);
    expect((await alice.history()).last.body, 'hi back');

    final edit = await alice.send(AppPayloadType.edit,
        <String, Object?>{'message_id': helloKey, 'text': 'hello!'});
    await bob.receive(alice, edit);
    final edited =
        (await bob.history()).firstWhere((item) => item.key == helloKey);
    expect(edited.body, 'hello!');
    expect(edited.editedAt, isNotNull);

    // Bob cannot edit Alice's message, on either device.
    final forged = await bob.send(AppPayloadType.edit,
        <String, Object?>{'message_id': helloKey, 'text': 'forged'});
    await alice.receive(bob, forged);
    expect(
        (await alice.history()).firstWhere((item) => item.key == helloKey).body,
        'hello!');

    final reaction = await bob.send(AppPayloadType.reaction,
        <String, Object?>{'message_id': helloKey, 'reaction': '👍'});
    await alice.receive(bob, reaction);
    expect((await alice.store.loadReactions('conv_1')).single.reaction, '👍');

    final delete = await alice
        .send(AppPayloadType.delete, <String, Object?>{'message_id': helloKey});
    await bob.receive(alice, delete);
    final deleted =
        (await bob.history()).firstWhere((item) => item.key == helloKey);
    expect(deleted.body, isNull);
    expect(deleted.deletedAt, isNotNull);
  }, skip: skip);

  test('a service reloads MLS state that moved without it', () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);

    // A second service on the same store advances the committed state, as a
    // backup restore or a second app instance would.
    final other =
        NativeCryptoService(bindings: bindings, localStore: alice.store);
    await other.activateSession(const Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: 'acct_alice',
      deviceId: 'dev_alice',
    ));
    final first = await other.encryptPayload(
        'conv_1', AppPayloadType.text, <String, Object?>{'text': 'one'});
    await alice.store.removePendingEnvelope(first.idempotencyKey);
    await other.dispose();

    // The original service must not reuse its stale in-memory ratchet.
    final second =
        await alice.send(AppPayloadType.text, <String, Object?>{'text': 'two'});
    await bob.receive(alice, first);
    await bob.receive(alice, second);
    expect((await bob.history()).map((item) => item.body), <String?>[
      'one',
      'two',
    ]);
  }, skip: skip);

  test('a spoofed sender is kept as unverifiable and sync continues', () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);

    final spoofed = await bob
        .send(AppPayloadType.text, <String, Object?>{'text': 'I am carol'});
    await alice.receive(bob, spoofed, claimedAccountId: 'acct_carol');
    final record = (await alice.history()).single;
    expect(record.kind, LocalMessageKind.unverifiable);
    expect(record.body, isNull);

    final next =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'next'});
    await alice.receive(bob, next);
    expect((await alice.history()).last.body, 'next');
  }, skip: skip);
}

Future<void> _startConversation(_Client alice, _Client bob) async {
  final package =
      (await bob.service.createReplenishmentKeyPackages(count: 1)).single;
  await alice.service.initializeConversation('conv_1', <DeviceKeyPackage>[
    DeviceKeyPackage(
      id: 'kp_1',
      deviceId: bob.deviceId,
      accountId: bob.accountId,
      keyPackage: package,
      ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
    ),
  ]);
  final welcome = (await alice.store.pendingMlsMessages()).single;
  await alice.store.removePendingMlsMessage(welcome.idempotencyKey);
  await bob.service.processMlsMessage(MlsMessage(
    id: 'mls_1',
    conversationId: 'conv_1',
    senderAccountId: alice.accountId,
    senderDeviceId: alice.deviceId,
    kind: welcome.kind,
    payload: welcome.payload,
    idempotencyKey: welcome.idempotencyKey,
    syncEventId: bob.nextEvent(),
    createdAt: DateTime.now().toUtc(),
    recipientDeviceId: bob.deviceId,
  ));
}

int _serverIds = 0;

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  int _events = 0;

  static Future<_Client> enroll(
      NativeCryptoBindings bindings, String accountId, String deviceId) async {
    final store = MemoryLocalStore();
    final service = NativeCryptoService(bindings: bindings, localStore: store);
    await service.createEnrollmentCredential(EnrollmentReservation(
      id: 'res_$deviceId',
      accountId: accountId,
      deviceId: deviceId,
      challenge: const <int>[1, 2, 3],
    ));
    await service.activateSession(Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    ));
    return _Client(service, store, accountId, deviceId);
  }

  int nextEvent() => ++_events;

  Future<List<LocalMessage>> history() => store.loadMessages('conv_1');

  Future<MessageEnvelope> send(
      AppPayloadType type, Map<String, Object?> body) async {
    final envelope = await service.encryptPayload('conv_1', type, body);
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  Future<void> receive(_Client from, MessageEnvelope sent,
      {String? claimedAccountId}) async {
    await service.processApplicationMessage(
      ReceivedMessageEnvelope(
        id: 'srv_${++_serverIds}',
        conversationId: sent.conversationId,
        senderAccountId: claimedAccountId ?? from.accountId,
        senderDeviceId: from.deviceId,
        idempotencyKey: sent.idempotencyKey,
        ciphertext: sent.ciphertext,
        cryptoProtocol: sent.cryptoProtocol,
        createdAt: DateTime.now().toUtc(),
      ),
      nextEvent(),
    );
  }
}
