import 'dart:convert';
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

  group('sync events that can never succeed (D54, TASK-058)', () {
    test('a message from an epoch this device never held is passed with a '
        'placeholder', () async {
      final bindings = NativeCryptoBindings.open(libraryPath!);
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      final carol = await _Client.enroll(bindings, 'acct_carol', 'dev_carol');
      await _startConversation(alice, bob);
      final early =
          await alice.send(AppPayloadType.text, <String, Object?>{'text': 'e1'});
      await alice.service.stageMembershipChange('conv_1',
          adds: <DeviceKeyPackage>[await carol.keyPackage()]);
      await _accept(alice, <_Client>[carol], <_Client>[bob]);
      final counter = (await carol.store.loadCryptoState())!.counter;

      // Epoch 1 is from before Carol joined.
      final envelope = carol.envelopeFrom(alice, early);
      final event = carol.nextEvent();
      expect(await carol.service.processApplicationMessage(envelope, event),
          isNull);

      await _expectPlaceholder(carol, envelope, event);
      expect((await carol.store.loadCryptoState())!.counter, counter + 1);
      // Sync goes on, and the group still decrypts.
      final next =
          await alice.send(AppPayloadType.text, <String, Object?>{'text': 'hi'});
      await carol.receive(alice, next);
      expect((await carol.history()).map((row) => row.body), contains('hi'));
    }, skip: skip);

    test('a damaged ciphertext is passed with a placeholder', () async {
      final bindings = NativeCryptoBindings.open(libraryPath!);
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      await _startConversation(alice, bob);
      final sent =
          await bob.send(AppPayloadType.text, <String, Object?>{'text': 'one'});
      final damaged = List<int>.of(sent.ciphertext);
      damaged[damaged.length - 1] ^= 0xff;

      final envelope = alice.envelopeFrom(bob, sent, ciphertext: damaged);
      final event = alice.nextEvent();
      expect(await alice.service.processApplicationMessage(envelope, event),
          isNull);

      await _expectPlaceholder(alice, envelope, event);
      final next =
          await bob.send(AppPayloadType.text, <String, Object?>{'text': 'two'});
      await alice.receive(bob, next);
      expect((await alice.history()).map((row) => row.body), contains('two'));
    }, skip: skip);

    test('a replayed message whose secrets are gone is passed with a '
        'placeholder', () async {
      final bindings = NativeCryptoBindings.open(libraryPath!);
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      await _startConversation(alice, bob);
      final sent =
          await bob.send(AppPayloadType.text, <String, Object?>{'text': 'once'});
      await alice.receive(bob, sent);

      // The same ciphertext again, as a new event: its key was used up.
      final replay = alice.envelopeFrom(bob, sent);
      final event = alice.nextEvent();
      expect(
          await alice.service.processApplicationMessage(replay, event), isNull);

      await _expectPlaceholder(alice, replay, event);
      expect((await alice.history()).map((row) => row.body), contains('once'));
    }, skip: skip);

    test('a call signal that can never be decrypted is passed and dropped',
        () async {
      final bindings = NativeCryptoBindings.open(libraryPath!);
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      await _startConversation(alice, bob);
      final signal = await bob.service.encryptCallSignal(
          'conv_1', <String, Object?>{'type': 'offer', 'sdp': 'v=0'});
      final damaged = base64Decode(signal.metadata['ciphertext'] as String);
      damaged[damaged.length - 1] ^= 0xff;
      final counter = (await alice.store.loadCryptoState())!.counter;

      final event = alice.nextEvent();
      final result = await alice.service.processCallSignal(
          _call(signal.metadata, ciphertext: damaged), event);

      expect(result, isNull);
      expect(await alice.store.loadSyncCursor(), event);
      expect((await alice.store.loadCryptoState())!.counter, counter + 1);
      expect(await alice.history(), isEmpty);
      // A later signal still decrypts.
      final later = await bob.service.encryptCallSignal(
          'conv_1', <String, Object?>{'type': 'answer', 'sdp': 'v=0'});
      expect(
          await alice.service
              .processCallSignal(_call(later.metadata), alice.nextEvent()),
          <String, Object?>{'type': 'answer', 'sdp': 'v=0'});
    }, skip: skip);

    test('a storage failure while passing an event rolls back and retries',
        () async {
      final bindings = NativeCryptoBindings.open(libraryPath!);
      final store = _FailingStore();
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice',
          store: store);
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      await _startConversation(alice, bob);
      final sent =
          await bob.send(AppPayloadType.text, <String, Object?>{'text': 'one'});
      final damaged = List<int>.of(sent.ciphertext);
      damaged[damaged.length - 1] ^= 0xff;
      final envelope = alice.envelopeFrom(bob, sent, ciphertext: damaged);
      final event = alice.nextEvent();
      final cursor = await store.loadSyncCursor();
      final counter = (await store.loadCryptoState())!.counter;

      store.failNextTransition = true;
      await expectLater(
          alice.service.processApplicationMessage(envelope, event),
          throwsA(isA<FileSystemException>()));
      expect(await store.loadSyncCursor(), cursor);
      expect((await store.loadCryptoState())!.counter, counter);
      expect(await alice.history(), isEmpty);

      expect(await alice.service.processApplicationMessage(envelope, event),
          isNull);
      await _expectPlaceholder(alice, envelope, event);
    }, skip: skip);

    test('a duplicate Welcome still stops sync (I33)', () async {
      final bindings = NativeCryptoBindings.open(libraryPath!);
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      await alice.service.initializeConversation(
          'conv_1', <DeviceKeyPackage>[await bob.keyPackage()]);
      final item = (await alice.store.pendingMlsMessages()).single;
      final bundle = MlsCommitBundle.decode(item.payload);
      await alice.service.completeCommitBundle(item);
      await bob.service.processMlsMessage(_welcome(bob,
          from: alice, idempotencyKey: item.idempotencyKey, payload: bundle));
      final cursor = await bob.store.loadSyncCursor();
      final counter = (await bob.store.loadCryptoState())!.counter;

      await expectLater(
          bob.service.processMlsMessage(_welcome(bob,
              from: alice,
              idempotencyKey: item.idempotencyKey,
              payload: bundle)),
          throwsA(anything));

      await _expectUnmoved(bob, cursor, counter);
      final hello =
          await alice.send(AppPayloadType.text, <String, Object?>{'text': 'hi'});
      await bob.receive(alice, hello);
      expect((await bob.history()).single.body, 'hi');
    }, skip: skip);

    test('a commit the group rejects still stops sync (I33)', () async {
      final bindings = NativeCryptoBindings.open(libraryPath!);
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      final carol = await _Client.enroll(bindings, 'acct_carol', 'dev_carol');
      await _startConversation(alice, bob);
      await alice.service.stageMembershipChange('conv_1',
          adds: <DeviceKeyPackage>[await carol.keyPackage()]);
      final item = (await alice.store.pendingMlsMessages()).single;
      final bundle = MlsCommitBundle.decode(item.payload);
      await _accept(alice, <_Client>[carol], <_Client>[bob]);
      final cursor = await bob.store.loadSyncCursor();
      final counter = (await bob.store.loadCryptoState())!.counter;

      // The commit Bob already applied, as a new message: a past epoch.
      await expectLater(
          bob.service.processMlsMessage(
              _commit(bob, from: alice, item: item, payload: bundle.commit)),
          throwsA(anything));
      await _expectUnmoved(bob, cursor, counter);
      // Damaged bytes are refused the same way.
      await expectLater(
          bob.service.processMlsMessage(
              _commit(bob, from: alice, item: item, payload: <int>[1, 2, 3])),
          throwsA(anything));
      await _expectUnmoved(bob, cursor, counter);
      expect(await bob.service.groupEpoch('conv_1'), (epoch: 2, pending: false));
    }, skip: skip);
  });
}

