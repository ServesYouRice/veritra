import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';

/// K2 local schema 18 through the native engine: a pending enrollment is
/// promoted in one step with a ledger row, and once promoted its frozen
/// pre-join state never opens again, even after the active MLS state is
/// gone (review finding 4 on schema 17).

const _origin = 'https://chat.example.org';
const _session = Session(
  baseUrl: _origin,
  token: 'tok_new',
  accountId: 'acct_me',
  deviceId: 'dev_new',
  deviceSecret: 'secret_new',
);
const _reservation = EnrollmentReservation(
  id: 'res_dev_new',
  accountId: 'acct_me',
  deviceId: 'dev_new',
  challenge: <int>[1, 2, 3],
);

/// Loses the outcome of the first promotion after it committed.
class _LostOutcomeStore extends MemoryLocalStore {
  bool lose = true;

  @override
  Future<EnrollmentPromotionOutcome> promotePendingEnrollment(
      EnrollmentPromotion promotion) async {
    final outcome = await super.promotePendingEnrollment(promotion);
    if (lose) {
      lose = false;
      throw StateError('outcome lost');
    }
    return outcome;
  }
}

Future<StoredCryptoState> _enroll(
    NativeCryptoService service, LocalStore store) async {
  await service.createEnrollmentCredential(_reservation);
  final sealed = await service.sealPendingEnrollment();
  await store.savePendingEnrollment(PendingEnrollment(
    kind: PendingEnrollment.kindDeviceLinkV3,
    origin: _origin,
    accountId: 'acct_me',
    deviceId: 'dev_new',
    payloadJson: jsonEncode({'claim_token': 'claim'}),
    state: sealed,
  ));
  return sealed;
}

void main() {
  test('promotes the pending identity and keeps using it', () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final store = MemoryLocalStore();
    final service = NativeCryptoService(bindings: bindings, localStore: store);
    await _enroll(service, store);
    expect(
        await service.promotePendingEnrollment(_session,
            kind: PendingEnrollment.kindDeviceLinkV3, promotionId: 'digest-1'),
        EnrollmentPromotionOutcome.promoted);
    expect((await store.loadCryptoState())!.counter, 1);
    expect(await store.loadPendingEnrollment(), isNull);
    // The device in memory is the stored one: the next commit follows it.
    await service.createReplenishmentKeyPackages(count: 1);
    expect((await store.loadCryptoState())!.counter, 2);
    await service.dispose();
  }, skip: nativeCryptoSkip());

  // K0's real order (AppState._finishRecoveredSession): a later process
  // reopens the stored claim's frozen state, then promotes it.
  test('a K0 claim resumed in a new process promotes and commits', () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final store = MemoryLocalStore();
    var service = NativeCryptoService(bindings: bindings, localStore: store);
    await service.createEnrollmentCredential(_reservation);
    final sealed = await service.sealPendingEnrollment();
    await store.savePendingEnrollment(PendingEnrollment(
      kind: PendingEnrollment.kindAccountRecovery,
      origin: _origin,
      accountId: 'acct_me',
      deviceId: 'dev_new',
      payloadJson: jsonEncode({'request_id': 'req_1'}),
      state: sealed,
    ));
    await service.dispose();
    // A signed-out device of the same account is still stored.
    await store.saveSession(const Session(
        baseUrl: _origin,
        token: '',
        accountId: 'acct_me',
        deviceId: 'dev_old',
        deviceSecret: 'secret_old'));

    service = NativeCryptoService(bindings: bindings, localStore: store);
    final stored = (await store.loadPendingEnrollment())!.state!;
    await service.resumePendingEnrollment(
        accountId: 'acct_me', deviceId: 'dev_new', state: stored);
    expect(
        await service.promotePendingEnrollment(_session,
            kind: PendingEnrollment.kindAccountRecovery, promotionId: 'req_1'),
        EnrollmentPromotionOutcome.promoted);
    expect((await store.loadSession())!.deviceId, 'dev_new');
    expect(await store.loadPendingEnrollment(), isNull);
    await service.createReplenishmentKeyPackages(count: 1);
    expect((await store.loadCryptoState())!.counter, 2);
    await service.dispose();

    // The next start opens the stored state, never the frozen one.
    service = NativeCryptoService(bindings: bindings, localStore: store);
    await service.activateSession(_session);
    await service.createReplenishmentKeyPackages(count: 1);
    expect((await store.loadCryptoState())!.counter, 3);
    await expectLater(
        service.resumePendingEnrollment(
            accountId: 'acct_me', deviceId: 'dev_new', state: stored),
        throwsA(isA<StateError>()));
    await service.dispose();
  }, skip: nativeCryptoSkip());

  test('a lost outcome is retried onto the stored state', () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final store = _LostOutcomeStore();
    final service = NativeCryptoService(bindings: bindings, localStore: store);
    await _enroll(service, store);
    await expectLater(
        service.promotePendingEnrollment(_session,
            kind: PendingEnrollment.kindDeviceLinkV3, promotionId: 'digest-1'),
        throwsA(isA<StateError>()));
    expect(
        await service.promotePendingEnrollment(_session,
            kind: PendingEnrollment.kindDeviceLinkV3, promotionId: 'digest-1'),
        EnrollmentPromotionOutcome.alreadyPromoted);
    await service.createReplenishmentKeyPackages(count: 1);
    expect((await store.loadCryptoState())!.counter, 2);
    await service.dispose();
  }, skip: nativeCryptoSkip());
}
