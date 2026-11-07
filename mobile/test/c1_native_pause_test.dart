import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/conversation_pause.dart';
import 'package:private_messenger/sync/sync_recovery.dart';

import 'native_test_env.dart';

/// C1 prerequisite 1 against real OpenMLS devices: one group is poisoned
/// and paused, the other keeps receiving, sending and sealing, and a replay
/// of the paused group applies its held events in order without moving the
/// global cursor or touching the other group's state.
void main() {
  final skip = nativeCryptoSkip();

  test('poison A, keep B, restart, then replay A in order', () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    var alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _start(alice, bob, 'conv_a');
    await _start(alice, bob, 'conv_b');

    // Bob sends two messages in A around one in B.
    final a1 = await bob.send('conv_a', 'a one');
    final b1 = await bob.send('conv_b', 'b one');
    final a2 = await bob.send('conv_a', 'a two');
    final eventA1 = alice.nextEvent();
    final eventB1 = alice.nextEvent();
    final eventA2 = alice.nextEvent();

    // A's first event cannot be applied: A is paused, and the cursor moves
    // past it and past A's later event by the cursor alone.
    await alice.store.pauseConversation(
        conversationId: 'conv_a',
        failedEventId: eventA1,
        kind: SyncFailureKind.mlsState);
    await alice.store.skipPausedConversationEvent(
        conversationId: 'conv_a', eventId: eventA1, expectedCursor: 0);

    // B goes on: receive, then send and seal.
    await alice.service
        .processApplicationMessage(alice.envelopeFrom(bob, b1), eventB1);
    await alice.store.skipPausedConversationEvent(
        conversationId: 'conv_a', eventId: eventA2, expectedCursor: eventB1);
    expect(await alice.store.loadSyncCursor(), eventA2);
    expect((await alice.store.loadMessages('conv_b')).single.body, 'b one');
    expect(await alice.store.loadMessages('conv_a'), isEmpty);
    await alice.service
        .encryptPayload('conv_b', AppPayloadType.text, {'text': 'b reply'});

    // A refuses every outgoing MLS operation while paused.
    await expectLater(
        alice.service
            .encryptPayload('conv_a', AppPayloadType.text, {'text': 'no'}),
        throwsA(isA<ConversationSyncPausedException>()));
    await expectLater(alice.service.stageSelfUpdate('conv_a'),
        throwsA(isA<ConversationSyncPausedException>()));
    // ...and a cursor-advancing event for it.
    await expectLater(
        alice.service.processApplicationMessage(
            alice.envelopeFrom(bob, a1), eventA2 + 1),
        throwsA(isA<ConversationSyncPausedException>()));

    // A restart keeps the pause and both groups.
    final counter = (await alice.store.loadCryptoState())!.counter;
    alice = await alice.restart(bindings);
    expect(await alice.store.loadConversationPause('conv_a'), isNotNull);
    expect((await alice.store.loadCryptoState())!.counter, counter);

    // The replay applies A's events in order, behind the cursor.
    await alice.service
        .processApplicationMessage(alice.envelopeFrom(bob, a1), eventA1);
    expect(await alice.store.loadSyncCursor(), eventA2);
    expect((await alice.store.loadConversationPause('conv_a'))!.resumeAfter,
        eventA1);
    await alice.service
        .processApplicationMessage(alice.envelopeFrom(bob, a2), eventA2);
    expect(await alice.store.loadSyncCursor(), eventA2);
    final held = await alice.store.loadMessages('conv_a');
    expect(
        held.map((row) => row.body), containsAll(<String?>['a one', 'a two']));

    // B kept its history, and both groups work after the pause is lifted.
    expect((await alice.store.loadMessages('conv_b')).first.body, isNotNull);
    expect(await alice.store.clearConversationPause('conv_a'), isTrue);
    await alice.service
        .encryptPayload('conv_a', AppPayloadType.text, {'text': 'a back'});
    final b2 = await bob.send('conv_b', 'b two');
    await alice.service.processApplicationMessage(
        alice.envelopeFrom(bob, b2), alice.nextEvent());
    expect((await alice.store.loadMessages('conv_b')).map((row) => row.body),
        containsAll(<String?>['b one', 'b two']));
  }, skip: skip);

  test('a real failed commit pauses A, then the replay merges it in order',
      () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _start(alice, bob, 'conv_a');
    await _start(alice, bob, 'conv_b');
    final epochA = await alice.epoch('conv_a');
    final epochB = await alice.epoch('conv_b');

    // Bob moves A to a new epoch with a self-update and speaks in it. He does
    // the same in B, which Alice applies while A is paused.
    final updateA = await bob.selfUpdate('conv_a');
    final newA = await bob.send('conv_a', 'a new epoch');
    final updateB = await bob.selfUpdate('conv_b');
    final newB = await bob.send('conv_b', 'b new epoch');
    final eventA1 = alice.nextEvent();
    final eventA2 = alice.nextEvent();
    final eventB1 = alice.nextEvent();
    final eventB2 = alice.nextEvent();

    // A's commit arrives damaged: a real failure inside OpenMLS, which must
    // leave the group, the counter and the cursor where they were.
    final good = MlsCommitBundle.decode(updateA.payload).commit;
    final goodB = MlsCommitBundle.decode(updateB.payload).commit;
    final damaged = List<int>.of(good)..[good.length - 1] ^= 0xff;
    final counter = (await alice.store.loadCryptoState())!.counter;
    await expectLater(
        alice.service.processMlsMessage(
            alice.commitFrom(bob, updateA, eventA1, damaged)),
        throwsA(isA<NativeCryptoException>()));
    expect(await alice.service.deviceHandleUsable(), isTrue);
    expect(await alice.epoch('conv_a'), epochA);
    expect((await alice.store.loadCryptoState())!.counter, counter);
    expect(await alice.store.loadSyncCursor(), 0);

    // The failure pauses A. The cursor passes A's two held events alone.
    await alice.store.pauseConversation(
        conversationId: 'conv_a',
        failedEventId: eventA1,
        kind: SyncFailureKind.mlsState,
        failedEventType: 'mls.message.created');
    await alice.store.skipPausedConversationEvent(
        conversationId: 'conv_a', eventId: eventA1, expectedCursor: 0);
    await alice.store.skipPausedConversationEvent(
        conversationId: 'conv_a', eventId: eventA2, expectedCursor: eventA1);

    // B goes on into its new epoch while A is paused.
    await alice.service
        .processMlsMessage(alice.commitFrom(bob, updateB, eventB1, goodB));
    await alice.service
        .processApplicationMessage(alice.envelopeFrom(bob, newB), eventB2);
    expect(await alice.epoch('conv_b'), epochB + 1);
    expect(await alice.epoch('conv_a'), epochA);
    expect((await alice.store.loadMessages('conv_b')).single.body,
        'b new epoch');
    expect(await alice.store.loadSyncCursor(), eventB2);
    final before = (await alice.store.loadCryptoState())!.counter;

    // The replay merges A's commit, then decrypts the new-epoch message,
    // both behind the cursor. Each is one transition.
    await alice.service
        .processMlsMessage(alice.commitFrom(bob, updateA, eventA1, good));
    expect(await alice.epoch('conv_a'), epochA + 1);
    expect((await alice.store.loadCryptoState())!.counter, before + 1);
    expect((await alice.store.loadConversationPause('conv_a'))!.resumeAfter,
        eventA1);
    expect(await alice.store.loadSyncCursor(), eventB2);
    expect(await alice.epoch('conv_b'), epochB + 1);

    await alice.service
        .processApplicationMessage(alice.envelopeFrom(bob, newA), eventA2);
    expect((await alice.store.loadCryptoState())!.counter, before + 2);
    expect((await alice.store.loadConversationPause('conv_a'))!.resumeAfter,
        eventA2);
    expect(await alice.store.loadSyncCursor(), eventB2);
    expect(await alice.epoch('conv_b'), epochB + 1);
    expect((await alice.store.loadMessages('conv_a')).single.body,
        'a new epoch');
    expect((await alice.store.loadMessages('conv_b')).single.body,
        'b new epoch');

    // With the pause lifted, A works in its new epoch both ways.
    expect(await alice.store.clearConversationPause('conv_a'), isTrue);
    await alice.service
        .encryptPayload('conv_a', AppPayloadType.text, {'text': 'a reply'});
    final later = await bob.send('conv_a', 'a later');
    await alice.service.processApplicationMessage(
        alice.envelopeFrom(bob, later), alice.nextEvent());
    expect((await alice.store.loadMessages('conv_a')).map((row) => row.body),
        containsAll(<String?>['a new epoch', 'a later']));
  }, skip: skip);
}

