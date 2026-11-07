import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'native_state_round_trip.dart';

void main() {
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final skip = libraryPath == null ? 'host native library not built' : false;

  test(
      'ABI8 persists transfer keys, approval intent and exact enrollment proof',
      () {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    var source = bindings.createDevice('account', 'source');
    var recipient = bindings.createDevice('account', 'recipient');
    const id = K2TransferId('https://example.test', 'link');
    final secret = List<int>.filled(16, 8);
    final stateKey = List<int>.filled(32, 7);
    // L1-3: the source commits to its random before the new device begins.
    final sourceRandom = List<int>.filled(32, 6);
    final commitment =
        source.k2SourceCommitment('https://example.test', sourceRandom);
    K2LinkContext context(List<int> transferKey, List<int> random) =>
        K2LinkContext(
          id: id,
          accountId: 'account',
          nonce: List<int>.filled(32, 9),
          sourceDeviceId: 'source',
          sourceSigningKey: source.signingPublicKey(),
          recipientDeviceId: 'recipient',
          recipientSigningKey: recipient.signingPublicKey(),
          transferPublicKey: transferKey,
          sourceCommitment: commitment,
          recipientRandom: random,
        );
    try {
      expect(commitment, hasLength(32));
      final beginning =
          context(List<int>.filled(32, 0), List<int>.filled(32, 0));
      final received = recipient.k2ReceiveBegin(beginning, secret,
          originalExpiresAt: 1000, now: 100);
      expect(received.recipientRandom.any((b) => b != 0), isTrue);
      // A random that does not open the commitment accepts nothing.
      final wrong = List<int>.filled(32, 5);
      expect(
          () => source.k2SourceAccept(
              context(received.transferPublicKey, received.recipientRandom),
              secret,
              originalExpiresAt: 1000,
              now: 100,
              transcriptHash: received.transcriptHash,
              claimTag: received.claimTag,
              sourceRandom: wrong),
          throwsA(isA<NativeCryptoException>()));
      final claimed = source.k2SourceAccept(
          context(received.transferPublicKey, received.recipientRandom), secret,
          originalExpiresAt: 1000,
          now: 100,
          transcriptHash: received.transcriptHash,
          claimTag: received.claimTag,
          sourceRandom: sourceRandom);
      expect(claimed.transcriptHash, received.transcriptHash);
      // Honest run: the new device's reveal shows the source's code, and a
      // substituted random shows none (VAL-066).
      expect(recipient.k2RevealSas(id, sourceRandom, now: 100), claimed.sas);
      expect(() => recipient.k2RevealSas(id, wrong, now: 100),
          throwsA(isA<NativeCryptoException>()));
      expect(recipient.k2Inspect(id, now: 100).verification.sas, isEmpty);
      expect(source.k2Inspect(id, now: 100).verification.sas, claimed.sas);
      expect(source.k2Inspect(id, now: 100).intentPresent, isFalse);
      expect(() => source.k2SourceApprovalRequest(id, now: 100),
          throwsA(isA<NativeCryptoException>()));

      final package = recipient.createKeyPackage();
      K2ProofResult proof() => recipient.k2EnrollmentProof(id,
          now: 100,
          locator: List.filled(64, 'a').join(),
          reservationRequestId: List<int>.filled(32, 0x11),
          deviceName: 'New phone',
          challenge: [255, 0, 1],
          keyPackage: package,
          claimTokenHash: List<int>.filled(32, 0x77),
          deviceSecretHash: List<int>.filled(32, 0x88),
          initialSessionHash: List<int>.filled(32, 0x99));
      final originalProof = proof();
      expect(originalProof.signature, hasLength(64));
      expect(originalProof.requestHash, hasLength(32));
      recipient = reopenFreshDevice(bindings, recipient, 'account', 'recipient',
          stateKey: stateKey);
      final resumed = recipient.k2ReceiveBegin(beginning, secret,
          originalExpiresAt: 1000, now: 100);
      expect(resumed.transferPublicKey, received.transferPublicKey);
      expect(resumed.recipientRandom, received.recipientRandom);
      // The reveal is read only: after a restart it gives the same code.
      expect(recipient.k2RevealSas(id, sourceRandom, now: 100), claimed.sas);
      expect(proof().signature, originalProof.signature);
      expect(proof().requestHash, originalProof.requestHash);

      expect(source.k2SourceConfirm(id, claimed.sas, now: 100), 100);
      source = reopenFreshDevice(bindings, source, 'account', 'source',
          stateKey: stateKey);
      expect(source.k2Inspect(id, now: 100).intentPresent, isTrue);
      expect(source.k2SourceConfirm(id, claimed.sas, now: 110), 100);
      final approval = source.k2SourceApprovalRequest(id, now: 110);
      final deadline = source.k2ApplyApproval(id, approval.approvalTag,
          approvedAt: 110, now: 110);
      expect(
          recipient.k2ApplyApproval(id, approval.approvalTag,
              approvedAt: 110, now: 110),
          deadline);
      expect(recipient.k2Inspect(id, now: 110).stage, K2Stage.approved);
      expect(recipient.k2Inspect(id, now: 110).direction, K2Direction.incoming);
      expect(() => recipient.k2SourceApprovalRequest(id, now: 110),
          throwsA(isA<NativeCryptoException>()));
      expect(() => recipient.k2Importing(id, now: 110),
          throwsA(isA<NativeCryptoException>()));
      expect(() => source.k2SourcePosted(id, now: 110),
          throwsA(isA<NativeCryptoException>()));
      expect(recipient.k2Forget(id), isTrue);
      expect(recipient.k2Forget(id), isFalse);
      expect(source.k2Expire(now: deadline), 1);
    } finally {
      source.close();
      recipient.close();
    }
  }, skip: skip);

  test('ABI8 rejects invalid fields, roles and substituted key package', () {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final source = bindings.createDevice('account', 'source');
    final recipient = bindings.createDevice('account', 'recipient');
    const id = K2TransferId('https://example.test', 'link');
    final context = K2LinkContext(
        id: id,
        accountId: 'account',
        nonce: List<int>.filled(32, 9),
        sourceDeviceId: 'source',
        sourceSigningKey: source.signingPublicKey(),
        recipientDeviceId: 'recipient',
        recipientSigningKey: recipient.signingPublicKey(),
        transferPublicKey: List<int>.filled(32, 0),
        sourceCommitment: List<int>.filled(32, 3),
        recipientRandom: List<int>.filled(32, 0));
    try {
      // A zero commitment is never accepted; nor is a zero random to commit.
      expect(
          () => recipient.k2ReceiveBegin(
              K2LinkContext(
                  id: id,
                  accountId: 'account',
                  nonce: List<int>.filled(32, 9),
                  sourceDeviceId: 'source',
                  sourceSigningKey: source.signingPublicKey(),
                  recipientDeviceId: 'recipient',
                  recipientSigningKey: recipient.signingPublicKey(),
                  transferPublicKey: List<int>.filled(32, 0),
                  sourceCommitment: List<int>.filled(32, 0),
                  recipientRandom: List<int>.filled(32, 0)),
              List<int>.filled(16, 8),
              originalExpiresAt: 1000,
              now: 100),
          throwsA(isA<NativeCryptoException>()));
      expect(
          () => source.k2SourceCommitment(
              'https://example.test', List<int>.filled(32, 0)),
          throwsA(isA<NativeCryptoException>()));
      expect(
          () => recipient.k2ReceiveBegin(context, [],
              originalExpiresAt: 1000, now: 100),
          throwsArgumentError);
      recipient.k2ReceiveBegin(context, List<int>.filled(16, 8),
          originalExpiresAt: 1000, now: 100);
      expect(() => recipient.k2SourceConfirm(id, '12345678', now: 100),
          throwsA(isA<NativeCryptoException>()));
      expect(
          () => recipient.k2EnrollmentProof(id,
              now: 100,
              locator: List.filled(64, 'a').join(),
              reservationRequestId: List<int>.filled(32, 0x11),
              deviceName: 'Phone',
              challenge: [1],
              keyPackage: source.createKeyPackage(),
              claimTokenHash: List<int>.filled(32, 0x77),
              deviceSecretHash: List<int>.filled(32, 0x88),
              initialSessionHash: List<int>.filled(32, 0x99)),
          throwsA(isA<NativeCryptoException>()));
      expect(() => recipient.k2Inspect(id, now: -1), throwsArgumentError);
      recipient.close();
      expect(() => recipient.k2Inspect(id, now: 100), throwsStateError);
    } finally {
      source.close();
      recipient.close();
    }
  }, skip: skip);
}
