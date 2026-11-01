import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// D70 S3 through [NativeCryptoService] and the real library: every
/// transition stores its change set, a restart restores from the records,
/// a format-3 blob migrates at activation, a group that is gone behaves
/// like an inactive one did (D54), and a Welcome for a key package this
/// device lacks becomes a notice (D74).
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

  test('transitions store records that a restart restores', () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    final first = await alice.store.loadCryptoSnapshot();
    expect(first.state!.counter, 1);
    expect(_version(first.state!.sealedState), 4);
    // The device record and the enrollment key package.
    expect(first.records.map((r) => r.kind),
        [cryptoRecordKindDevice, cryptoRecordKindKeyPackage]);

    await _startConversation(alice, bob);
    for (final client in [alice, bob]) {
      final snapshot = await client.store.loadCryptoSnapshot();
      expect(
          snapshot.records.where((r) =>
              r.kind == cryptoRecordKindGroup &&
              String.fromCharCodes(r.recordId) == 'conv_1'),
          hasLength(1),
          reason: client.deviceId);
      expect(
          snapshot.records
              .every((r) => r.generation <= snapshot.state!.counter),
          isTrue);
    }

    final hello =
        await alice.send(AppPayloadType.text, <String, Object?>{'text': 'hi'});
    await bob.receive(alice, hello);

    // Both restart from what is stored and keep talking.
    final alice2 = await alice.restart(bindings);
    final bob2 = await bob.restart(bindings);
    final reply =
        await bob2.send(AppPayloadType.text, <String, Object?>{'text': 'yo'});
    await alice2.receive(bob2, reply);
    expect((await alice2.history()).last.body, 'yo');
    expect(await alice2.service.groupEpoch('conv_1'),
        await bob2.service.groupEpoch('conv_1'));
  }, skip: skip);

  test('a format-3 blob migrates once at activation, dropping leftovers',
      () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final blob = File('../crypto/rust/tests/fixtures/state-v3/source.bin')
        .readAsBytesSync();
    final key = List<int>.filled(32, 0x73);
    expect(_version(blob), 3);

    // A wrong counter fails closed and leaves the blob as it was.
    final stale = MemoryLocalStore();
    await stale.saveCryptoState(
        StoredCryptoState(counter: 50, stateKey: key, sealedState: blob), 7);
    final refused = NativeCryptoService(bindings: bindings, localStore: stale);
    await expectLater(
        refused.activateSession(_session('acct_fixture3', 'dev_src')),
        throwsA(anything));
    expect((await stale.loadCryptoState())!.sealedState, blob);
    await refused.dispose();

    final store = MemoryLocalStore();
    await store.saveCryptoState(
        StoredCryptoState(counter: 51, stateKey: key, sealedState: blob), 7);
    // Records left by an older build that opened this database.
    store.seedCryptoRecordsForTest([
      StoredCryptoRecord(
          kind: cryptoRecordKindGroup,
          recordId: 'conv_old'.codeUnits,
          generation: 40,
          sealed: const [1, 2, 3]),
    ]);
    final service = NativeCryptoService(bindings: bindings, localStore: store);
    await service.activateSession(_session('acct_fixture3', 'dev_src'));

    final snapshot = await store.loadCryptoSnapshot();
    expect(snapshot.state!.counter, 52);
    expect(_version(snapshot.state!.sealedState), 4);
    expect(await store.loadSyncCursor(), 7);
    final groups = snapshot.records
        .where((r) => r.kind == cryptoRecordKindGroup)
        .map((r) => String.fromCharCodes(r.recordId))
        .toList();
    expect(groups, ['conv_alpha', 'conv_beta']);
    expect(snapshot.records.where((r) => r.kind == cryptoRecordKindDevice),
        hasLength(1));
    expect(snapshot.records.where((r) => r.kind == cryptoRecordKindKeyPackage),
        hasLength(2));
    expect(snapshot.records.every((r) => r.generation == 52), isTrue);

    expect(await service.groupEpoch('conv_alpha'), isNotNull);
    expect(await service.groupEpoch('conv_beta'), isNotNull);
    // The inactive group was dropped by the migration.
    expect(await service.groupEpoch('conv_gamma'), isNull);

    // The next activation is a plain restore; nothing migrates again.
    await service.dispose();
    final again = NativeCryptoService(bindings: bindings, localStore: store);
    await again.activateExistingSessionBounded(
        _session('acct_fixture3', 'dev_src'),
        checkCanCommit: () {});
    expect((await store.loadCryptoState())!.counter, 52);
    expect(await again.groupEpoch('conv_alpha'), isNotNull);
    await again.dispose();
  }, skip: skip);

  test('a group that is gone settles its bundle and its messages (D54)',
      () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);

    // Bob staged a self-update; Alice removes him before it is accepted.
    await bob.service.stageSelfUpdate('conv_1');
    final bobBundle = (await bob.store.pendingMlsMessages()).single;
    await alice.service.stageMembershipChange('conv_1',
        removes: <MlsDeviceRef>[(accountId: 'acct_bob', deviceId: 'dev_bob')]);
    final removal = (await alice.store.pendingMlsMessages()).single;
    await alice.service.completeCommitBundle(removal);
    await _deliverCommit(alice, bob, removal);

    // Applying his own removal dropped Bob's group and its record.
    expect(await bob.service.groupEpoch('conv_1'), isNull);
    final snapshot = await bob.store.loadCryptoSnapshot();
    expect(snapshot.records.where((r) => r.kind == cryptoRecordKindGroup),
        isEmpty);

    // The refused bundle settles instead of failing on the missing group.
    await bob.service.abandonCommitBundle(bobBundle);
    expect(await bob.store.pendingMlsMessages(), isEmpty);

    // A message to the group he left is a placeholder, and sync moves on.
    final after =
        await alice.send(AppPayloadType.text, <String, Object?>{'text': 'bye'});
    await bob.receive(alice, after);
    expect(await bob.store.loadSyncCursor(), bob.events);
    final row = (await bob.history()).last;
    expect(row.kind, LocalMessageKind.invalid);
    expect(row.key, startsWith('undecryptable:'));
    expect(row.body, isNull);

    // And all of it survives a restart.
    final restarted = await bob.restart(bindings);
    expect(await restarted.service.groupEpoch('conv_1'), isNull);
  }, skip: skip);

  test('a Welcome for a key package this device lacks is a notice (D74)',
      () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    final tablet = await _Client.enroll(bindings, 'acct_bob', 'dev_tablet');
    await alice.service.initializeConversation(
        'conv_1', <DeviceKeyPackage>[await bob.keyPackage()]);
    final item = (await alice.store.pendingMlsMessages()).single;
    await alice.service.completeCommitBundle(item);
    final welcome = MlsCommitBundle.decode(item.payload).welcome;
    final before = await tablet.store.loadCryptoState();

    // The tablet never had the key package the Welcome names.
    final event = tablet.nextEvent();
    await tablet.service.processMlsMessage(MlsMessage(
      id: 'mls_welcome',
      conversationId: 'conv_1',
      senderAccountId: 'acct_alice',
      senderDeviceId: 'dev_alice',
      kind: 'welcome',
      payload: welcome,
      idempotencyKey: '${item.idempotencyKey}:welcome:dev_tablet',
      syncEventId: event,
      createdAt: DateTime.now().toUtc(),
      recipientDeviceId: 'dev_tablet',
    ));
    expect(await tablet.store.loadSyncCursor(), event);
    expect(await tablet.service.groupEpoch('conv_1'), isNull);
    final row = (await tablet.history()).single;
    expect(row.key, 'welcome-unavailable:$event:mls_welcome');
    expect(row.kind, LocalMessageKind.invalid);
    expect(row.body, isNull);
    expect(
        (await tablet.store.loadCryptoState())!.counter, before!.counter + 1);

    // The device that holds the key package still joins.
    await bob.service.processMlsMessage(MlsMessage(
      id: 'mls_welcome_bob',
      conversationId: 'conv_1',
      senderAccountId: 'acct_alice',
      senderDeviceId: 'dev_alice',
      kind: 'welcome',
      payload: welcome,
      idempotencyKey: '${item.idempotencyKey}:welcome:dev_bob',
      syncEventId: bob.nextEvent(),
      createdAt: DateTime.now().toUtc(),
      recipientDeviceId: 'dev_bob',
    ));
    expect(await bob.service.groupEpoch('conv_1'), isNotNull);
  }, skip: skip);

  test('a first activation whose store failed can be retried', () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final store = _FailFirstSave();
    final service = NativeCryptoService(bindings: bindings, localStore: store);
    await service.createEnrollmentCredential(EnrollmentReservation(
      id: 'res_dev_a',
      accountId: 'acct_a',
      deviceId: 'dev_a',
      challenge: const <int>[1, 2, 3],
    ));
    final session = _session('acct_a', 'dev_a');
    await expectLater(service.activateSession(session), throwsStateError);
    expect(await store.loadCryptoState(), isNull);
    // The retry stores the same first state instead of sealing again.
    await service.activateSession(session);
    expect((await store.loadCryptoState())!.counter, 1);
    await service.dispose();
    final restarted =
        NativeCryptoService(bindings: bindings, localStore: store);
    await restarted.activateSession(session);
    await restarted.dispose();
  }, skip: skip);

  test('deleting a conversation drops its record; its messages are D54',
      () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);

    expect(await bob.service.deleteConversationState('conv_1'), isTrue);
    expect(await bob.service.deleteConversationState('conv_1'), isFalse);
    expect(await bob.service.groupEpoch('conv_1'), isNull);
    expect(
        (await bob.store.loadCryptoRecords())
            .where((r) => r.kind == cryptoRecordKindGroup),
        isEmpty);

    // A message to the deleted group fails like one to an inactive group
    // did: a placeholder, and sync moves on.
    final hello =
        await alice.send(AppPayloadType.text, <String, Object?>{'text': 'hi'});
    await bob.receive(alice, hello);
    expect(await bob.store.loadSyncCursor(), bob.events);
    expect((await bob.history()).last.key, startsWith('undecryptable:'));

    final restarted = await bob.restart(bindings);
    expect(await restarted.service.groupEpoch('conv_1'), isNull);
  }, skip: skip);

  test('expired key packages are pruned and the change is stored', () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    await alice.service.createReplenishmentKeyPackages(count: 3);
    Future<int> stored() async => (await alice.store.loadCryptoRecords())
        .where((r) => r.kind == cryptoRecordKindKeyPackage)
        .length;
    expect(await stored(), 4);
    final counter = (await alice.store.loadCryptoState())!.counter;

    // Nothing has expired yet: no change, no new state.
    expect(await alice.service.pruneExpiredKeyPackages(DateTime.now()), 0);
    expect((await alice.store.loadCryptoState())!.counter, counter);

    // 84 days of lifetime plus the 24-hour grace have passed.
    final later = DateTime.now().add(const Duration(days: 86));
    expect(await alice.service.pruneExpiredKeyPackages(later), 4);
    expect(await stored(), 0);
    expect((await alice.store.loadCryptoState())!.counter, counter + 1);
    final restarted = await alice.restart(bindings);
    expect(await restarted.service.createReplenishmentKeyPackages(count: 1),
        hasLength(1));
  }, skip: skip);
}

