import 'dart:typed_data';

import '../core/models.dart';
import '../core/roles/governance.dart' show GovernanceState;
import '../core/roles/governance_commands.dart'
    show GovernanceCommands, GovernanceObservations;
import '../storage/encrypted_database.dart'
    show EnrollmentPromotionOutcome, HistoryTransferProgress;
import '../storage/local_store.dart' show PendingMlsMessage, StoredCryptoState;
import '../core/device_lists.dart' show DeviceListPins, DeviceListVerifier;
import 'mls_commit_bundle.dart';
import 'native_crypto_bindings.dart'
    show BackupHeaderInfo, DeviceListBody, DeviceListPair, OpenedBackup;
import 'app_payload.dart';
import 'community_info_codec.dart' show CommunityInfoCodec;
import 'profile_record_codec.dart' show ProfileRecordCodec;

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
  // The v2 link derivation was retired with ABI 18 (L1-3): device links run
  // on K2TransferCryptoService, whose SAS needs the source's committed random.

  /// The verified role record for [conversationId], if this service holds one
  /// (C4, ABI 20). Returns null without a record or when not supported.
  GovernanceState? governanceOf(String conversationId) => null;
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

/// The L1 approved-device list (D94) through the native engine. Only an
/// engine that does real MLS implements it, and that engine gates every add
/// and judges every leaf against [deviceListPins]: until they are set, it
/// stages no add and judges every leaf as "checking" (fail closed).
abstract interface class DeviceListCryptoService implements DeviceListVerifier {
  /// The pins the add gate and the leaf judge use. Set by the app once the
  /// session's API and store are known; null again on sign-out.
  set deviceListPins(DeviceListPins? pins);

  /// Signs [body] as this device and returns the whole statement. Works for
  /// a pending enrollment too, so a genesis can travel with setup or
  /// registration.
  Future<Uint8List> signDeviceList(DeviceListBody body);

  /// The current (possibly pending) device's MLS signing key.
  Future<Uint8List> currentSigningKey();

  /// Keeps the recovery list seed derived from [entropy] in the sealed
  /// pending enrollment (K0-R claim, D94 question 1).
  Future<void> holdRecoveryListSeed(Uint8List entropy);

  /// Signs change 4 from the held seed, or from [entropy] when given.
  Future<Uint8List> signRecoveryDeviceList({
    required List<int> prev,
    required DeviceListBody body,
    required List<DeviceListPair> history,
    Uint8List? entropy,
  });

  /// Drops a held recovery list seed. Returns whether one was held.
  Future<bool> dropRecoveryListHold();

  /// Whether [conversationId] is held because one of its leaves is not
  /// approved now (judging it again first). While held, nothing is
  /// encrypted to it; a removal may still be committed.
  Future<bool> refreshApprovalHold(String conversationId);
}

/// Discovers additions independently of the server's device enumeration.
abstract interface class ApprovedDeviceDiscoveryCryptoService {
  /// Lists currently approved devices of member [accountIds] absent from the
  /// actual MLS tree. Null [conversationId] means a new group with only self.
  Future<List<MlsDeviceRef>> missingApprovedDevices(
      String? conversationId, Iterable<String> accountIds);
}

/// A membership change named only devices that are not on their accounts'
/// approved-device lists now (L1, D94). Nothing was staged; the change stays
/// pending and is offered again.
class DeviceListNotApprovedException implements Exception {
  const DeviceListNotApprovedException(this.deviceIds);
  final List<String> deviceIds;

  @override
  String toString() => 'DeviceListNotApprovedException';
}

/// Encryption to a conversation was refused because one of its devices is
/// not on its account's approved-device list (the approval hold, D94).
class ConversationApprovalHeldException implements Exception {
  const ConversationApprovalHeldException(this.conversationId);
  final String conversationId;

  @override
  String toString() => 'ConversationApprovalHeldException';
}

/// Whether the native device handle still answers (C1 prerequisite 1).
/// After one conversation's event fails and its group is restored, sync
/// pauses only that conversation; if the handle itself is gone (a failed
/// restore, a poisoned native lock) every conversation would fail next, so
/// the caller stops the whole device instead.
abstract interface class MlsDeviceHealthCryptoService {
  Future<bool> deviceHandleUsable();
}

