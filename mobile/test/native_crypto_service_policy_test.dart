import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// Real OpenMLS devices driven through [NativeCryptoService]: how a commit
/// bundle settles when sync got there first (TASK-057), and what happens to
/// sync events that can never succeed (D54, TASK-058).
void main() {
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final skip = libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false;

  group('a commit bundle sync already settled (TASK-057)', () {
    test('completes without a fork after later commits, and changes nothing',
        () async {
      final bindings = NativeCryptoBindings.open(libraryPath!);
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      final carol = await _Client.enroll(bindings, 'acct_carol', 'dev_carol');
      await _startConversation(alice, bob);

      await alice.service.stageMembershipChange('conv_1',
          adds: <DeviceKeyPackage>[await carol.keyPackage()]);
      // The outbox worker holds this item across its HTTP call.
      final held = (await alice.store.pendingMlsMessages()).single;
      final bundle = MlsCommitBundle.decode(held.payload);

      // Sync delivers the accepted commit first: it merges and settles it.
      await alice.service.processMlsMessage(
          _commit(alice, from: alice, item: held, payload: bundle.commit));
      expect(await alice.store.pendingMlsMessages(), isEmpty);
      // Bob follows, then his self-update moves the group on again.
      await bob.service.processMlsMessage(
          _commit(bob, from: alice, item: held, payload: bundle.commit));
      await bob.service.stageSelfUpdate('conv_1');
      final bobs = (await bob.store.pendingMlsMessages()).single;
      await bob.service.completeCommitBundle(bobs);
      await alice.service.processMlsMessage(_commit(alice,
          from: bob,
          item: bobs,
          payload: MlsCommitBundle.decode(bobs.payload).commit));
      expect(
          await alice.service.groupEpoch('conv_1'), (epoch: 3, pending: false));
      final counter = (await alice.store.loadCryptoState())!.counter;

      // The worker's answer arrives late, with the item it still holds.
      await alice.service.completeCommitBundle(held);

      expect((await alice.store.loadCryptoState())!.counter, counter);
      expect(
          await alice.service.groupEpoch('conv_1'), (epoch: 3, pending: false));
      // The group still works.
      final hello = await bob
          .send(AppPayloadType.text, <String, Object?>{'text': 'still here'});
      await alice.receive(bob, hello);
      expect((await alice.history()).last.body, 'still here');
    }, skip: skip);

    test('a pending bundle still fails closed when the group does not match',
        () async {
      final bindings = NativeCryptoBindings.open(libraryPath!);
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      final carol = await _Client.enroll(bindings, 'acct_carol', 'dev_carol');
      await _startConversation(alice, bob);
      await alice.service.stageMembershipChange('conv_1',
          adds: <DeviceKeyPackage>[await carol.keyPackage()]);
      final item = (await alice.store.pendingMlsMessages()).single;
      final bundle = MlsCommitBundle.decode(item.payload);
      final counter = (await alice.store.loadCryptoState())!.counter;

      // Same outbox entry, but it claims an epoch the commit does not lead
      // to: that would be a fork.
      final mismatched = PendingMlsMessage(
        idempotencyKey: item.idempotencyKey,
        conversationId: item.conversationId,
        kind: item.kind,
        payload: MlsCommitBundle(
          epoch: bundle.epoch + 1,
          commit: bundle.commit,
          welcome: bundle.welcome,
          added: bundle.added,
        ).encode(),
      );
      await expectLater(
          alice.service.completeCommitBundle(mismatched),
          throwsA(isA<StateError>().having((error) => error.message, 'message',
              'accepted MLS commit does not match the group')));
      // Rolled back: the commit is still staged and the entry still queued.
      expect((await alice.store.loadCryptoState())!.counter, counter);
      expect(
          await alice.service.groupEpoch('conv_1'), (epoch: 1, pending: true));
      expect(await alice.store.pendingMlsMessages(), hasLength(1));

      await alice.service.completeCommitBundle(item);
      expect(
          await alice.service.groupEpoch('conv_1'), (epoch: 2, pending: false));
      expect(await alice.store.pendingMlsMessages(), isEmpty);
    }, skip: skip);

    test('abandoning a settled bundle keeps a newer staged commit', () async {
      final bindings = NativeCryptoBindings.open(libraryPath!);
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      final carol = await _Client.enroll(bindings, 'acct_carol', 'dev_carol');
      await _startConversation(alice, bob);

      await alice.service.stageMembershipChange('conv_1',
          adds: <DeviceKeyPackage>[await carol.keyPackage()]);
      final held = (await alice.store.pendingMlsMessages()).single;
      await alice.service.processMlsMessage(_commit(alice,
          from: alice,
          item: held,
          payload: MlsCommitBundle.decode(held.payload).commit));
      // A later change for the same conversation is staged next.
      await alice.service.stageSelfUpdate('conv_1');
      final newer = (await alice.store.pendingMlsMessages()).single;
      expect(
          await alice.service.groupEpoch('conv_1'), (epoch: 2, pending: true));
      final counter = (await alice.store.loadCryptoState())!.counter;

      // A late refusal for the settled bundle must not drop the newer one.
      await alice.service.abandonCommitBundle(held);

      expect((await alice.store.loadCryptoState())!.counter, counter);
      expect(
          await alice.service.groupEpoch('conv_1'), (epoch: 2, pending: true));
      expect((await alice.store.pendingMlsMessages()).single.idempotencyKey,
          newer.idempotencyKey);
      await alice.service.completeCommitBundle(newer);
      expect(
          await alice.service.groupEpoch('conv_1'), (epoch: 3, pending: false));
    }, skip: skip);
  });
}

