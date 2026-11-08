import 'dart:typed_data';

import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';

/// The device signing key [TestOnlyCryptoService] reports (32 bytes).
final Uint8List testDeviceSigningKey =
    Uint8List.fromList(List<int>.generate(32, (i) => 0x20 + i));

class TestOnlyCryptoService
    implements CryptoService, DeviceSigningKeyCryptoService {
  // Windows clocks tick coarsely, so a timestamp alone repeats within a test.
  static int _keySequence = 0;

  @override
  Future<EnrollmentCredential> createEnrollmentCredential(
      EnrollmentReservation reservation) async {
    return EnrollmentCredential(
      deviceKeyPackage: 'TEST_ONLY_DEVICE_KEY_PACKAGE'.codeUnits,
      signingKey: List<int>.filled(32, 1),
      challengeSignature: List<int>.filled(64, 2),
    );
  }

  @override
  Future<MessageEnvelope> encrypt(
      String conversationId, String plaintext) async {
    return MessageEnvelope(
      conversationId: conversationId,
      idempotencyKey:
          '${DateTime.now().microsecondsSinceEpoch}-${_keySequence++}',
      ciphertext: 'TEST_ONLY_CIPHERTEXT_LEN:${plaintext.length}'.codeUnits,
      cryptoProtocol: 'test-only-not-production',
      cryptoMetadata: const <String, Object?>{
        'warning': 'not-production-crypto'
      },
    );
  }

  @override
  Future<Uint8List> deviceSigningPublicKey({
    required String accountId,
    required String deviceId,
  }) async =>
      Uint8List.fromList(testDeviceSigningKey);

  @override
  Future<String> deviceLinkLocator(List<int> secret) async => "a" * 64;
}
