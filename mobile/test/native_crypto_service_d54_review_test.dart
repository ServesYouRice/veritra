import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// Real OpenMLS devices driven through [NativeCryptoService], for the review
/// of D54: which native errors count as "can never decrypt", and what stays
/// fail-closed.
void main() {
  final configured = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final libraryPath =
      configured == null || configured.isEmpty ? null : configured;
  final skip = libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false;

  group('a decrypt error is retried once on a fresh handle (D54)', () {
    for (final kind in <NativeCryptoError>[
      NativeCryptoError.operationFailed,
      NativeCryptoError.nativePanic,
      NativeCryptoError.invalidOutput,
    ]) {
      test('one ${kind.name} still decrypts the message', () async {
        final faults = _FaultyBindings(NativeCryptoBindings.open(libraryPath!));
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
      final faults = _FaultyBindings(NativeCryptoBindings.open(libraryPath!));
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
        final faults = _FaultyBindings(NativeCryptoBindings.open(libraryPath!));
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
      final faults = _FaultyBindings(NativeCryptoBindings.open(libraryPath!));
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
      final faults = _FaultyBindings(NativeCryptoBindings.open(libraryPath!));
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
      final faults = _FaultyBindings(NativeCryptoBindings.open(libraryPath!));
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
      final faults = _FaultyBindings(NativeCryptoBindings.open(libraryPath!));
      final alice = await _Client.enroll(faults, 'acct_alice', 'dev_alice');
      expect(await alice.service.groupEpoch('conv_none'), isNull);
    }, skip: skip);
  });
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
