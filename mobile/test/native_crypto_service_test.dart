import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/errors.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// Two real OpenMLS devices exchanging every message payload type through
/// [NativeCryptoService], with the server's role played by the test.
void main() {
  final configured = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  // An empty value counts as missing, so it never reaches the loader.
  final libraryPath =
      configured == null || configured.isEmpty ? null : configured;
  if (libraryPath == null && Platform.environment['CI'] == 'true') {
    test('CI provides the native crypto library', () {
      fail('VERITRA_CRYPTO_LIBRARY is required when CI=true: set it to a '
          'built libprivate_messenger_crypto');
    });
  }
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
    // Both received in the same test tick, so compare without order.
    expect((await bob.history()).map((item) => item.body),
        unorderedEquals(<String?>['one', 'two']));
  }, skip: skip);

  test('sealed state in an unsupported format is a distinct error', () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final stored = (await alice.store.loadCryptoState())!;
    // Format 1 (OpenMLS 0.8.1): right magic, a version this build refuses.
    final oldFormat = List<int>.of(stored.sealedState)
      ..setRange(8, 10, const [0, 1]);
    // A fresh store, as after reinstalling over old app data.
    final store = MemoryLocalStore();
    await store.saveCryptoState(
        StoredCryptoState(
            counter: stored.counter,
            stateKey: stored.stateKey,
            sealedState: oldFormat),
        0);
    final restarted =
        NativeCryptoService(bindings: bindings, localStore: store);
    const session = Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: 'acct_alice',
      deviceId: 'dev_alice',
    );
    await expectLater(restarted.activateSession(session),
        throwsA(isA<CryptoStateFormatUnsupported>()));
    await expectLater(
        restarted.activateExistingSessionBounded(session,
            checkCanCommit: () {}),
        throwsA(isA<CryptoStateFormatUnsupported>()));
    expect(describeError(const CryptoStateFormatUnsupported()),
        englishL10n.errorCryptoStateFormatUnsupported);
    await restarted.dispose();
  }, skip: skip);

  test('a device added after creation joins and reads new messages', () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    final tablet = await _Client.enroll(bindings, 'acct_bob', 'dev_tablet');
    await _startConversation(alice, bob);

    await bob.service.stageMembershipChange('conv_1',
        adds: <DeviceKeyPackage>[await tablet.keyPackage()]);
    // Until the server accepts it, Bob's group stays on the old epoch.
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 1, pending: true));
    await _accept(bob, <_Client>[tablet], <_Client>[alice]);
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 2, pending: false));
    expect(
        await alice.service.groupEpoch('conv_1'), (epoch: 2, pending: false));

    final hello =
        await alice.send(AppPayloadType.text, <String, Object?>{'text': 'hi'});
    await bob.receive(alice, hello);
    await tablet.receive(alice, hello);
    expect((await tablet.history()).single.body, 'hi');

    // Removing the tablet again is one more bundle.
    await alice.service.stageMembershipChange('conv_1', removes: <MlsDeviceRef>[
      (accountId: 'acct_bob', deviceId: 'dev_tablet')
    ]);
    expect(await alice.service.groupEpoch('conv_1'), (epoch: 2, pending: true));
    await _accept(alice, const <_Client>[], <_Client>[bob, tablet]);
    expect(
        await alice.service.groupEpoch('conv_1'), (epoch: 3, pending: false));
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 3, pending: false));
    // The tablet applies its own removal, which drops its group (D70), and
    // can no longer send.
    expect(await tablet.service.groupEpoch('conv_1'), isNull);
    await expectLater(
        tablet.send(AppPayloadType.text, <String, Object?>{'text': 'still?'}),
        throwsA(isA<NativeCryptoException>()));

    final after =
        await alice.send(AppPayloadType.text, <String, Object?>{'text': 'bye'});
    await bob.receive(alice, after);
    expect((await bob.history()).last.body, 'bye');
    // Nor can it read what the group sends after the removal: sync moves
    // past it and history holds a placeholder with no content (D54).
    await tablet.receive(alice, after);
    final event = await tablet.store.loadSyncCursor();
    final history = await tablet.history();
    expect(history.map((message) => message.body), <String?>['hi', null]);
    final placeholder = history.last;
    expect(
        placeholder.key, 'undecryptable:$event:${placeholder.serverMessageId}');
    expect(placeholder.kind, LocalMessageKind.invalid);
    expect(placeholder.formatJson, isNull);
  }, skip: skip);

  test('a refused commit is dropped and the winner applies cleanly', () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    final carol = await _Client.enroll(bindings, 'acct_carol', 'dev_carol');
    await _startConversation(alice, bob);

    await alice.service.stageMembershipChange('conv_1',
        adds: <DeviceKeyPackage>[await carol.keyPackage()]);
    await bob.service.stageMembershipChange('conv_1',
        adds: <DeviceKeyPackage>[await carol.keyPackage()]);
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 1, pending: true));

    // Bob's commit lost. The winning commit arrives before his refusal:
    // his staged commit is dropped and the winner applied.
    await _accept(alice, <_Client>[carol], <_Client>[bob]);
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 2, pending: false));
    final bobsBundle = (await bob.store.pendingMlsMessages()).single;
    await bob.service.abandonCommitBundle(bobsBundle);
    expect(await bob.store.pendingMlsMessages(), isEmpty);
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 2, pending: false));
    expect(
        await alice.service.groupEpoch('conv_1'), (epoch: 2, pending: false));
    expect(
        await carol.service.groupEpoch('conv_1'), (epoch: 2, pending: false));

    final after = await alice
        .send(AppPayloadType.text, <String, Object?>{'text': 'converged'});
    await bob.receive(alice, after);
    expect((await bob.history()).last.body, 'converged');
  }, skip: skip);

  test('a commit refused before the winner arrives still applies the winner',
      () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    final carol = await _Client.enroll(bindings, 'acct_carol', 'dev_carol');
    await _startConversation(alice, bob);

    await alice.service.stageMembershipChange('conv_1',
        adds: <DeviceKeyPackage>[await carol.keyPackage()]);
    await bob.service.stageMembershipChange('conv_1',
        adds: <DeviceKeyPackage>[await carol.keyPackage()]);
    final winner = await _accept(alice, <_Client>[carol], const <_Client>[]);

    // Bob's refusal comes first: his staged commit is dropped, and the
    // winning commit that arrives later applies to the old epoch.
    final bobsBundle = (await bob.store.pendingMlsMessages()).single;
    await bob.service.abandonCommitBundle(bobsBundle);
    expect(await bob.store.pendingMlsMessages(), isEmpty);
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 1, pending: false));
    await _deliverCommit(alice, bob, winner);
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 2, pending: false));

    final after = await alice
        .send(AppPayloadType.text, <String, Object?>{'text': 'converged'});
    await bob.receive(alice, after);
    expect((await bob.history()).last.body, 'converged');
  }, skip: skip);

  test('an own commit echo merges the staged commit once', () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    final carol = await _Client.enroll(bindings, 'acct_carol', 'dev_carol');
    await _startConversation(alice, bob);
    await alice.service.stageMembershipChange('conv_1',
        adds: <DeviceKeyPackage>[await carol.keyPackage()]);
    final item = (await alice.store.pendingMlsMessages()).single;
    final bundle = MlsCommitBundle.decode(item.payload);

    // The sync stream delivers Alice's accepted commit before her outbox
    // worker saw the server's answer.
    final echo = MlsMessage(
      id: 'mls_echo',
      conversationId: 'conv_1',
      senderAccountId: 'acct_alice',
      senderDeviceId: 'dev_alice',
      kind: 'commit',
      payload: bundle.commit,
      idempotencyKey: item.idempotencyKey,
      syncEventId: alice.nextEvent(),
      createdAt: DateTime.now().toUtc(),
    );
    final before = (await alice.service.groupEpoch('conv_1'))!;
    await alice.service.processMlsMessage(echo);
    expect(await alice.store.pendingMlsMessages(), isEmpty);
    final merged = (epoch: before.epoch + 1, pending: false);
    expect(await alice.service.groupEpoch('conv_1'), merged);

    // Her outbox worker then sees the server's answer for the same bundle,
    // and the stream redelivers the echo: neither merges a second time.
    await alice.service.completeCommitBundle(item);
    expect(await alice.service.groupEpoch('conv_1'), merged);
    await alice.service.processMlsMessage(echo);
    expect(await alice.service.groupEpoch('conv_1'), merged);
    // The same commit in a later sync event finds no bundle left to merge.
    await alice.service.processMlsMessage(MlsMessage(
      id: 'mls_echo_again',
      conversationId: 'conv_1',
      senderAccountId: 'acct_alice',
      senderDeviceId: 'dev_alice',
      kind: 'commit',
      payload: bundle.commit,
      idempotencyKey: item.idempotencyKey,
      syncEventId: alice.nextEvent(),
      createdAt: DateTime.now().toUtc(),
    ));
    expect(await alice.service.groupEpoch('conv_1'), merged);
    expect(await alice.store.pendingMlsMessages(), isEmpty);
  }, skip: skip);

  test('a self-update lands only once accepted, and every member follows',
      () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    final carol = await _Client.enroll(bindings, 'acct_carol', 'dev_carol');
    await _startConversation(alice, bob);
    await alice.service.stageMembershipChange('conv_1',
        adds: <DeviceKeyPackage>[await carol.keyPackage()]);
    await _accept(alice, <_Client>[carol], <_Client>[bob]);
    final safety = await alice.service.conversationSafetyNumber('conv_1');

    await bob.service.stageSelfUpdate('conv_1');
    // Staged, not merged, until the server accepts it (D28).
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 2, pending: true));
    final bundle = MlsCommitBundle.decode(
        (await bob.store.pendingMlsMessages()).single.payload);
    expect(bundle.isUpdateOnly, isTrue);
    expect(bundle.epoch, 2);
    await _accept(bob, const <_Client>[], <_Client>[alice, carol]);
    for (final member in <_Client>[alice, bob, carol]) {
      expect(await member.service.groupEpoch('conv_1'),
          (epoch: 3, pending: false));
    }
    // Same members and signing keys, so the safety number holds.
    expect((await alice.service.conversationSafetyNumber('conv_1')).digits,
        safety.digits);

    final hello = await alice
        .send(AppPayloadType.text, <String, Object?>{'text': 'after'});
    await bob.receive(alice, hello);
    await carol.receive(alice, hello);
    expect((await bob.history()).last.body, 'after');
    final reply =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'ok'});
    await carol.receive(bob, reply);
    expect((await carol.history()).last.body, 'ok');
  }, skip: skip);

  test('a self-update that loses the epoch is dropped without a fork',
      () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);

    await bob.service.stageSelfUpdate('conv_1');
    final bobs = (await bob.store.pendingMlsMessages()).single;
    await alice.service.stageSelfUpdate('conv_1');
    await _accept(alice, const <_Client>[], <_Client>[bob]);
    // The server refused Bob's commit (409): it is dropped, and the
    // winner already applied.
    await bob.service.abandonCommitBundle(bobs);
    expect(await bob.store.pendingMlsMessages(), isEmpty);
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 2, pending: false));
    final next =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'next'});
    await alice.receive(bob, next);
    expect((await alice.history()).last.body, 'next');
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
    // Both messages can share a timestamp, so do not rely on list order.
    final after = await alice.history();
    expect(after, hasLength(2));
    expect(after.where((m) => m.kind == LocalMessageKind.unverifiable),
        hasLength(1));
    expect(after.map((m) => m.body), contains('next'));
  }, skip: skip);
}