/// The public values derived from a K0 recovery key (ABI 11). [rkPub] is
/// kept for K1 and never sent; [rkAuthPub] and [rkId] are what
/// `PUT /api/v1/account/recovery-key` takes.
class RecoveryKeyValues {
  const RecoveryKeyValues({
    required this.rkPub,
    required this.rkId,
    required this.rkAuthPub,
    this.rkListPub,
  });

  final Uint8List rkPub;
  final Uint8List rkId;
  final Uint8List rkAuthPub;

  /// The L1 recovery signer's public key (ABI 14), which a change-5 version
  /// puts on the account's approved-device list. Null from an engine
  /// without L1.
  final Uint8List? rkListPub;
}

/// K1 automatic backups (ABI 19): seals a history snapshot to the
/// account's recovery key as a VHC1 kind-1 container. The file key is fresh
/// per backup and never leaves the engine; padding is applied inside.
abstract interface class BackupSealCryptoService {
  /// The sealed container. [plaintext] belongs to the caller, who wipes it.
  Future<Uint8List> sealK1Backup({
    required String accountId,
    required String sourceDeviceId,
    required int createdAtMs,
    required int counter,
    required Uint8List rkPub,
    required Uint8List plaintext,
  });

  /// The largest snapshot [sealK1Backup] takes.
  int get k1BackupMaxPlaintextBytes;
}

/// Reading a K1 backup (K1-4). Kept apart from [BackupSealCryptoService] so a
/// build that can only seal, and every test fake, stays as it is.
abstract interface class BackupOpenCryptoService {
  /// The unauthenticated header from the first 416 bytes of a container.
  BackupHeaderInfo peekK1Backup(Uint8List prefix);

  /// Opens a container with the typed recovery key [entropy] (the caller
  /// wipes it). [sourceDeviceId] pins the device the server row names.
  /// The caller wipes [OpenedBackup.plaintext].
  Future<OpenedBackup> openK1Backup({
    required Uint8List ciphertext,
    required Uint8List entropy,
    required String accountId,
    String? sourceDeviceId,
  });
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

/// The public signing key of this device's MLS credential (the one the server
/// holds as the device's `signing_key`). C1 binds an invitation to it (D90),
/// and the binding is checked against the key the server registered. Reads
/// the existing `pm_crypto_device_signing_public_key`; no signing happens.
/// Callers check for it like the other capabilities, so
/// [UnavailableCryptoService] (`PM_CRYPTO_UNAVAILABLE`) is never asked.
abstract interface class DeviceSigningKeyCryptoService {
  /// The 32-byte Ed25519 public key of the active device, which must be
  /// [accountId]/[deviceId]; any other active identity throws.
  Future<Uint8List> deviceSigningPublicKey({
    required String accountId,
    required String deviceId,
  });
}

/// The signing domain of invitation binding v2 (C1, ABI 13 allowlist entry).
/// The native side prepends it to the message; the app never builds
/// `domain | message` itself.
const String inviteBindingSigningDomain = 'veritra-invite-binding-v2';

/// C1 invitation binding v2 (`docs/designs/C1-invite-format.md`): the device
/// signature on an invitation and its check, through the ABI 13 credential-key
/// sign and verify, plus the roster read that anchors the key. Implemented by
/// the native engine only; callers check for it like the other capabilities,
/// so [UnavailableCryptoService] (`PM_CRYPTO_UNAVAILABLE`) is never asked and a
/// build without the engine neither makes nor accepts an invitation.
abstract interface class InviteBindingCryptoService {
  /// Signs [message] under [inviteBindingSigningDomain] with the active
  /// device's credential key (64 bytes). The active identity must be
  /// [accountId]/[deviceId]; any other throws.
  Future<Uint8List> signInviteBinding({
    required String accountId,
    required String deviceId,
    required List<int> message,
  });

  /// Strict Ed25519 verification of [signature] over [message] under
  /// [inviteBindingSigningDomain] and the 32-byte [signingKey]. `false` for
  /// any invalid signature or malformed key, and also when the engine does not
  /// know the domain (an older library), so the caller fails closed.
  Future<bool> verifyInviteBinding({
    required List<int> signingKey,
    required List<int> message,
    required List<int> signature,
  });