MlsMessage _commit(_Client to,
        {required _Client from,
        required PendingMlsMessage item,
        required List<int> payload}) =>
    MlsMessage(
      id: 'mls_${++_serverIds}',
      conversationId: 'conv_1',
      senderAccountId: from.accountId,
      senderDeviceId: from.deviceId,
      kind: 'commit',
      payload: payload,
      idempotencyKey: item.idempotencyKey,
      syncEventId: to.nextEvent(),
      createdAt: DateTime.now().toUtc(),
    );

Future<void> _startConversation(_Client alice, _Client bob) async {
  await alice.service.initializeConversation(
      'conv_1', <DeviceKeyPackage>[await bob.keyPackage()]);
  await _accept(alice, <_Client>[bob], const <_Client>[]);
}

/// Plays the server accepting [from]'s queued commit bundle: [from] merges
/// it, [joiners] get the Welcome and [members] the commit.
Future<void> _accept(
    _Client from, List<_Client> joiners, List<_Client> members) async {
  final item = (await from.store.pendingMlsMessages()).single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await from.service.completeCommitBundle(item);
  for (final member in members) {
    await member.service.processMlsMessage(
        _commit(member, from: from, item: item, payload: bundle.commit));
  }
  for (final joiner in joiners) {
    await joiner.service.processMlsMessage(_welcome(joiner,
        from: from, idempotencyKey: item.idempotencyKey, payload: bundle));
  }
}

MlsMessage _welcome(_Client to,
        {required _Client from,
        required String idempotencyKey,
        required MlsCommitBundle payload,
        String? id}) =>
    MlsMessage(
      id: id ?? 'mls_${++_serverIds}',
      conversationId: 'conv_1',
      senderAccountId: from.accountId,
      senderDeviceId: from.deviceId,
      kind: 'welcome',
      payload: payload.welcome,
      idempotencyKey: '$idempotencyKey:welcome:${to.deviceId}',
      syncEventId: to.nextEvent(),
      createdAt: DateTime.now().toUtc(),
      recipientDeviceId: to.deviceId,
    );

int _serverIds = 0;

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  int _events = 0;

  static Future<_Client> enroll(
      NativeCryptoBindings bindings, String accountId, String deviceId,
      {MemoryLocalStore? store}) async {
    final local = store ?? MemoryLocalStore();
    final service = NativeCryptoService(bindings: bindings, localStore: local);
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
    return _Client(service, local, accountId, deviceId);
  }

  int nextEvent() => ++_events;

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$deviceId${++_serverIds}',
        deviceId: deviceId,
        accountId: accountId,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  Future<List<LocalMessage>> history() => store.loadMessages('conv_1');

  Future<MessageEnvelope> send(
      AppPayloadType type, Map<String, Object?> body) async {
    final envelope = await service.encryptPayload('conv_1', type, body);
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  ReceivedMessageEnvelope envelopeFrom(_Client from, MessageEnvelope sent,
          {List<int>? ciphertext, String? id}) =>
      ReceivedMessageEnvelope(
        id: id ?? 'srv_${++_serverIds}',
        conversationId: sent.conversationId,
        senderAccountId: from.accountId,
        senderDeviceId: from.deviceId,
        idempotencyKey: sent.idempotencyKey,
        ciphertext: ciphertext ?? sent.ciphertext,
        cryptoProtocol: sent.cryptoProtocol,
        createdAt: DateTime.now().toUtc(),
      );

  Future<List<int>?> receive(_Client from, MessageEnvelope sent) =>
      service.processApplicationMessage(envelopeFrom(from, sent), nextEvent());
}
