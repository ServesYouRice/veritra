import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';

class TestOnlyCryptoService implements CryptoService {
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
      idempotencyKey: DateTime.now().microsecondsSinceEpoch.toString(),
      ciphertext: 'TEST_ONLY_CIPHERTEXT_LEN:${plaintext.length}'.codeUnits,
      cryptoProtocol: 'test-only-not-production',
      cryptoMetadata: const <String, Object?>{
        'warning': 'not-production-crypto'
      },
    );
  }

  @override
  Future<String> deviceLinkLocator(List<int> secret) async => "a" * 64;

  @override
  Future<DeviceLinkVerification> deriveDeviceLinkVerification({
    required String accountId,
    required String protocolVersion,
    required String serverOrigin,
    required String linkId,
    required List<int> linkSecret,
    required List<int> linkNonce,
    required String peerDeviceId,
    required List<int> peerSigningKey,
    required bool localIsExistingDevice,
  }) async {
    return DeviceLinkVerification(
      transcriptHash: List<int>.filled(32, 7),
      sas: '65432101',
      claimTag: List<int>.filled(32, 8),
      approvalTag: List<int>.filled(32, 9),
    );
  }
}
