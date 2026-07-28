import '../core/models.dart';

abstract class CryptoService {
  Future<EnrollmentCredential> createEnrollmentCredential(
      EnrollmentReservation reservation);
  Future<MessageEnvelope> encrypt(String conversationId, String plaintext);
  Future<DeviceLinkVerification> deriveDeviceLinkVerification({
    required String accountId,
    required String protocolVersion,
    required List<int> linkNonce,
    required String peerDeviceId,
    required List<int> peerSigningKey,
    required bool localIsExistingDevice,
  });
}

class UnavailableCryptoService implements CryptoService {
  @override
  Future<EnrollmentCredential> createEnrollmentCredential(
      EnrollmentReservation reservation) async {
    throw StateError(
        'Production MLS/OpenMLS enrollment signing is not integrated');
  }

  @override
  Future<MessageEnvelope> encrypt(
      String conversationId, String plaintext) async {
    throw StateError('Production MLS/OpenMLS encryption is not integrated');
  }

  @override
  Future<DeviceLinkVerification> deriveDeviceLinkVerification({
    required String accountId,
    required String protocolVersion,
    required List<int> linkNonce,
    required String peerDeviceId,
    required List<int> peerSigningKey,
    required bool localIsExistingDevice,
  }) async {
    throw StateError('Production device-link SAS is not integrated');
  }
}
