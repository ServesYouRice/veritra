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
  Future<String> deviceLinkLocator(List<int> secret);
  Future<EnrollmentCredential> createEnrollmentCredential(
      EnrollmentReservation reservation);
  Future<MessageEnvelope> encrypt(String conversationId, String plaintext);
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
  /// [draftText] is the original composer text, before formatting markers
  /// are stripped. It stays local and clears that draft atomically with send.
  Future<MessageEnvelope> encryptPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    List<String> attachmentRefs = const <String>[],
    String? draftText,
  });
  Future<List<int>?> processApplicationMessage(
    ReceivedMessageEnvelope envelope,
    int syncEventId,
  );
  Future<void> dispose();
}

/// Inbound-only operations authorized by one short-lived background permit.
/// The captured synchronous fence is checked at native mutation boundaries
/// and by the same atomic storage transaction. It must throw when ownership
/// or the permit has ended; callers still drain that transaction normally.
abstract interface class BoundedMlsConversationCryptoService
    implements MlsConversationCryptoService {
  Future<void> activateExistingSessionBounded(Session session,
      {required void Function() checkCanCommit});
  Future<void> processMlsMessageBounded(MlsMessage message,
      {required void Function() checkCanCommit});
  Future<List<int>?> processApplicationMessageBounded(
      ReceivedMessageEnvelope envelope, int syncEventId,
      {required void Function() checkCanCommit});
  Future<Map<String, Object?>?> processCallSignalBounded(
      CallSession call, int syncEventId,
      {required void Function() checkCanCommit});
}

/// Cached server roles today; C4 will replace this source with encrypted roles.
abstract interface class ConversationAuthority {
  String? roleOf(String conversationId, String accountId);
  Set<String> memberAccounts(String conversationId);
  String? conversationKind(String conversationId);
  String? conversationChannel(String conversationId);
}

abstract interface class ConversationAuthorityConsumer {
  set conversationAuthority(ConversationAuthority authority);
}

/// Off by default. AppState enables this only for the current verified
/// subscription's local-decryption capability. The service freezes the grant
/// for each queued inbound operation, never enabling capture halfway through.
abstract interface class NoticeCaptureConsumer {
  bool get noticeCaptureEnabled;
  set noticeCaptureEnabled(bool enabled);
}

/// A local owner/capability ended before commit. Retrying under the current
/// owner is safe; this is not evidence of a malformed or undecryptable message.
class CryptoOperationCancelled implements Exception {
  const CryptoOperationCancelled();
  @override
  String toString() => 'crypto operation ownership changed';
}

/// The protected MLS state on this device was sealed in a format this build
/// cannot read (ABI 9 `PM_CRYPTO_STATE_FORMAT_UNSUPPORTED`). The state stays
/// refused; linking the device again is the way forward. The format version
/// is not authenticated, so this never relaxes a check.
class CryptoStateFormatUnsupported implements Exception {
  const CryptoStateFormatUnsupported();
  @override
  String toString() => 'protected MLS state format is unsupported';
}

class UnavailableCryptoService implements CryptoService {
  @override
  Future<String> deviceLinkLocator(List<int> secret) async =>
      throw StateError("Device linking is unavailable");
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
    required String serverOrigin,
    required String linkId,
    required List<int> linkSecret,
    required List<int> linkNonce,
    required String peerDeviceId,
    required List<int> peerSigningKey,
    required bool localIsExistingDevice,
  }) async {
    throw StateError('Production device-link SAS is not integrated');
  }
}