int _serverIds = 0;

Session _session(String accountId, String deviceId) => Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    );

Future<void> _start(_Client alice, _Client bob, String conversationId) async {
  await alice.service.initializeConversation(
      conversationId, <DeviceKeyPackage>[await bob.keyPackage()]);
  final item = (await alice.store.pendingMlsMessages()).single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await alice.service.completeCommitBundle(item);
  await bob.service.processMlsMessage(MlsMessage(
    id: 'mls_${++_serverIds}',
    conversationId: conversationId,
    senderAccountId: alice.accountId,
    senderDeviceId: alice.deviceId,
    kind: 'welcome',
    payload: bundle.welcome,
    idempotencyKey: '${item.idempotencyKey}:welcome:${bob.deviceId}',
    syncEventId: bob.nextEvent(),
    createdAt: DateTime.now().toUtc(),
    recipientDeviceId: bob.deviceId,
  ));
}

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId, this.events);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  int events;

  static Future<_Client> enroll(
      NativeCryptoBindings bindings, String accountId, String deviceId) async {
    final local = MemoryLocalStore();
    final service = NativeCryptoService(bindings: bindings, localStore: local);
    await service.createEnrollmentCredential(EnrollmentReservation(
      id: 'res_$deviceId',
      accountId: accountId,
      deviceId: deviceId,
      challenge: const <int>[1, 2, 3],
    ));
    await service.activateSession(_session(accountId, deviceId));
    return _Client(service, local, accountId, deviceId, 0);
  }

  /// A new service over the same store, as after an app restart.
  Future<_Client> restart(NativeCryptoBindings bindings) async {
    await service.dispose();
    final next = NativeCryptoService(bindings: bindings, localStore: store);
    await next.activateSession(_session(accountId, deviceId));
    return _Client(next, store, accountId, deviceId, events);
  }

  int nextEvent() => ++events;

  Future<int> epoch(String conversationId) async =>
      (await service.groupEpoch(conversationId))!.epoch;

  /// Stages a self-update commit and merges it, as after the server accepts
  /// it. Returns the accepted outbox item, so its commit can be delivered.
  Future<PendingMlsMessage> selfUpdate(String conversationId) async {
    await service.stageSelfUpdate(conversationId);
    final item = (await store.pendingMlsMessages())
        .singleWhere((pending) => pending.conversationId == conversationId);
    await service.completeCommitBundle(item);
    return item;
  }

  /// The sync event that delivers [payload], a copy of [item]'s commit, from
  /// [from] to this device.
  MlsMessage commitFrom(_Client from, PendingMlsMessage item, int eventId,
      List<int> payload) {
    return MlsMessage(
      id: 'mls_${item.conversationId}',
      conversationId: item.conversationId,
      senderAccountId: from.accountId,
      senderDeviceId: from.deviceId,
      kind: 'commit',
      payload: payload,
      idempotencyKey: item.idempotencyKey,
      syncEventId: eventId,
      createdAt: DateTime.now().toUtc(),
    );
  }

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$deviceId${++_serverIds}',
        deviceId: deviceId,
        accountId: accountId,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  Future<MessageEnvelope> send(String conversationId, String text) async {
    final envelope = await service.encryptPayload(
        conversationId, AppPayloadType.text, <String, Object?>{'text': text});
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  ReceivedMessageEnvelope envelopeFrom(_Client from, MessageEnvelope sent) =>
      ReceivedMessageEnvelope(
        id: 'srv_${++_serverIds}',
        conversationId: sent.conversationId,
        senderAccountId: from.accountId,
        senderDeviceId: from.deviceId,
        idempotencyKey: sent.idempotencyKey,
        ciphertext: sent.ciphertext,
        cryptoProtocol: sent.cryptoProtocol,
        createdAt: DateTime.now().toUtc(),
      );
}
