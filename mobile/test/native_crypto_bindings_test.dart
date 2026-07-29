import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

void main() {
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  test('ABI v4 lifecycle owns outputs and handles safely', () {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = bindings.createDevice('acct_alice', 'dev_alice');
    final bob = bindings.createDevice('acct_bob', 'dev_bob');
    expect(alice.signingPublicKey(), hasLength(32));
    expect(alice.signingPublicKey(), hasLength(32));
    expect(alice.signEnrollmentChallenge([1, 2, 3]), hasLength(64));
    final enrollment = alice.createEnrollmentCredential([7, 8, 9]);
    expect(enrollment.signingKey, hasLength(32));
    final linked = bindings.createDevice('acct_alice', 'dev_linked');
    final nonce = List<int>.filled(32, 0x42);
    final existingVerification = alice.deriveDeviceLinkVerification(
      protocolVersion: 'veritra-device-link-v1',
      peerDeviceId: 'dev_linked',
      peerSigningKey: linked.signingPublicKey(),
      linkNonce: nonce,
      localIsExistingDevice: true,
    );
    final linkedVerification = linked.deriveDeviceLinkVerification(
      protocolVersion: 'veritra-device-link-v1',
      peerDeviceId: 'dev_alice',
      peerSigningKey: alice.signingPublicKey(),
      linkNonce: nonce,
      localIsExistingDevice: false,
    );
    expect(
        linkedVerification.transcriptHash, existingVerification.transcriptHash);
    expect(linkedVerification.sas, existingVerification.sas);
    final substitutedKey = linked.signingPublicKey();
    substitutedKey[0] ^= 1;
    expect(
      alice
          .deriveDeviceLinkVerification(
            protocolVersion: 'veritra-device-link-v1',
            peerDeviceId: 'dev_linked',
            peerSigningKey: substitutedKey,
            linkNonce: nonce,
            localIsExistingDevice: true,
          )
          .sas,
      isNot(existingVerification.sas),
    );
    linked.close();
    final bobPackage = bob.createKeyPackage();
    alice.createGroup('conv_test');
    final added =
        alice.addMember('conv_test', bobPackage, 'acct_bob', 'dev_bob');
    bob.joinGroup('conv_test', added.welcome);
    final ciphertext = alice.encrypt('conv_test', [4, 5, 6]);
    expect(bob.decrypt('conv_test', ciphertext), [4, 5, 6]);
    final update = alice.selfUpdate('conv_test');
    bob.processCommit('conv_test', update);
    expect(
        () => bob.decrypt('conv_test', [1]),
        throwsA(isA<NativeCryptoException>().having(
            (error) => error.kind, 'kind', NativeCryptoError.operationFailed)));
    final removal = alice.removeMember('conv_test', 'acct_bob', 'dev_bob');
    bob.processCommit('conv_test', removal);
    expect(() => bob.encrypt('conv_test', [1]),
        throwsA(isA<NativeCryptoException>()));

    final key = List<int>.filled(32, 9);
    final sealed = alice.sealState(key, 7);
    alice.close();
    alice.close();
    final restored =
        bindings.restoreDevice('acct_alice', 'dev_alice', key, 7, sealed);
    expect(restored.counter, 7);
    expect(() => restored.device.encrypt('conv_test', const []),
        throwsArgumentError);
    restored.device.close();
    bob.close();
  }, skip: libraryPath == null ? 'host native library not built' : false);
}
