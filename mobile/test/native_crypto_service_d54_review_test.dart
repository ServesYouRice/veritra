import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';

/// Real OpenMLS devices driven through [NativeCryptoService], for the review
/// of D54: which native errors count as "can never decrypt", and what stays
/// fail-closed.
void main() {
  // Skipped without the library, unless VERITRA_REQUIRE_NATIVE_CRYPTO=1.
  final skip = nativeCryptoSkip();

  group('a decrypt error is retried once on a fresh handle (D54)', () {
    for (final kind in <NativeCryptoError>[
      NativeCryptoError.operationFailed,
      NativeCryptoError.nativePanic,
      NativeCryptoError.invalidOutput,
    ]) {
      test('one ${kind.name} still decrypts the message', () async {
        final faults = _FaultyBindings(
            NativeCryptoBindings.open(requireNativeCryptoLibrary()));
        final alice = await _Client.enroll(faults, 'acct_alice', 'dev_alice');
        final bob = await _Client.enroll(faults, 'acct_bob', 'dev_bob');
        await _startConversation(alice, bob);
        final sent = await bob
            .send(AppPayloadType.text, <String, Object?>{'text': 'kept'});

        faults.decryptFaults.add(kind);
        final event = alice.nextEvent();
        await alice.service
            .processApplicationMessage(alice.envelopeFrom(bob, sent), event);

        expect(faults.decryptFaults, isEmpty);
        expect(await alice.store.loadSyncCursor(), event);
        final history = await alice.history();
        expect(history.map((row) => row.body), <String?>['kept']);
        expect(history.single.kind, isNot(LocalMessageKind.invalid));
        // The handle the fault left behind was replaced: the group works.
        final next = await bob
            .send(AppPayloadType.text, <String, Object?>{'text': 'on'});
        await alice.receive(bob, next);
        expect((await alice.history()).last.body, 'on');
      }, skip: skip);
    }

    test('a second failure of the same kind gives the placeholder', () async {
      final faults = _FaultyBindings(
          NativeCryptoBindings.open(requireNativeCryptoLibrary()));
      final alice = await _Client.enroll(faults, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(faults, 'acct_bob', 'dev_bob');
      await _startConversation(alice, bob);
      final sent =
          await bob.send(AppPayloadType.text, <String, Object?>{'text': 'x'});

      faults.decryptFaults.addAll(
          [NativeCryptoError.invalidOutput, NativeCryptoError.nativePanic]);
      final envelope = alice.envelopeFrom(bob, sent);
      final event = alice.nextEvent();
      expect(await alice.service.processApplicationMessage(envelope, event),
          isNull);

      expect(await alice.store.loadSyncCursor(), event);
      final row = (await alice.history()).single;
      expect(row.key, 'undecryptable:$event:${envelope.id}');
      expect(row.kind, LocalMessageKind.invalid);
      expect(row.body, isNull);
      final next =
          await bob.send(AppPayloadType.text, <String, Object?>{'text': 'on'});
      await alice.receive(bob, next);
      expect((await alice.history()).last.body, 'on');
    }, skip: skip);

    for (final kind in <NativeCryptoError>[
      NativeCryptoError.invalidArgument,
      NativeCryptoError.unknown,
    ]) {
      test('${kind.name} stops sync with nothing consumed (I33)', () async {
        final faults = _FaultyBindings(
            NativeCryptoBindings.open(requireNativeCryptoLibrary()));
        final alice = await _Client.enroll(faults, 'acct_alice', 'dev_alice');
        final bob = await _Client.enroll(faults, 'acct_bob', 'dev_bob');
        await _startConversation(alice, bob);
        final sent = await bob
            .send(AppPayloadType.text, <String, Object?>{'text': 'later'});
        final cursor = await alice.store.loadSyncCursor();
        final counter = (await alice.store.loadCryptoState())!.counter;

        faults.decryptFaults.add(kind);
        final envelope = alice.envelopeFrom(bob, sent);
        final event = alice.nextEvent();
        await expectLater(
            alice.service.processApplicationMessage(envelope, event),
            throwsA(isA<NativeCryptoException>()
                .having((error) => error.kind, 'kind', kind)));
        expect(await alice.store.loadSyncCursor(), cursor);
        expect((await alice.store.loadCryptoState())!.counter, counter);
        expect(await alice.history(), isEmpty);

        // Sync retries the same event and reads it.
        await alice.service.processApplicationMessage(envelope, event);
        expect((await alice.history()).single.body, 'later');
      }, skip: skip);
    }

    test('a call signal survives one operationFailed', () async {
      final faults = _FaultyBindings(
          NativeCryptoBindings.open(requireNativeCryptoLibrary()));
      final alice = await _Client.enroll(faults, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(faults, 'acct_bob', 'dev_bob');
      await _startConversation(alice, bob);
      final signal = await bob.service.encryptCallSignal(
          'conv_1', <String, Object?>{'type': 'offer', 'sdp': 'v=0'});

      faults.decryptFaults.add(NativeCryptoError.operationFailed);
      final event = alice.nextEvent();
      expect(
          await alice.service.processCallSignal(_call(signal.metadata), event),
          <String, Object?>{'type': 'offer', 'sdp': 'v=0'});
      expect(await alice.store.loadSyncCursor(), event);
    }, skip: skip);

    test('a call signal with invalidArgument stops sync (I33)', () async {
      final faults = _FaultyBindings(
          NativeCryptoBindings.open(requireNativeCryptoLibrary()));
      final alice = await _Client.enroll(faults, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(faults, 'acct_bob', 'dev_bob');
      await _startConversation(alice, bob);
      final signal = await bob.service.encryptCallSignal(
          'conv_1', <String, Object?>{'type': 'offer', 'sdp': 'v=0'});
      final cursor = await alice.store.loadSyncCursor();

      faults.decryptFaults.add(NativeCryptoError.invalidArgument);
      final event = alice.nextEvent();
      await expectLater(
          alice.service.processCallSignal(_call(signal.metadata), event),
          throwsA(isA<NativeCryptoException>()));
      expect(await alice.store.loadSyncCursor(), cursor);
      expect(
          await alice.service.processCallSignal(_call(signal.metadata), event),
          <String, Object?>{'type': 'offer', 'sdp': 'v=0'});
    }, skip: skip);
  });

  group('groupEpoch', () {
    test('a poisoned handle is replaced, not read as "no group"', () async {
      final faults = _FaultyBindings(
          NativeCryptoBindings.open(requireNativeCryptoLibrary()));
      final alice = await _Client.enroll(faults, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(faults, 'acct_bob', 'dev_bob');
      await _startConversation(alice, bob);

      faults.epochFaults.add(NativeCryptoError.nativePanic);
      expect(
          await alice.service.groupEpoch('conv_1'), (epoch: 1, pending: false));
      expect(faults.epochFaults, isEmpty);
      // The next operation runs on the fresh handle.
      final sent = await alice
          .send(AppPayloadType.text, <String, Object?>{'text': 'ok'});
      await bob.receive(alice, sent);
      expect((await bob.history()).single.body, 'ok');
    }, skip: skip);

    test('a group this device does not hold is still null', () async {
      final faults = _FaultyBindings(
          NativeCryptoBindings.open(requireNativeCryptoLibrary()));
      final alice = await _Client.enroll(faults, 'acct_alice', 'dev_alice');
      final restores = faults.restores;
      expect(await alice.service.groupEpoch('conv_none'), isNull);
      // A healthy handle answers the probe: no state restore for a plain miss.
      expect(faults.restores, restores);
    }, skip: skip);

    test('a missing group restores when the stored state moved', () async {
      final faults = _FaultyBindings(
          NativeCryptoBindings.open(requireNativeCryptoLibrary()));
      final alice = await _Client.enroll(faults, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(faults, 'acct_bob', 'dev_bob');
      // A second service on Alice's store holds a handle from before conv_1,
      // so the store moves on without it: the state a backup restore leaves.
      final stale =
          NativeCryptoService(bindings: faults, localStore: alice.store);
      await stale.activateSession(Session(
        baseUrl: 'https://localhost:8443',
        token: 'token',
        accountId: alice.accountId,
        deviceId: alice.deviceId,
      ));
      await _startConversation(alice, bob);

      final restores = faults.restores;
      expect(await stale.groupEpoch('conv_1'), (epoch: 1, pending: false));
      expect(faults.restores, restores + 1);
    }, skip: skip);
  });

  group('mlsMessageEpoch reads the group ID as the bindings send it', () {
    // The bindings pass `Uint8List.fromList(groupId.codeUnits)` to the native
    // side: one byte per UTF-16 unit, its low byte.
    List<int> header(List<int> groupId, int epoch) => <int>[
          0, 1, 0, 1, groupId.length, ...groupId, //
          0, 0, 0, 0, 0, 0, 0, epoch,
        ];

    for (final groupId in <String>['conv_1', 'é', '€x']) {
      test(groupId, () {
        final wire = Uint8List.fromList(groupId.codeUnits);
        expect(mlsMessageEpoch(header(wire, 7), groupId), 7);
        if (groupId.codeUnits.any((unit) => unit > 0x7f)) {
          expect(mlsMessageEpoch(header(utf8.encode(groupId), 7), groupId),
              isNull);
        }
      });
    }
  });

  group('an own commit with no queued bundle (fork check)', () {
    test('the clear header gives the epoch the commit was built on', () async {
      final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      final carol = await _Client.enroll(bindings, 'acct_carol', 'dev_carol');
      await _startConversation(alice, bob);

      await alice.service.stageMembershipChange('conv_1',
          adds: <DeviceKeyPackage>[await carol.keyPackage()]);
      final add = MlsCommitBundle.decode(
          (await alice.store.pendingMlsMessages()).single.payload);
      expect(mlsMessageEpoch(add.commit, 'conv_1'), add.epoch);
      expect(add.epoch, 1);
      expect(mlsMessageEpoch(add.commit, 'conv_2'), isNull);
      expect(mlsMessageEpoch(add.commit.sublist(0, 12), 'conv_1'), isNull);
      expect(mlsMessageEpoch(<int>[1, 2, 3], 'conv_1'), isNull);
      await _accept(alice, <_Client>[carol], <_Client>[bob]);

      await bob.service.stageSelfUpdate('conv_1');
      final update = MlsCommitBundle.decode(
          (await bob.store.pendingMlsMessages()).single.payload);
      expect(mlsMessageEpoch(update.commit, 'conv_1'), update.epoch);
      expect(update.epoch, 2);
    }, skip: skip);

    test('a bundle the worker already settled passes', () async {
      final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      await _startConversation(alice, bob);
      await alice.service.stageSelfUpdate('conv_1');
      final item = (await alice.store.pendingMlsMessages()).single;
      final bundle = MlsCommitBundle.decode(item.payload);
      // Accepted, then settled by the worker before sync sees the commit.
      await alice.service.completeCommitBundle(item);
      expect(await alice.store.pendingMlsMessages(), isEmpty);

      final echo =
          _commit(alice, from: alice, item: item, payload: bundle.commit);
      await alice.service.processMlsMessage(echo);
      expect(await alice.store.loadSyncCursor(), echo.syncEventId);
      expect(
          await alice.service.groupEpoch('conv_1'), (epoch: 2, pending: false));
    }, skip: skip);

    test('a commit this device never merged stops sync', () async {
      final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      await _startConversation(alice, bob);
      await alice.service.stageSelfUpdate('conv_1');
      final item = (await alice.store.pendingMlsMessages()).single;
      final bundle = MlsCommitBundle.decode(item.payload);
      // Dropped here, yet the server holds it under this device's identity
      // (the state a clone-restored twin's commit leaves behind).
      await alice.service.abandonCommitBundle(item);
      final cursor = await alice.store.loadSyncCursor();
      final counter = (await alice.store.loadCryptoState())!.counter;

      await expectLater(
          alice.service.processMlsMessage(
              _commit(alice, from: alice, item: item, payload: bundle.commit)),
          throwsA(isA<StateError>().having((error) => error.message, 'message',
              'own MLS commit was never merged here')));
      expect(await alice.store.loadSyncCursor(), cursor);
      expect((await alice.store.loadCryptoState())!.counter, counter);
      // Bytes that are not a commit of this group are refused too.
      await expectLater(
          alice.service.processMlsMessage(
              _commit(alice, from: alice, item: item, payload: <int>[1, 2, 3])),
          throwsA(isA<StateError>()));
      expect(await alice.store.loadSyncCursor(), cursor);
    }, skip: skip);
  });

  test('abandoning a bundle that lost its epoch keeps a newer staged commit',
      () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    final carol = await _Client.enroll(bindings, 'acct_carol', 'dev_carol');
    await _startConversation(alice, bob);
    await alice.service.stageMembershipChange('conv_1',
        adds: <DeviceKeyPackage>[await carol.keyPackage()]);
    await bob.service.stageSelfUpdate('conv_1');
    final lost = (await bob.store.pendingMlsMessages()).single;

    // Alice's commit wins epoch 1; sync drops Bob's staged commit but the
    // entry stays queued until the server refuses it.
    await _accept(alice, <_Client>[carol], <_Client>[bob]);
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 2, pending: false));
    // A newer commit is staged on epoch 2 before the refusal arrives.
    await bob.service.stageSelfUpdate('conv_1');
    final newer = (await bob.store.pendingMlsMessages())
        .singleWhere((item) => item.idempotencyKey != lost.idempotencyKey);

    await bob.service.abandonCommitBundle(lost);

    expect(await bob.service.groupEpoch('conv_1'), (epoch: 2, pending: true));
    expect((await bob.store.pendingMlsMessages()).single.idempotencyKey,
        newer.idempotencyKey);
    await bob.service.completeCommitBundle(newer);
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 3, pending: false));
  }, skip: skip);
}

