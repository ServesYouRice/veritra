import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';

/// C-b5dfd921d890: a new enrollment swaps in a fresh, group-less device. Until
/// the new session is activated, no operation may seal that device over the
/// MLS state already stored on this device.
void main() {
  test('a pending enrollment never seals over stored MLS state', () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final store = MemoryLocalStore();
    final service = NativeCryptoService(bindings: bindings, localStore: store);
    await service.createEnrollmentCredential(const EnrollmentReservation(
      id: 'res_dev_alice',
      accountId: 'acct_alice',
      deviceId: 'dev_alice',
      challenge: <int>[1, 2, 3],
    ));
    await service.activateSession(const Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: 'acct_alice',
      deviceId: 'dev_alice',
    ));
    final before = (await store.loadCryptoState())!;

    // A second enrollment starts while the first identity's state is stored.
    await service.createEnrollmentCredential(const EnrollmentReservation(
      id: 'res_dev_alice_2',
      accountId: 'acct_alice',
      deviceId: 'dev_alice',
      challenge: <int>[4, 5, 6],
    ));

    await expectLater(service.createReplenishmentKeyPackages(count: 1),
        throwsA(isA<StateError>()));

    final after = (await store.loadCryptoState())!;
    expect(after.counter, before.counter);
    expect(after.sealedState, before.sealedState);
    await service.dispose();
  }, skip: nativeCryptoSkip());
}
