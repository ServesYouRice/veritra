import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

void main() {
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  test('ABI v9 lifecycle owns outputs and handles safely', () {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = bindings.createDevice('acct_alice', 'dev_alice');
    final bob = bindings.createDevice('acct_bob', 'dev_bob');
    expect(alice.signingPublicKey(), hasLength(32));
    expect(alice.signingPublicKey(), hasLength(32));
    final enrollment = alice.createEnrollmentCredential([7, 8, 9]);
    expect(enrollment.signingKey, hasLength(32));
    final linked = bindings.createDevice('acct_alice', 'dev_linked');
    final nonce = List<int>.filled(32, 0x42);
    final existingVerification = alice.deriveDeviceLinkVerification(
      protocolVersion: 'veritra-device-link-v2',
      serverOrigin: 'https://example.test',
      linkId: 'link_01',
      linkSecret: List<int>.filled(16, 0x55),
      peerDeviceId: 'dev_linked',
      peerSigningKey: linked.signingPublicKey(),
      linkNonce: nonce,
      localIsExistingDevice: true,
    );
    final linkedVerification = linked.deriveDeviceLinkVerification(
      protocolVersion: 'veritra-device-link-v2',
      serverOrigin: 'https://example.test',
      linkId: 'link_01',
      linkSecret: List<int>.filled(16, 0x55),
      peerDeviceId: 'dev_alice',
      peerSigningKey: alice.signingPublicKey(),
      linkNonce: nonce,
      localIsExistingDevice: false,
    );
    expect(
        linkedVerification.transcriptHash, existingVerification.transcriptHash);
    expect(linkedVerification.sas, existingVerification.sas);
    expect(linkedVerification.claimTag, existingVerification.claimTag);
    expect(linkedVerification.approvalTag, existingVerification.approvalTag);
    expect(linkedVerification.claimTag, isNot(linkedVerification.approvalTag));
    final substitutedKey = linked.signingPublicKey();
    substitutedKey[0] ^= 1;
    expect(
      alice
          .deriveDeviceLinkVerification(
            protocolVersion: 'veritra-device-link-v2',
            serverOrigin: 'https://example.test',
            linkId: 'link_01',
            linkSecret: List<int>.filled(16, 0x55),
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
    expect(
        bob.decrypt('conv_test', ciphertext,
            senderAccountId: 'acct_alice', senderDeviceId: 'dev_alice'),
        [4, 5, 6]);
    final spoofed = alice.encrypt('conv_test', [7]);
    expect(
        () => bob.decrypt('conv_test', spoofed,
            senderAccountId: 'acct_mallory', senderDeviceId: 'dev_mallory'),
        throwsA(isA<NativeCryptoException>().having(
            (error) => error.kind, 'kind', NativeCryptoError.senderMismatch)));
    final update = alice.selfUpdate('conv_test');
    bob.processCommit('conv_test', update);
    expect(
        () => bob.decrypt('conv_test', [1],
            senderAccountId: 'acct_alice', senderDeviceId: 'dev_alice'),
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
    final oldFormat = List<int>.of(sealed)..setRange(8, 10, const [0, 1]);
    expect(
        () => bindings.restoreDevice(
            'acct_alice', 'dev_alice', key, 7, oldFormat),
        throwsA(isA<NativeCryptoException>().having((error) => error.kind,
            'kind', NativeCryptoError.stateFormatUnsupported)));
    final tampered = List<int>.of(sealed)..[sealed.length - 1] ^= 1;
    expect(
        () =>
            bindings.restoreDevice('acct_alice', 'dev_alice', key, 7, tampered),
        throwsA(isA<NativeCryptoException>().having(
            (error) => error.kind, 'kind', NativeCryptoError.operationFailed)));
    expect(() => restored.device.encrypt('conv_test', const []),
        throwsArgumentError);
    restored.device.close();
    bob.close();
  }, skip: libraryPath == null ? 'host native library not built' : false);

  test('a past-epoch message from a removed device is senderRemoved', () {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = bindings.createDevice('acct_alice', 'dev_alice');
    final bob = bindings.createDevice('acct_bob', 'dev_bob');
    final carol = bindings.createDevice('acct_carol', 'dev_carol');
    alice.createGroup('conv_removed');
    final added = alice.stageCommit('conv_removed', adds: [
      (
        keyPackage: bob.createKeyPackage(),
        accountId: 'acct_bob',
        deviceId: 'dev_bob'
      ),
      (
        keyPackage: carol.createKeyPackage(),
        accountId: 'acct_carol',
        deviceId: 'dev_carol'
      ),
    ]);
    alice.mergePendingCommit('conv_removed');
    bob.joinGroup('conv_removed', added.welcome);
    carol.joinGroup('conv_removed', added.welcome);
    final removal = alice.stageCommit('conv_removed',
        removes: [(accountId: 'acct_bob', deviceId: 'dev_bob')]);
    alice.mergePendingCommit('conv_removed');
    carol.processCommit('conv_removed', removal.commit);
    // Bob never applies his removal and writes in the old epoch.
    final injected = bob.encrypt('conv_removed', [1, 2, 3]);
    expect(
        () => carol.decrypt('conv_removed', injected,
            senderAccountId: 'acct_bob', senderDeviceId: 'dev_bob'),
        throwsA(isA<NativeCryptoException>().having(
            (error) => error.kind, 'kind', NativeCryptoError.senderRemoved)));
    // The service commits the ratchet and keeps a warning for both.
    expect(NativeCryptoError.senderRemoved.ratchetAdvanced, isTrue);
    expect(NativeCryptoError.senderMismatch.ratchetAdvanced, isTrue);
    expect(NativeCryptoError.operationFailed.ratchetAdvanced, isFalse);
    alice.close();
    bob.close();
    carol.close();
  }, skip: libraryPath == null ? 'host native library not built' : false);
}