/// A store whose first crypto-state write fails, as a full disk would.
class _FailFirstSave extends MemoryLocalStore {
  bool _failed = false;

  @override
  Future<void> saveCryptoState(StoredCryptoState state, int syncCursor) {
    if (!_failed) {
      _failed = true;
      throw StateError('injected store failure');
    }
    return super.saveCryptoState(state, syncCursor);
  }
}

int _version(List<int> sealed) => (sealed[8] << 8) | sealed[9];

Session _session(String accountId, String deviceId) => Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    );

int _serverIds = 0;

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId,
      [this.events = 0]);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  int events;

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

  /// A new service over the same store, as after an app restart.
  Future<_Client> restart(NativeCryptoBindings bindings) async {
    await service.dispose();
    final next = NativeCryptoService(bindings: bindings, localStore: store);
    await next.activateSession(_session(accountId, deviceId));
    return _Client(next, store, accountId, deviceId, events);
  }

  int nextEvent() => ++events;

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

  Future<void> receive(_Client from, MessageEnvelope sent) async {
    await service.processApplicationMessage(
      ReceivedMessageEnvelope(
        id: 'srv_${++_serverIds}',
        conversationId: sent.conversationId,
        senderAccountId: from.accountId,
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
    syncEventId: bob.nextEvent(),
    createdAt: DateTime.now().toUtc(),
    recipientDeviceId: bob.deviceId,
  ));
}

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