  /// The signature key of the member device [accountId]/[deviceId] in the
  /// current tree of the MLS group of [conversationId] on this device, or
  /// null when this device holds no such group or the group has no such
  /// member. Reads local MLS state only; the server is not asked.
  Future<Uint8List?> memberSigningKey({
    required String conversationId,
    required String accountId,
    required String deviceId,
  });
}

/// K2/K0 (local schema 18): the one step that makes the pending identity
/// this device's active one, with a promotion-ledger row, so its frozen
/// pre-join MLS state can never become active again (review finding 4 on
/// schema 17). Implemented by the native engine only; callers check for it
/// like the other capabilities.
abstract interface class EnrollmentPromotionCryptoService {
  /// Promotes the pending enrollment of [kind] this service holds open
  /// (after [RecoveryCryptoService.resumePendingEnrollment] or a fresh
  /// enrollment) as [session], in one local transaction. [promotionId] is
  /// the K2 claim request digest or the K0 request ID; a retry with the
  /// same one after a lost outcome answers
  /// [EnrollmentPromotionOutcome.alreadyPromoted] and opens the stored
  /// state, never the frozen one. [transfer] is an incoming K2 transfer to
  /// start with the identity.
  Future<EnrollmentPromotionOutcome> promotePendingEnrollment(
    Session session, {
    required String kind,
    required String promotionId,
    HistoryTransferProgress? transfer,
  });
}

/// C6 reports (docs/designs/C6-reports-franking.md, D80): the HPKE seal a
/// report travels in, sealed to the recipient's key so the server carries
/// ciphertext only, and the franking commitment that proves a reported
/// message. Kept apart from [CryptoService] so a build without the native
/// library is never asked: [UnavailableCryptoService] implements it only to
/// refuse. Nothing here stores, sends or logs a seed, a report or a payload.
abstract interface class ReportCryptoService {
  /// A fresh 32-byte report key seed. The caller owns it, keeps it only in
  /// protected storage and wipes every copy once used.
  Future<Uint8List> generateReportKeySeed();

  /// The 32-byte X25519 report public key for [seed].
  Future<Uint8List> reportPublicKey(Uint8List seed);

  /// Seals [plaintext] to [recipientPublicKey] with [aad] bound.
  Future<Uint8List> sealReport({
    required List<int> recipientPublicKey,
    required List<int> aad,
    required Uint8List plaintext,
  });

  /// Opens [sealed] with [seed]; throws unless it is unaltered and [aad]
  /// matches. The caller wipes the result.
  Future<Uint8List> openReport({
    required Uint8List seed,
    required List<int> aad,
    required List<int> sealed,
  });

  /// The franking commitment over the canonical payload bytes [payload]
  /// (`docs/crypto.md`, "Franking v1").
  Future<Uint8List> frankCommit({
    required Uint8List key,
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
    required Uint8List payload,
  });
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

/// Sends into one channel of a community's shared group (C0). Kept apart
/// from [MlsConversationCryptoService.encryptPayload] so that method, which
/// every other conversation uses, does not change. The channel and the layout
/// generation go into the clear envelope metadata (the server routes by them)
/// and the channel again into the encrypted payload (the receiver checks it).
abstract interface class ChannelRoutedCryptoService {
  Future<MessageEnvelope> encryptChannelPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    required String channelId,
    required int layoutGeneration,
    List<String> attachmentRefs = const <String>[],
    String? draftText,
  });
}

/// A crypto service that can put the sender's own expiry inside the encrypted
/// payload (TASK-106). The expiry is the sender's signed word for when a
/// disappearing message ends; receivers use the shorter of it and the
/// server-stamped time. A service without this keeps sending payloads with no
/// expiry, and receivers then trust the server time as before. [channelId]
/// and [layoutGeneration] are given exactly for a post in a shared group, as
/// for [ChannelRoutedCryptoService].
abstract interface class ExpiringPayloadCryptoService {
  Future<MessageEnvelope> encryptExpiringPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    required DateTime expiresAt,
    String? channelId,
    int? layoutGeneration,
    List<String> attachmentRefs = const <String>[],
    String? draftText,
  });
}

/// C3: seals and opens community info records. Only the native service
/// offers it, so the app never names that service directly.
abstract interface class CommunityInfoCryptoService {
  CommunityInfoCodec get communityInfoCodec;
}

/// The accounts in a conversation's MLS group, read from the group's own
/// tree (never the server's member list). Null when the group is unknown.
/// C3 uses it to tell when no owner or admin is in a private channel.
abstract interface class MlsRosterSource {
  Set<String>? groupMemberAccounts(String conversationId);
}