Future<void> _startConversation(_Client alice, _Client bob) async {
  await alice.service.initializeConversation(
      'conv_1', <DeviceKeyPackage>[await bob.keyPackage()]);
  await _accept(alice, <_Client>[bob], const <_Client>[]);
}

/// Plays the server accepting [from]'s queued commit bundle: [from] merges
/// it, [joiners] get the Welcome and [members] the commit. Returns the
/// accepted outbox item, so a test can deliver its commit later.
Future<PendingMlsMessage> _accept(
    _Client from, List<_Client> joiners, List<_Client> members) async {
  final item = (await from.store.pendingMlsMessages()).single;
  expect(item.kind, MlsCommitBundle.kind);
  final bundle = MlsCommitBundle.decode(item.payload);
  await from.service.completeCommitBundle(item);
  expect(await from.store.pendingMlsMessages(), isEmpty);
  for (final member in members) {
    await _deliverCommit(from, member, item);
  }
  for (final joiner in joiners) {
    await joiner.service.processMlsMessage(MlsMessage(
      id: 'mls_${++_serverIds}',
      conversationId: 'conv_1',
      senderAccountId: from.accountId,
      senderDeviceId: from.deviceId,
      kind: 'welcome',
      payload: bundle.welcome,
      idempotencyKey: '${item.idempotencyKey}:welcome:${joiner.deviceId}',
      syncEventId: joiner.nextEvent(),
      createdAt: DateTime.now().toUtc(),
      recipientDeviceId: joiner.deviceId,
    ));
  }
  return item;
}

/// Plays the sync stream delivering the commit of [from]'s accepted [item]
/// to [member].
Future<void> _deliverCommit(
    _Client from, _Client member, PendingMlsMessage item) async {
  await member.service.processMlsMessage(MlsMessage(
    id: 'mls_${++_serverIds}',
    conversationId: 'conv_1',
    senderAccountId: from.accountId,
    senderDeviceId: from.deviceId,
    kind: 'commit',
    payload: MlsCommitBundle.decode(item.payload).commit,
    idempotencyKey: item.idempotencyKey,
    syncEventId: member.nextEvent(),
    createdAt: DateTime.now().toUtc(),
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
