import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';

/// D70 S4 through [NativeCryptoService] and the real library: replenishment
/// cannot get stuck at the 1,000 key-package cap, deleting a conversation
/// settles its queued commits (also one left behind by a crash), and the
/// first sealed state is not kept once a save is known to have committed.
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

  test('replenishment fills the last places, then recovers as packages expire',
      () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    var now = DateTime.now();
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice',
        clock: () => now);
    Future<int> stored() async => (await alice.store.loadCryptoRecords())
        .where((r) => r.kind == cryptoRecordKindKeyPackage)
        .length;

    // The enrollment package plus 994 more: five places are left.
    for (var batch = 0; batch < 99; batch++) {
      await alice.service.createReplenishmentKeyPackages(count: 10);
    }
    await alice.service.createReplenishmentKeyPackages(count: 4);
    expect(await stored(), 995);

    // Ten asked, five places: the five are made and stored, not none.
    expect(await alice.service.createReplenishmentKeyPackages(count: 10),
        hasLength(5));
    expect(await stored(), 1000);

    // A full pool of live packages refuses and changes nothing.
    final counter = (await alice.store.loadCryptoState())!.counter;
    await expectLater(alice.service.createReplenishmentKeyPackages(count: 1),
        throwsA(isA<NativeCryptoException>()));
    expect((await alice.store.loadCryptoState())!.counter, counter);
    expect(await stored(), 1000);

    // Once they expired (84 days plus the 24-hour grace), replenishment
    // drops them first and goes on, without waiting for a sync pass.
    now = now.add(const Duration(days: 86));
    expect(await alice.service.createReplenishmentKeyPackages(count: 2),
        hasLength(2));
    expect(await stored(), 2);
    final restarted = await alice.restart(bindings);
    expect(await restarted.service.createReplenishmentKeyPackages(count: 1),
        hasLength(1));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

  test('deleting a conversation settles its queued MLS messages', () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    final carol = await _Client.enroll(bindings, 'acct_carol', 'dev_carol');
    await _startConversation(alice, bob, 'conv_1');
    await _startConversation(alice, carol, 'conv_2');
    await alice.service.stageSelfUpdate('conv_1');
    await alice.service.stageSelfUpdate('conv_2');
    expect(
        (await alice.store.pendingMlsMessages()).map((m) => m.conversationId),
        unorderedEquals(<String>['conv_1', 'conv_2']));

    expect(await alice.service.deleteConversationState('conv_1'), isTrue);
    final left = await alice.store.pendingMlsMessages();
    expect(left.map((m) => m.conversationId), <String>['conv_2']);
    expect(await alice.service.groupEpoch('conv_1'), isNull);
    // The other conversation is untouched and its commit still completes.
    await alice.service.completeCommitBundle(left.single);
    expect(await alice.store.pendingMlsMessages(), isEmpty);
    expect((await alice.service.groupEpoch('conv_2'))!.pending, isFalse);
  }, skip: skip);

  test('an accepted commit whose group was deleted settles, not loops',
      () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final store = _KeepOutboxStore();
    final alice =
        await _Client.enroll(bindings, 'acct_alice', 'dev_alice', store: store);
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob, 'conv_1');
    await alice.service.stageSelfUpdate('conv_1');
    final item = (await store.pendingMlsMessages()).single;
    expect(MlsCommitBundle.decode(item.payload).hasCommit, isTrue);

    // A crash after the group was dropped, before its entries were.
    store.keepOutbox = true;
    expect(await alice.service.deleteConversationState('conv_1'), isTrue);
    expect(await store.pendingMlsMessages(), hasLength(1));
    store.keepOutbox = false;

    // The server had accepted it: completing settles the entry.
    final counter = (await store.loadCryptoState())!.counter;
    await alice.service.completeCommitBundle(item);
    expect(await store.pendingMlsMessages(), isEmpty);
    expect((await store.loadCryptoState())!.counter, counter + 1);
    final restarted = await alice.restart(bindings);
    expect(await restarted.service.groupEpoch('conv_1'), isNull);
  }, skip: skip);

  test('the first state is dropped once a save is known to have committed',
      () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final store = _LoseFirstSaveOutcome();
    final service = NativeCryptoService(bindings: bindings, localStore: store);
    await service.createEnrollmentCredential(EnrollmentReservation(
      id: 'res_dev_a',
      accountId: 'acct_a',
      deviceId: 'dev_a',
      challenge: const <int>[1, 2, 3],
    ));
    expect(service.holdsFirstState, isFalse);
    final session = _session('acct_a', 'dev_a');
    // The save committed but reported failure.
    await expectLater(service.activateSession(session), throwsStateError);
    expect(service.holdsFirstState, isTrue);
    expect((await store.loadCryptoState())!.counter, 1);

    // The retry finds the committed state and lets the copy go.
    await service.activateSession(session);
    expect(service.holdsFirstState, isFalse);
    expect((await store.loadCryptoState())!.counter, 1);
    expect(
        await service.createReplenishmentKeyPackages(count: 1), hasLength(1));
    await service.dispose();
  }, skip: skip);

  test('a first save that commits drops the first state at once', () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    expect(alice.service.holdsFirstState, isFalse);
  }, skip: skip);
}

/// A store whose MLS outbox removals are skipped while [keepOutbox] is set,
/// as a crash between the group's drop and its entries' would leave them.
class _KeepOutboxStore extends MemoryLocalStore {
  bool keepOutbox = false;

  @override
  Future<void> removePendingMlsMessage(String idempotencyKey) async {
    if (keepOutbox) return;
    return super.removePendingMlsMessage(idempotencyKey);
  }
}

/// A store whose first crypto-state write commits but reports failure.
class _LoseFirstSaveOutcome extends MemoryLocalStore {
  bool _lost = false;

  @override
  Future<void> saveCryptoState(StoredCryptoState state, int syncCursor) async {
    await super.saveCryptoState(state, syncCursor);
    if (!_lost) {
      _lost = true;
      throw StateError('injected lost outcome');
    }
  }
}

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
  DateTime Function()? clock;

  static Future<_Client> enroll(
      NativeCryptoBindings bindings, String accountId, String deviceId,
      {DateTime Function()? clock, MemoryLocalStore? store}) async {
    final local = store ?? MemoryLocalStore();
    final service = NativeCryptoService(
        bindings: bindings, localStore: local, clock: clock);
    await service.createEnrollmentCredential(EnrollmentReservation(
      id: 'res_$deviceId',
      accountId: accountId,
      deviceId: deviceId,
      challenge: const <int>[1, 2, 3],
    ));
    await service.activateSession(_session(accountId, deviceId));
    return _Client(service, local, accountId, deviceId)..clock = clock;
  }

  /// A new service over the same store, as after an app restart.
  Future<_Client> restart(NativeCryptoBindings bindings) async {
    await service.dispose();
    final next = NativeCryptoService(
        bindings: bindings, localStore: store, clock: clock);
    await next.activateSession(_session(accountId, deviceId));
    return _Client(next, store, accountId, deviceId, events)..clock = clock;
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
}

Future<void> _startConversation(
    _Client alice, _Client bob, String conversationId) async {
  await alice.service.initializeConversation(
      conversationId, <DeviceKeyPackage>[await bob.keyPackage()]);
  final item = (await alice.store.pendingMlsMessages())
      .where((m) => m.conversationId == conversationId)
      .single;
  await alice.service.completeCommitBundle(item);
  await bob.service.processMlsMessage(MlsMessage(
    id: 'mls_${++_serverIds}',
    conversationId: conversationId,
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