/// W11: the service that owns the native library also hands out the profile
/// record codec, which seals records with the library's chunk AEAD. A build
/// without it has no profiles.
abstract interface class ProfileCodecSource {
  ProfileRecordCodec get profileCodec;
}

abstract interface class ConversationAuthorityConsumer {
  set conversationAuthority(ConversationAuthority authority);
}

/// The community a conversation belongs to (C7 signs it into every post).
/// An authority that is not one leaves C7 off.
abstract interface class ConversationCommunitySource {
  String? conversationCommunity(String conversationId);

  /// The private channel whose own group (C0 layout) is [conversationId], or
  /// null (a shared group, a legacy channel, or anything else). With C7 on,
  /// that group's posts name the channel in their envelope metadata, so the
  /// server applies slow mode and admins-only posting to them.
  String? privateGroupChannel(String conversationId);
}

/// C7 (docs/designs/C7-channel-history.md): off by default. AppState turns
/// it on when the server reports `c7_history` (PRIVATE_MESSENGER_C7_HISTORY),
/// and then every application message in a community conversation is sent
/// as an MLS reference plus a sealed body. Receiving two-part messages needs
/// no switch.
abstract interface class C7HistoryConsumer {
  bool get c7SealedBodies;
  set c7SealedBodies(bool enabled);
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

/// Fails closed: no recovery key, proof, pending identity, report key, sealed
/// report or franking commitment exists without the reviewed native engine
/// (`PM_CRYPTO_UNAVAILABLE`).
class UnavailableCryptoService
    implements CryptoService, RecoveryCryptoService, ReportCryptoService {
  static Never _recoveryUnavailable() =>
      throw StateError('Account recovery is unavailable');
  static Never _reportsUnavailable() =>
      throw StateError('Reporting is unavailable');

  @override
  Future<Uint8List> generateReportKeySeed() async => _reportsUnavailable();
  @override
  Future<Uint8List> reportPublicKey(Uint8List seed) async =>
      _reportsUnavailable();
  @override
  Future<Uint8List> sealReport({
    required List<int> recipientPublicKey,
    required List<int> aad,
    required Uint8List plaintext,
  }) async =>
      _reportsUnavailable();
  @override
  Future<Uint8List> openReport({
    required Uint8List seed,
    required List<int> aad,
    required List<int> sealed,
  }) async =>
      _reportsUnavailable();
  @override
  Future<Uint8List> frankCommit({
    required Uint8List key,
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
    required Uint8List payload,
  }) async =>
      _reportsUnavailable();

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
  GovernanceState? governanceOf(String conversationId) => null;
}

/// C4: a group's verified role record with the MLS account roster it was
/// read with and this device's own clocks for it.
class GovernanceView {
  const GovernanceView({
    required this.record,
    required this.roster,
    required this.observations,
  });

  final GovernanceState record;
  final Set<String> roster;
  final GovernanceObservations? observations;
}

/// A remote commit the C4 rules refuse (docs/crypto.md, "C4 app wiring"). It
/// is an invalid MLS control message: the conversation pauses on it (I33).
class GovernanceRefusedException implements Exception {
  const GovernanceRefusedException(this.reason);
  final String reason;
  @override
  String toString() => 'GovernanceRefusedException($reason)';
}

/// This device cannot prove the departure of a governing account its
/// change would remove; the removal stays pending for a device that can.
class GovernanceRemovalUnprovenException implements Exception {
  const GovernanceRemovalUnprovenException(this.conversationId);
  final String conversationId;
  @override
  String toString() => 'GovernanceRemovalUnprovenException';
}

/// C4 role commands: role-only commits built by [GovernanceCommands] from the
/// group's current record and MLS roster, queued like any staged commit.
abstract interface class RoleCommandCryptoService {
  /// The record, roster and clocks of [groupId], or null without a record.
  Future<GovernanceView?> governanceView(String groupId);

  /// Builds the next record with [build] (which throws
  /// `GovernanceCommandException` to refuse) and stages it as a commit.
  Future<void> stageRoleChange(
    String groupId,
    GovernanceState Function(GovernanceCommands commands,
            GovernanceObservations? observed, DateTime now)
        build,
  );
}
