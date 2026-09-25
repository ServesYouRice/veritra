import '../core/models.dart';
import '../storage/local_store.dart' show PendingMlsMessage;
import 'mls_commit_bundle.dart';
import 'app_payload.dart';

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

  /// Stages one commit adding [adds] and removing [removes] and queues it as
  /// a commit bundle (card I51). The commit is merged only once the server
  /// accepts it.
  Future<void> stageMembershipChange(
    String conversationId, {
    List<DeviceKeyPackage> adds,
    List<MlsDeviceRef> removes,
  });

  /// The server accepted the queued commit [bundle]: merge it and remove the
  /// outbox item in one step.
  Future<void> completeCommitBundle(PendingMlsMessage bundle);

  /// The server refused the queued commit [bundle] (another commit won):
  /// drop the staged commit and the outbox item in one step.
  Future<void> abandonCommitBundle(PendingMlsMessage bundle);

  /// The local epoch of a group and whether a staged commit waits, or null
  /// when this device has no such group.
  Future<({int epoch, bool pending})?> groupEpoch(String conversationId);
  Future<ConversationSafetyNumber> conversationSafetyNumber(
      String conversationId);
  Future<EncryptedCallSignal> encryptCallSignal(
      String conversationId, Map<String, Object?> signal);
  Future<Map<String, Object?>?> processCallSignal(
      CallSession call, int syncEventId);

  /// [attachmentRefs] names the uploaded ciphertext blobs the message
  /// refers to, so the server expires them with it.
  Future<MessageEnvelope> encryptPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    List<String> attachmentRefs = const <String>[],
  });
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
