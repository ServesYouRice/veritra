import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';

/// D70 S4: a seal the native library refuses with `PM_CRYPTO_RECORD_LIMIT`
/// (-8) fails closed through [NativeCryptoService]. The app sees
/// [CryptoRecordLimitExceeded] naming the conversation, nothing is stored,
/// and the in-memory group is rolled back, so the same message still
/// decrypts once the seal goes through.
void main() {
  final configured = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final libraryPath =
      configured == null || configured.isEmpty ? null : configured;
  if (libraryPath == null && Platform.environment['CI'] == 'true') {
    test('CI provides the native crypto library', () {
      fail('VERITRA_CRYPTO_LIBRARY is required when CI=true');
    });
  }
  final skip = libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false;

  test('a record over its limit rolls back and names the conversation',
      () async {
    final real = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(real, 'acct_alice', 'dev_alice');
    final limited = _LimitBindings(real);
    final bob = await _Client.enroll(limited, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);

    final hello = await alice.service.encryptPayload(
        'conv_1', AppPayloadType.text, <String, Object?>{'text': 'hi'});
    final before = (await bob.store.loadCryptoState())!.counter;
    final cursor = await bob.store.loadSyncCursor();
    final event = cursor + 1;

    limited.refuseSeal = true;
    await expectLater(
        bob.receive(alice, hello, event),
        throwsA(isA<CryptoRecordLimitExceeded>()
            .having((e) => e.conversationId, 'conversationId', 'conv_1')));
    expect((await bob.store.loadCryptoState())!.counter, before);
    expect(await bob.store.loadSyncCursor(), cursor);
    expect(await bob.store.loadMessages('conv_1'), isEmpty);

    // A send fails the same way and queues nothing.
    await expectLater(
        bob.service.encryptPayload(
            'conv_1', AppPayloadType.text, <String, Object?>{'text': 'no'}),
        throwsA(isA<CryptoRecordLimitExceeded>()));
    expect(await bob.store.pendingEnvelopes(), isEmpty);
    expect((await bob.store.loadCryptoState())!.counter, before);

    // The group was rolled back, not left advanced: the same message
    // decrypts once sealing works again.
    limited.refuseSeal = false;
    await bob.receive(alice, hello, event);
    expect((await bob.store.loadMessages('conv_1')).single.body, 'hi');
    expect(await bob.store.loadSyncCursor(), event);
  }, skip: skip);

  test('a stored group that fails to load does not settle an accepted commit',
      () async {
    final real = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(real, 'acct_alice', 'dev_alice');
    final limited = _LimitBindings(real);
    final bob = await _Client.enroll(limited, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    await bob.service.stageSelfUpdate('conv_1');
    final item = (await bob.store.pendingMlsMessages()).single;

    // The group is stored; only this read fails. Not a missing group.
    limited.epochFailures = 1;
    await expectLater(bob.service.completeCommitBundle(item),
        throwsA(isA<NativeCryptoException>()));
    expect(await bob.store.pendingMlsMessages(), hasLength(1));
    limited.epochFailures = 1;
    await expectLater(bob.service.abandonCommitBundle(item),
        throwsA(isA<NativeCryptoException>()));
    expect(await bob.store.pendingMlsMessages(), hasLength(1));

    await bob.service.completeCommitBundle(item);
    expect(await bob.store.pendingMlsMessages(), isEmpty);
    expect(await bob.service.groupEpoch('conv_1'), (epoch: 2, pending: false));
  }, skip: skip);
}

/// Real bindings whose devices refuse every seal with a group record over
/// its cap while [refuseSeal] is set.
class _LimitBindings implements NativeCryptoBindings {
  _LimitBindings(this.real);

  final NativeCryptoBindings real;
  bool refuseSeal = false;

  /// How many next `groupEpoch` calls fail with operationFailed.
  int epochFailures = 0;

  @override
  NativeCryptoDevice createDevice(String accountId, String deviceId) =>
      _LimitDevice(this, real.createDevice(accountId, deviceId));

  @override
  ({NativeCryptoDevice device, int generation}) restoreRecords(
      String accountId,
      String deviceId,
      List<int> stateKey,
      int minimumGeneration,
      List<int> root,
      Iterable<List<int>> records) {
    final restored = real.restoreRecords(
        accountId, deviceId, stateKey, minimumGeneration, root, records);
    return (
      device: _LimitDevice(this, restored.device),
      generation: restored.generation
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LimitDevice implements NativeCryptoDevice {
  _LimitDevice(this.limits, this.real);

  final _LimitBindings limits;
  final NativeCryptoDevice real;

  @override
  NativeChangeSet sealChanges(List<int> stateKey, int generation) {
    if (limits.refuseSeal) {
      throw NativeRecordLimitException(2, 'conv_1'.codeUnits);
    }
    return real.sealChanges(stateKey, generation);
  }

  @override
  List<int> decrypt(String groupId, List<int> ciphertext,
          {required String senderAccountId, required String senderDeviceId}) =>
      real.decrypt(groupId, ciphertext,
          senderAccountId: senderAccountId, senderDeviceId: senderDeviceId);

  @override
  ({int epoch, bool pending}) groupEpoch(String groupId) {
    if (limits.epochFailures > 0) {
      limits.epochFailures--;
      throw const NativeCryptoException(NativeCryptoError.operationFailed);
    }
    return real.groupEpoch(groupId);
  }

  @override
  ({List<int> commit, List<int> welcome, int epoch}) stageSelfUpdate(
          String groupId) =>
      real.stageSelfUpdate(groupId);

  @override
  void mergePendingCommit(String groupId) => real.mergePendingCommit(groupId);

  @override
  void clearPendingCommit(String groupId) => real.clearPendingCommit(groupId);

  @override
  EnrollmentCredential createEnrollmentCredential(List<int> challenge) =>
      real.createEnrollmentCredential(challenge);

  @override
  List<int> createKeyPackage() => real.createKeyPackage();

  @override
  int pruneKeyPackages(DateTime now) => real.pruneKeyPackages(now);

  @override
  List<int> signingPublicKey() => real.signingPublicKey();

  @override
  void joinGroup(String expectedGroupId, List<int> welcome) =>
      real.joinGroup(expectedGroupId, welcome);

  @override
  List<int> encrypt(String groupId, List<int> plaintext) =>
      real.encrypt(groupId, plaintext);

  @override
  void close() => real.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Session _session(String accountId, String deviceId) => Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    );

int _serverIds = 0;

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  int events = 0;

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
    await service.activateSession(_session(accountId, deviceId));
    return _Client(service, store, accountId, deviceId);
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

  Future<void> receive(_Client from, MessageEnvelope sent, int event) =>
      service.processApplicationMessage(
        ReceivedMessageEnvelope(
          id: 'srv_${sent.idempotencyKey}',
          conversationId: sent.conversationId,
          senderAccountId: from.accountId,
          senderDeviceId: from.deviceId,
          idempotencyKey: sent.idempotencyKey,
          ciphertext: sent.ciphertext,
          cryptoProtocol: sent.cryptoProtocol,
          createdAt: DateTime.now().toUtc(),
        ),
        event,
      );
}

Future<void> _startConversation(_Client alice, _Client bob) async {
  await alice.service.initializeConversation(
      'conv_1', <DeviceKeyPackage>[await bob.keyPackage()]);
  final item = (await alice.store.pendingMlsMessages()).single;
  await alice.service.completeCommitBundle(item);
  await bob.service.processMlsMessage(MlsMessage(
    id: 'mls_${++_serverIds}',
    conversationId: 'conv_1',
    senderAccountId: alice.accountId,
    senderDeviceId: alice.deviceId,
    kind: 'welcome',
    payload: MlsCommitBundle.decode(item.payload).welcome,
    idempotencyKey: '${item.idempotencyKey}:welcome:${bob.deviceId}',
    syncEventId: ++bob.events,
    createdAt: DateTime.now().toUtc(),
    recipientDeviceId: bob.deviceId,
  ));
}
