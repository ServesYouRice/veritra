import '../core/device_link_v3_models.dart' show deviceLinkV3Id;
import '../storage/encrypted_database.dart' show HistoryTransferProgress;
import 'native_crypto_bindings.dart';

/// The plaintext version both ends pass to the native bundle: the
/// `HistorySnapshot` JSON version (`storage/history_snapshot.dart`). The
/// native header binds it, so a recipient that expects another version
/// refuses the bundle before any plaintext is released.
const int k2HistoryPlaintextVersion = 1;

/// The reason of the [K2TransferException] for a transfer the server no
/// longer holds as an active copy (cancelled, expired, revoked or gone). The
/// copy is over: the caller abandons it.
const String k2ServerClosedReason = 'the server closed this copy';

/// A K2 transfer step that must not happen. [reason] is fixed text: it never
/// carries a key, a token, a handoff or any history.
class K2TransferException implements Exception {
  const K2TransferException(this.reason);
  final String reason;

  @override
  String toString() => 'K2 transfer refused: $reason';
}

/// Refuses a link ID outside the v3 ID alphabet (`[A-Za-z0-9_-]{1,128}`)
/// before it can name a file: the ID comes from the server and the link QR,
/// and that alphabet holds no separator, dot or drive colon.
String k2RequireLinkId(String linkId) {
  try {
    return deviceLinkV3Id(linkId);
  } on FormatException {
    throw const K2TransferException('the link ID is not valid');
  }
}

/// K2 history transfer on the native crypto engine (ABI 8 controls and bundle
/// streams, schema-18 tables; no native change).
///
/// Every method that mutates native transfer state runs in the service's
/// serial queue and stores the sealed state, with the transfer progress row
/// where one changes, in one expected-counter transaction (the sync cursor
/// does not move). A failed commit restores the committed state, so no
/// result reaches HTTP or a caller without its durable record. No method
/// does HTTP: the caller (`HistoryTransferService`) sequences the two.
///
/// Native streams are opened and closed inside one method, never held
/// across calls: a restore replaces the native device and kills them.
abstract interface class K2TransferCryptoService {
  // --- Recipient, while its enrollment is pending (before promotion) ---

  /// Creates the incoming transfer key. It must run before the first seal of
  /// the pending state (`sealPendingEnrollment`),
  /// whose frozen state then holds the record; afterwards it is refused,
  /// because the pending state cannot change (no schema change needed).
  Future<K2ReceiveResult> k2ReceiveBegin(
      K2LinkContext context, List<int> secret,
      {required int originalExpiresAt});

  /// Signs the v3 claim over the stored context. Reads native state only.
  Future<K2ProofResult> k2EnrollmentProof(K2TransferId id,
      {required String locator,
      required List<int> reservationRequestId,
      required String deviceName,
      required List<int> challenge,
      required List<int> keyPackage,
      required List<int> claimTokenHash,
      required List<int> deviceSecretHash,
      required List<int> initialSessionHash});

  /// Checks the approval tag of a waiting link against the stored context
  /// before the new device completes at the server, without changing any
  /// state: the pending state is frozen, so the check runs on a scratch copy
  /// of it that is dropped at once. False only when native rejects the tag
  /// or time; anything else passes through.
  Future<bool> k2VerifyPendingApproval(K2TransferId id, List<int> approvalTag,
      {required int approvedAt});

  // --- Both roles ---

  /// Reads the native record (pending or active identity). Never mutates.
  Future<K2Status> k2Inspect(K2TransferId id);

  /// Verifies the approval tag and fixes the transfer deadline (returned,
  /// epoch milliseconds). The recipient runs it after promotion as the first
  /// active commit; the source after its approval POST.
  Future<int> k2ApplyApproval(K2TransferId id, List<int> approvalTag,
      {required int approvedAt});

  // --- Source ---

  /// Accepts the claim and returns the SAS to show. Committed first.
  Future<K2Verification> k2SourceAccept(K2LinkContext context, List<int> secret,
      {required int originalExpiresAt,
      required List<int> transcriptHash,
      required List<int> claimTag});

  /// Confirms the typed SAS: native intent, an `approving` progress row (its
  /// deadline is the latest the native record can live, the original link
  /// expiry plus seven days; native enforces the real one) and the claim
  /// request digest, in one commit. Returns the intent time.
  Future<int> k2SourceConfirm(K2TransferId id, String typedSas,
      {required String recipientDeviceId, required String claimRequestHash});

  /// The approval tag to POST. Refused until [k2SourceConfirm]'s commit is
  /// stored (the progress row is the proof).
  Future<K2ApprovalRequest> k2SourceApprovalRequest(K2TransferId id);

  /// Exports the history snapshot, encrypts it natively, drains the
  /// ciphertext into a durable file under [cacheDirectory] and commits the
  /// frozen handoff, manifest and `snapshot_ready` row, all before any
  /// upload. A retry after the commit returns the stored row.
  Future<HistoryTransferProgress> k2SourcePrepare(K2TransferId id,
      {required String cacheDirectory});

  /// The server holds exactly this ciphertext and handoff: native posted
  /// state and the `uploaded` row.
  Future<HistoryTransferProgress> k2SourcePosted(K2TransferId id);

  // --- Recipient, after promotion ---

  /// Verifies [handoff] natively against the pinned context, checks it names
  /// the transfer the server described, and commits the frozen handoff,
  /// digest, size and `downloading` row before any download.
  Future<HistoryTransferProgress> k2ReceiveHandoff(K2TransferId id,
      {required List<int> handoff,
      required String transferId,
      required List<int> ciphertextSha256,
      required int ciphertextSize,
      required String downloadPath});

  /// Feeds the whole downloaded file to a native stream: true only when the
  /// digest, header and every chunk authenticate. Changes no state.
  Future<bool> k2VerifyDownload(K2TransferId id);

  /// Commits the native importing stage, then reads the verified plaintext
  /// and imports it in one database transaction (which holds the import
  /// ledger), and stores the `imported` row. Re-running after the import
  /// committed is a no-op through the ledger.
  Future<HistoryTransferProgress> k2ImportDownloaded(K2TransferId id);

  // --- Both, last step ---

  /// After the server confirmed the ACK (row stage `acknowledged`): removes
  /// the native record (committed), deletes the ciphertext file and the row.
  /// Idempotent after a crash at any of those points.
  Future<void> k2Finish(K2TransferId id);

  /// Local abandonment (the user cancels, or the copy cannot finish): the
  /// native record, the ciphertext file and the row go. It does not cancel
  /// the server's copy (the caller does, and may fail), and it keeps
  /// whatever history was already imported.
  Future<void> k2Abandon(K2TransferId id);

  /// Drops native records past their retention and rows past their deadline
  /// (with their files). Returns how many rows went. Commits only when a
  /// native record was removed.
  Future<int> k2ExpireTransfers();

  /// Deletes `k2-source-*` ciphertext files (and their `.part` files) under
  /// [cacheDirectory] that no stored transfer row names, such as a copy
  /// written just before a crash that kept its row from committing. A file a
  /// row names is never touched, whatever its stage. Runs in the service's
  /// serial queue, so it cannot meet a prepare between its rename and its
  /// commit. Returns how many files went.
  Future<int> k2SweepOrphanCaches(String cacheDirectory);
}
