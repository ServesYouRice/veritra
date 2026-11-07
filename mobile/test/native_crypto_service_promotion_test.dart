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

  test('after a restore the frozen identity never opens again', () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final store = MemoryLocalStore();
    var service = NativeCryptoService(bindings: bindings, localStore: store);
    final frozen = await _enroll(service, store);
    await service.promotePendingEnrollment(_session,
        kind: PendingEnrollment.kindDeviceLinkV3, promotionId: 'digest-1');
    await service.createReplenishmentKeyPackages(count: 1);
    await store.saveSnapshot(const <Conversation>[],
        const <String, List<ReceivedMessageEnvelope>>{}, 0);
    await store.restoreBackup(await store.exportBackup());
    await store.saveSession(_session);
    expect(await store.loadCryptoState(), isNull);
    await service.dispose();

    // A restart with the identity's session and an empty MLS state.
    service = NativeCryptoService(bindings: bindings, localStore: store);
    await expectLater(
        service.resumePendingEnrollment(
            accountId: 'acct_me', deviceId: 'dev_new', state: frozen),
        throwsA(isA<StateError>()));
    await expectLater(
        service.activateSession(_session), throwsA(isA<StateError>()));
    await expectLater(service.createEnrollmentCredential(_reservation),
        throwsA(isA<StateError>()));
    expect(await store.loadCryptoState(), isNull);
    await service.dispose();
  }, skip: nativeCryptoSkip());
}