/// The D54 outcome: the cursor is past the event, which is recorded as
/// processed, and history holds one placeholder row for the envelope with
/// no content at all.
Future<void> _expectPlaceholder(
    _Client client, ReceivedMessageEnvelope envelope, int event) async {
  expect(await client.store.loadSyncCursor(), event);
  expect(
      await client.store
          .hasProcessedMlsMessage('application:$event:${envelope.id}'),
      isTrue);
  final rows = (await client.history())
      .where((row) => row.serverMessageId == envelope.id)
      .toList();
  expect(rows, hasLength(1));
  expect(rows.single.key, 'undecryptable:$event:${envelope.id}');
  expect(rows.single.kind, LocalMessageKind.invalid);
  expect(rows.single.body, isNull);
  expect(rows.single.formatJson, isNull);
  expect(rows.single.senderAccountId, envelope.senderAccountId);
  // The envelope is kept so the timeline can show the placeholder.
  final cached = (await client.store.loadSnapshot())!
      .messagesByConversation['conv_1']!
      .where((item) => item.id == envelope.id);
  expect(cached, hasLength(1));
}

Future<void> _expectUnmoved(_Client client, int cursor, int counter) async {
  expect(await client.store.loadSyncCursor(), cursor);
  expect((await client.store.loadCryptoState())!.counter, counter);
}

CallSession _call(Map<String, Object?> metadata, {List<int>? ciphertext}) =>
    CallSession(
      id: 'call_${++_serverIds}',
      conversationId: 'conv_1',
      createdBy: 'acct_bob',
      invitedAccountId: 'acct_alice',
      state: 'ringing',
      version: 1,
      metadata: <String, Object?>{
        ...metadata,
        if (ciphertext != null) 'ciphertext': base64Encode(ciphertext),
      },
      createdAt: DateTime.now().toUtc(),
    );

class _FailingStore extends MemoryLocalStore {
  bool failNextTransition = false;

  @override
  Future<void> commitMlsTransition(MlsStateTransition transition) async {
    if (failNextTransition) {
      failNextTransition = false;
      throw const FileSystemException('write refused');
    }
    return super.commitMlsTransition(transition);
  }
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
