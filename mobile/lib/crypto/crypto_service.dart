import 'dart:typed_data';

import '../core/models.dart';
import '../storage/local_store.dart' show PendingMlsMessage, StoredCryptoState;
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

/// Periodic MLS self-update (docs/crypto.md, change log 2026-10-31). Kept
/// apart from [MlsConversationCryptoService] so a service that cannot
/// refresh keys is simply never asked to.
abstract interface class MlsSelfUpdateCryptoService {
  /// Stages one commit that adds and removes no one and gives this device's
  /// leaf a fresh key in [conversationId], and queues it as an update-only
  /// commit bundle. Like every staged commit (D28) it is merged only once
  /// the server accepts it, and dropped when the server refuses it.
  Future<void> stageSelfUpdate(String conversationId);
}

/// Upkeep of the stored MLS state (D70 S4). Kept apart from
/// [MlsConversationCryptoService] so a service without per-group state is
/// simply never asked.
abstract interface class MlsStateMaintenanceCryptoService {
  /// Drops key packages that expired more than 24 hours before [now] and
  /// stores the change. Returns how many went.
  Future<int> pruneExpiredKeyPackages(DateTime now);

  /// Drops this device's state for [conversationId] and settles that
  /// conversation's queued MLS control messages. Only the user's own leave
  /// or delete may call this, never a server event (docs/crypto.md,
  /// "Rejoining a conversation"). Returns whether a group was stored.
  Future<bool> deleteConversationState(String conversationId);
}

/// The public values derived from a K0 recovery key (ABI 11). [rkPub] is
/// kept for K1 and never sent; [rkAuthPub] and [rkId] are what
/// `PUT /api/v1/account/recovery-key` takes.
class RecoveryKeyValues {
  const RecoveryKeyValues({
    required this.rkPub,
    required this.rkId,
    required this.rkAuthPub,
  });

  final Uint8List rkPub;
  final Uint8List rkId;
  final Uint8List rkAuthPub;
}

/// K0 recovery (docs/designs/K0-recovery-enrollment.md, R3/R4). Kept apart
/// from [CryptoService] so a build without the native library is simply
/// never asked: [UnavailableCryptoService] implements it only to refuse.
///
/// Every [Uint8List] of recovery key entropy belongs to the caller, who
/// wipes it once used. Nothing here stores or logs a key.
abstract interface class RecoveryCryptoService {
  /// Fresh 30-byte recovery key entropy from the OS RNG.
  Future<Uint8List> generateRecoveryKey();

  /// The canonical 52-character display of [entropy].
  Future<String> encodeRecoveryKey(Uint8List entropy);

  /// Decodes typed key text (already normalised) to its entropy. A typo
  /// throws, before any network call.
  Future<Uint8List> decodeRecoveryKey(String text);

  Future<RecoveryKeyValues> deriveRecoveryKey(Uint8List entropy);

  /// The recovery proof for a claim, over [origin], the canonical origin
  /// the app uses for this server.
  Future<Uint8List> signRecoveryProof({
    required Uint8List entropy,
    required List<int> challenge,
    required List<int> signingKey,
    required List<int> keyPackage,
    required String origin,
  });

  /// Seals the identity [CryptoService.createEnrollmentCredential] just
  /// made, once, so a recovery claim can wait days and survive a restart.
  /// The same state is what activation later stores.
  Future<StoredCryptoState> sealPendingEnrollment();

  /// Opens [state] (from [sealPendingEnrollment]) as the pending identity of
  /// [accountId]/[deviceId], ready for activation.
  Future<void> resumePendingEnrollment({
    required String accountId,
    required String deviceId,
    required StoredCryptoState state,
  });

  /// Drops a pending (not yet activated) enrollment identity.
  Future<void> abandonPendingEnrollment();
}

/// A change would make one sealed record of the MLS state larger than its
/// cap (D70, native `PM_CRYPTO_RECORD_LIMIT`). Nothing was stored and the
/// operation was rolled back. [conversationId] names the conversation when
/// the record is its group; null for the device record or a key package.
class CryptoRecordLimitExceeded implements Exception {
  const CryptoRecordLimitExceeded({this.conversationId});
  final String? conversationId;
  @override
  String toString() => 'encrypted state record is over its size limit';
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

/// Fails closed: no recovery key, proof or pending identity exists without
/// the reviewed native engine (`PM_CRYPTO_UNAVAILABLE`).
class UnavailableCryptoService implements CryptoService, RecoveryCryptoService {
  static Never _recoveryUnavailable() =>
      throw StateError('Account recovery is unavailable');

  @override
  Future<Uint8List> generateRecoveryKey() async => _recoveryUnavailable();
  @override
  Future<String> encodeRecoveryKey(Uint8List entropy) async =>
      _recoveryUnavailable();
  @override
  Future<Uint8List> decodeRecoveryKey(String text) async =>
      _recoveryUnavailable();
  @override
  Future<RecoveryKeyValues> deriveRecoveryKey(Uint8List entropy) async =>
      _recoveryUnavailable();
  @override
  Future<Uint8List> signRecoveryProof({
    required Uint8List entropy,
    required List<int> challenge,
    required List<int> signingKey,
    required List<int> keyPackage,
    required String origin,
  }) async =>
      _recoveryUnavailable();
  @override
  Future<StoredCryptoState> sealPendingEnrollment() async =>
      _recoveryUnavailable();
  @override
  Future<void> resumePendingEnrollment({
    required String accountId,
    required String deviceId,
    required StoredCryptoState state,
  }) async =>
      _recoveryUnavailable();
  @override
  Future<void> abandonPendingEnrollment() async {}

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
