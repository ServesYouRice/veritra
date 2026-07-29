import '../core/models.dart';

class ConversationSafetyNumber {
  const ConversationSafetyNumber({
    required this.digits,
    required this.transcriptHash,
    required this.qrPayload,
  });
  final String digits;
  final List<int> transcriptHash;
  final String qrPayload;
}

class EncryptedCallSignal {
  const EncryptedCallSignal(this.metadata);
  final Map<String, Object?> metadata;
}

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

abstract class MlsConversationCryptoService implements CryptoService {
  Future<void> activateSession(Session session);
  Future<List<List<int>>> createReplenishmentKeyPackages({int count = 5});
  Future<void> initializeConversation(
    String conversationId,
    List<DeviceKeyPackage> claimedPackages,
  );
  Future<void> processMlsMessage(MlsMessage message);
  Future<void> createRevocationCommit(MlsRevocation revocation);
  Future<ConversationSafetyNumber> conversationSafetyNumber(
      String conversationId);
  Future<EncryptedCallSignal> encryptCallSignal(
      String conversationId, Map<String, Object?> signal);
  Future<Map<String, Object?>?> processCallSignal(
      CallSession call, int syncEventId);
  Future<List<int>?> processApplicationMessage(
    ReceivedMessageEnvelope envelope,
    int syncEventId,
  );
  Future<void> dispose();
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