/// Wraps the real bindings so a test can make the next native `decrypt` or
/// `groupEpoch` calls fail with a chosen kind. A [NativeCryptoError.nativePanic]
/// poisons that device handle the way a Rust panic poisons its mutex: every
/// later call on it fails with operationFailed.
class _FaultyBindings implements NativeCryptoBindings {
  _FaultyBindings(this.real);

  final NativeCryptoBindings real;
  final List<NativeCryptoError> decryptFaults = <NativeCryptoError>[];
  final List<NativeCryptoError> epochFaults = <NativeCryptoError>[];

  /// How many times a device was restored from sealed state.
  int restores = 0;

  @override
  NativeCryptoDevice createDevice(String accountId, String deviceId) =>
      _FaultyDevice(this, real.createDevice(accountId, deviceId));

  @override
  ({NativeCryptoDevice device, int counter}) restoreDevice(
      String accountId,
      String deviceId,
      List<int> stateKey,
      int minimumCounter,
      List<int> sealedState) {
    restores++;
    final restored = real.restoreDevice(
        accountId, deviceId, stateKey, minimumCounter, sealedState);
    return (
      device: _FaultyDevice(this, restored.device),
      counter: restored.counter
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FaultyDevice implements NativeCryptoDevice {
  _FaultyDevice(this.faults, this.real);

  final _FaultyBindings faults;
  final NativeCryptoDevice real;
  bool _poisoned = false;

  T _call<T>(List<NativeCryptoError> queue, T Function() operation) {
    if (_poisoned) {
      throw const NativeCryptoException(NativeCryptoError.operationFailed);
    }
    if (queue.isNotEmpty) {
      final kind = queue.removeAt(0);
      if (kind == NativeCryptoError.nativePanic) _poisoned = true;
      throw NativeCryptoException(kind);
    }
    return operation();
  }

  T _plain<T>(T Function() operation) =>
      _call(const <NativeCryptoError>[], operation);

  @override
  List<int> decrypt(String groupId, List<int> ciphertext,
          {required String senderAccountId, required String senderDeviceId}) =>
      _call(
          faults.decryptFaults,
          () => real.decrypt(groupId, ciphertext,
              senderAccountId: senderAccountId,
              senderDeviceId: senderDeviceId));

  @override
  ({int epoch, bool pending}) groupEpoch(String groupId) =>
      _call(faults.epochFaults, () => real.groupEpoch(groupId));

  @override
  EnrollmentCredential createEnrollmentCredential(List<int> challenge) =>
      _plain(() => real.createEnrollmentCredential(challenge));

  @override
  List<int> createKeyPackage() => _plain(real.createKeyPackage);

  @override
  List<int> signingPublicKey() => _plain(real.signingPublicKey);

  @override
  List<int> sealState(List<int> stateKey, int counter) =>
      _plain(() => real.sealState(stateKey, counter));

  @override
  void createGroup(String groupId) => _plain(() => real.createGroup(groupId));

  @override
  void joinGroup(String expectedGroupId, List<int> welcome) =>
      _plain(() => real.joinGroup(expectedGroupId, welcome));

  @override
  ({List<int> commit, List<int> welcome, int epoch}) stageCommit(
    String groupId, {
    List<({List<int> keyPackage, String accountId, String deviceId})> adds =
        const [],
    List<({String accountId, String deviceId})> removes = const [],
  }) =>
      _plain(() => real.stageCommit(groupId, adds: adds, removes: removes));

  @override
  ({List<int> commit, List<int> welcome, int epoch}) stageSelfUpdate(
          String groupId) =>
      _plain(() => real.stageSelfUpdate(groupId));

  @override
  void mergePendingCommit(String groupId) =>
      _plain(() => real.mergePendingCommit(groupId));

  @override
  void clearPendingCommit(String groupId) =>
      _plain(() => real.clearPendingCommit(groupId));

  @override
  void processCommit(String groupId, List<int> commit) =>
      _plain(() => real.processCommit(groupId, commit));

  @override
  List<int> encrypt(String groupId, List<int> plaintext) =>
      _plain(() => real.encrypt(groupId, plaintext));

  @override
  void close() => real.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

int _serverIds = 0;

CallSession _call(Map<String, Object?> metadata) => CallSession(
      id: 'call_${++_serverIds}',
      conversationId: 'conv_1',
      createdBy: 'acct_bob',
      invitedAccountId: 'acct_alice',
      state: 'ringing',
      version: 1,
      metadata: metadata,
      createdAt: DateTime.now().toUtc(),
    );

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

MlsMessage _welcome(_Client to,
        {required _Client from,
        required String idempotencyKey,
        required MlsCommitBundle payload}) =>
    MlsMessage(
      id: 'mls_${++_serverIds}',
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

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  int _events = 0;

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

  Future<List<int>?> receive(_Client from, MessageEnvelope sent) =>
      service.processApplicationMessage(envelopeFrom(from, sent), nextEvent());
}
