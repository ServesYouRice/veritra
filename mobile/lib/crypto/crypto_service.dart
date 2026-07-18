import '../core/models.dart';

abstract class CryptoService {
  Future<EnrollmentCredential> createEnrollmentCredential(
      EnrollmentReservation reservation);
  Future<MessageEnvelope> encrypt(String conversationId, String plaintext);
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
}
