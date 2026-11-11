part of 'encrypted_database.dart';

// Local schema 18 (K2, docs/designs/K2-native-state-migration.md, "Atomic
// persistence and upgrade rules"): the enrollment promotion ledger and the
// progress of a history transfer. Both hold only what this device needs to
// resume; neither ever goes into a backup, a history snapshot or a log.

/// One identity this database made active from a pending enrollment (a K0
/// recovery claim or a K2 v3 link). Keyed by the identity, not by the link:
/// device IDs are fresh per reservation, so the identity alone says that its
/// frozen pre-join MLS state must never become active again (review finding
/// 4 on schema 17). The crypto state being empty is not that signal: a
/// backup restore or an identity change empties it while the identity
/// stays promoted.
///
/// The ledger lives exactly as long as the database's identity history:
/// sign-out, a cached clear, an identity change and a backup restore keep
/// it; only a full reset ([EncryptedLocalDatabase.clearAll]) drops it, and
/// that drops the pending enrollment too.
class EnrollmentPromotionRow {
  const EnrollmentPromotionRow({
    required this.kind,
    required this.origin,
    required this.accountId,
    required this.deviceId,
    required this.promotionId,
    required this.promotedAt,
  });

  final String kind;

  /// The canonical server origin.
  final String origin;
  final String accountId;
  final String deviceId;

  /// What made the promotion: the K2 claim request digest, the K0 request
  /// ID, or [promotionIdSchemaUpgrade]. A retry must name the same one.
  final String promotionId;

  /// Epoch milliseconds.
  final int promotedAt;

  @override
  String toString() => 'EnrollmentPromotionRow($kind)';
}

/// [EnrollmentPromotionRow.promotionId] of an identity the 17 to 18 upgrade
/// found already active beside its own pending enrollment.
const String promotionIdSchemaUpgrade = 'schema-18-upgrade';

enum EnrollmentPromotionOutcome {
  /// This call made the pending identity active.
  promoted,

  /// The same promotion had already committed (its outcome was lost); the
  /// stored state, not the frozen pending one, is the active identity.
  alreadyPromoted,
}

/// A promotion that must not happen. [reason] is fixed text: it never names
/// a credential, a key or an identifier.
class EnrollmentPromotionRefused implements Exception {
  const EnrollmentPromotionRefused(this.reason);
  final String reason;

  @override
  String toString() => 'enrollment promotion refused: $reason';
}

/// What a promotion makes active, as the database layer takes it.
class EnrollmentPromotionRequest {
  const EnrollmentPromotionRequest({
    required this.kind,
    required this.origin,
    required this.accountId,
    required this.deviceId,
    required this.promotionId,
    required this.session,
    required this.expectedState,
    required this.promotedAt,
    this.transfer,
  });

  final String kind;
  final String origin;
  final String accountId;
  final String deviceId;
  final String promotionId;

  /// The new active session, as stored (`base_url`, `token`, ...).
  final Map<String, Object?> session;

  /// The frozen state the native service opened; it must be byte-equal to
  /// the pending row's.
  final PendingEnrollmentState expectedState;
  final int promotedAt;

  /// An incoming K2 transfer to start with the identity, if any.
  final HistoryTransferProgress? transfer;

  @override
  String toString() => 'EnrollmentPromotionRequest($kind)';
}

const _promotionKinds = {
  pendingEnrollmentKindAccountRecovery,
  pendingEnrollmentKindDeviceLinkV3,
};

/// The canonical origin of [raw], or [raw] itself when it is not an origin
/// (it then matches nothing canonical).
String _canonicalOrigin(String raw) {
  try {
    return canonicalizeServerOrigin(raw);
  } on FormatException {
    return raw;
  }
}

/// The identity a stored session JSON names, or null when it names none.
({String origin, String accountId, String deviceId, String token})?
    _storedSessionIdentity(Map<String, Object?>? session) {
  if (session == null) return null;
  String text(String name) {
    final value = session[name];
    return value is String ? value : '';
  }

  final baseUrl = text('base_url');
  return (
    origin: baseUrl.isEmpty ? '' : _canonicalOrigin(baseUrl),
    accountId: text('account_id'),
    deviceId: text('device_id'),
    token: text('token'),
  );
}

/// Whether promoting [request] over the stored session [existingSession]
/// replaces another identity that is signed out (its token is empty, for
/// example a sign-out that kept the device). That identity's local state
/// (MLS state, chats, cursor) is then dropped in the promotion's own
/// transaction, as saving a session of another identity drops it. Throws
/// [EnrollmentPromotionRefused] when another identity is signed in.
///
/// Kept, never replaced: no session, and a session of the pending identity
/// itself (an older build saved it before its MLS state). A signed-out
/// account with no device (what a retired legacy restore left, K1-6) is
/// replaced like any other identity: its state is dropped, never mixed.
bool promotionReplacesSignedOutIdentity({
  required EnrollmentPromotionRequest request,
  required Map<String, Object?>? existingSession,
}) {
  final previous = _storedSessionIdentity(existingSession);
  if (previous == null) return false;
  final sameAccount = previous.origin == request.origin &&
      previous.accountId == request.accountId;
  if (sameAccount && previous.deviceId == request.deviceId) {
    return false;
  }
  if (previous.token.isNotEmpty) {
    throw const EnrollmentPromotionRefused('another session is active');
  }
  return true;
}

/// Decides a promotion from what is stored; throws
/// [EnrollmentPromotionRefused] where it must not happen. Both stores use
/// it. [ledger] holds every ledger row for the request's account and device
/// (any origin); [cryptoStateStored] is whether an active MLS state exists;
/// [existingSession] is the stored session JSON, if any.
EnrollmentPromotionOutcome decideEnrollmentPromotion({
  required EnrollmentPromotionRequest request,
  required List<EnrollmentPromotionRow> ledger,
  required PendingEnrollmentRow? pending,
  required bool cryptoStateStored,
  required Map<String, Object?>? existingSession,
}) {
  if (!_promotionKinds.contains(request.kind) ||
      request.origin.isEmpty ||
      request.origin != _canonicalOrigin(request.origin) ||
      request.accountId.isEmpty ||
      request.deviceId.isEmpty ||
      request.promotionId.isEmpty ||
      request.promotionId.length > 256 ||
      request.promotedAt <= 0) {
    throw const EnrollmentPromotionRefused('invalid promotion');
  }
  final next = _storedSessionIdentity(request.session)!;
  if (next.origin != request.origin ||
      next.accountId != request.accountId ||
      next.deviceId != request.deviceId ||
      next.token.isEmpty) {
    throw const EnrollmentPromotionRefused(
        'the session does not match the enrollment');
  }
  // The ledger decides first, whatever the crypto state says.
  if (ledger.isNotEmpty) {
    final same = ledger.where((row) =>
        row.origin == request.origin &&
        row.kind == request.kind &&
        row.promotionId == request.promotionId);
    if (same.isNotEmpty) return EnrollmentPromotionOutcome.alreadyPromoted;
    throw const EnrollmentPromotionRefused('this identity was promoted before');
  }
  if (pending == null ||
      pending.kind != request.kind ||
      pending.origin != request.origin ||
      pending.accountId != request.accountId ||
      pending.deviceId != request.deviceId) {
    throw const EnrollmentPromotionRefused('no matching pending enrollment');
  }
  final state = pending.state;
  if (state == null ||
      state.counter != 1 ||
      !_samePendingState(state, request.expectedState)) {
    throw const EnrollmentPromotionRefused(
        'the pending identity is not the one opened');
  }
  // The session decides before the MLS state: a signed-out identity the
  // promotion replaces takes its MLS state with it.
  final replaces = promotionReplacesSignedOutIdentity(
      request: request, existingSession: existingSession);
  if (cryptoStateStored && !replaces) {
    throw const EnrollmentPromotionRefused('another MLS state is active');
  }
  if (request.transfer case final transfer?) {
    if (transfer.direction != historyTransferIncoming ||
        transfer.origin != request.origin ||
        transfer.accountId != request.accountId ||
        transfer.deviceId != request.deviceId) {
      throw const EnrollmentPromotionRefused(
          'the transfer is not for this identity');
    }
  }
  return EnrollmentPromotionOutcome.promoted;
}

// ---------------------------------------------------------------------------
// History transfer progress.

/// [HistoryTransferProgress.direction] of a transfer this device receives.
const String historyTransferIncoming = 'incoming';

/// [HistoryTransferProgress.direction] of a transfer this device sends.
const String historyTransferOutgoing = 'outgoing';

/// The stages of a history transfer, in the only order they may move.
abstract final class HistoryTransferStage {
  // Incoming (recipient).

  /// Promoted; the handoff is not stored yet.
  static const awaitingHandoff = 'awaiting_handoff';

  /// The handoff is verified natively and frozen here; ciphertext arrives
  /// at [HistoryTransferProgress.fileOffset].
  static const downloading = 'downloading';

  /// The whole file is here and its digest matched.
  static const downloaded = 'downloaded';

  /// The import transaction (and its import ledger) committed; the ACK and
  /// the native cleanup may still be owed.
  static const imported = 'imported';

  // Outgoing (source).

  /// The SAS was confirmed; the approval request may be retried.
  static const approving = 'approving';

  /// The encrypted snapshot is cached at [HistoryTransferProgress.filePath]
  /// and its handoff frozen, before any upload.
  static const snapshotReady = 'snapshot_ready';

  /// The server holds exactly this ciphertext and handoff.
  static const uploaded = 'uploaded';

  // Both.

  /// The server confirmed the ACK; only local cleanup is left.
  static const acknowledged = 'acknowledged';

  static const incoming = [
    awaitingHandoff,
    downloading,
    downloaded,
    imported,
    acknowledged,
  ];
  static const outgoing = [approving, snapshotReady, uploaded, acknowledged];

  static List<String> of(String direction) =>
      direction == historyTransferIncoming ? incoming : outgoing;
}

/// The largest K2 ciphertext and handoff (the transfer client's limits).
const int _maxTransferCiphertextBytes = 100 * 1024 * 1024;
const int _maxTransferHandoffBytes = 8192;
const int _maxTransferPayloadBytes = 64 * 1024;

/// One history transfer this device sends or receives: the app half of a
/// native transfer record (link context, keys and handoff verification live
/// in the sealed MLS state). Keyed like the native map, by origin and link.
///
/// Its lifetime is the active MLS state's: every path that drops that state
/// drops these rows, since their native half goes with it.
///
/// A class, not a record, so [toString] names the direction and stage only:
/// [payloadJson] holds credentials (the claim token) and [handoff] is the
/// sealed handoff.
class HistoryTransferProgress {
  const HistoryTransferProgress({
    required this.origin,
    required this.linkId,
    required this.direction,
    required this.accountId,
    required this.deviceId,
    required this.peerDeviceId,
    required this.stage,
    required this.expiresAt,
    this.transferId,
    this.ciphertextSha256,
    this.ciphertextSize,
    this.handoff,
    this.filePath,
    this.fileOffset = 0,
    this.payloadJson = '{}',
  });

  /// The canonical server origin.
  final String origin;
  final String linkId;

  /// [historyTransferIncoming] or [historyTransferOutgoing].
  final String direction;
  final String accountId;

  /// This device.
  final String deviceId;

  /// The other device of the link.
  final String peerDeviceId;

  /// One of [HistoryTransferStage.of] for [direction].
  final String stage;

  /// The fixed transfer deadline, epoch milliseconds. Never extended.
  final int expiresAt;

  /// The native transfer ID (64 lowercase hex), with [ciphertextSha256] and
  /// [ciphertextSize]: all three or none, frozen once set.
  final String? transferId;
  final List<int>? ciphertextSha256;
  final int? ciphertextSize;

  /// The exact opaque handoff bytes, frozen once set: HPKE re-sealing is
  /// randomized, so only these bytes are a valid retry.
  final List<int>? handoff;

  /// The ciphertext cache (outgoing) or download (incoming) file in the
  /// app's private directory. Frozen once set. Never a plaintext file.
  final String? filePath;

  /// Ciphertext bytes stored in [filePath] (incoming) or acknowledged by
  /// the server (outgoing).
  final int fileOffset;

  /// The direction's own mutable fields, credentials included. Never log.
  final String payloadJson;

  HistoryTransferProgress copyWith({
    String? stage,
    String? transferId,
    List<int>? ciphertextSha256,
    int? ciphertextSize,
    List<int>? handoff,
    String? filePath,
    int? fileOffset,
    String? payloadJson,
  }) =>
      HistoryTransferProgress(
        origin: origin,
        linkId: linkId,
        direction: direction,
        accountId: accountId,
        deviceId: deviceId,
        peerDeviceId: peerDeviceId,
        stage: stage ?? this.stage,
        expiresAt: expiresAt,
        transferId: transferId ?? this.transferId,
        ciphertextSha256: ciphertextSha256 ?? this.ciphertextSha256,
        ciphertextSize: ciphertextSize ?? this.ciphertextSize,
        handoff: handoff ?? this.handoff,
        filePath: filePath ?? this.filePath,
        fileOffset: fileOffset ?? this.fileOffset,
        payloadJson: payloadJson ?? this.payloadJson,
      );

  @override
  String toString() => 'HistoryTransferProgress($direction, $stage)';
}

/// A history transfer write that must not happen. [reason] is fixed text.
class HistoryTransferConflict implements Exception {
  const HistoryTransferConflict(this.reason);
  final String reason;

  @override
  String toString() => 'history transfer refused: $reason';
}

final _transferIdPattern = RegExp(r'^[0-9a-f]{64}$');

bool _boundedText(String value, int max) =>
    value.isNotEmpty && value.length <= max;

/// Throws [FormatException] unless [t] is a well-formed transfer in a
/// stage whose requirements it meets.
void validateHistoryTransfer(HistoryTransferProgress t) {
  Never invalid() => throw const FormatException('invalid history transfer');
  if (!_boundedText(t.origin, 2048) ||
      t.origin != _canonicalOrigin(t.origin) ||
      !_boundedText(t.linkId, 128) ||
      !_boundedText(t.accountId, 128) ||
      !_boundedText(t.deviceId, 128) ||
      !_boundedText(t.peerDeviceId, 128) ||
      t.deviceId == t.peerDeviceId ||
      (t.direction != historyTransferIncoming &&
          t.direction != historyTransferOutgoing) ||
      t.expiresAt <= 0 ||
      t.fileOffset < 0) {
    invalid();
  }
  final stages = HistoryTransferStage.of(t.direction);
  final stage = stages.indexOf(t.stage);
  if (stage < 0) invalid();
  final known = t.transferId != null;
  if (known != (t.ciphertextSha256 != null) ||
      known != (t.ciphertextSize != null)) {
    invalid();
  }
  if (known &&
      (!_transferIdPattern.hasMatch(t.transferId!) ||
          t.ciphertextSha256!.length != 32 ||
          t.ciphertextSize! <= 0 ||
          t.ciphertextSize! > _maxTransferCiphertextBytes)) {
    invalid();
  }
  if (t.fileOffset > (t.ciphertextSize ?? 0)) invalid();
  final handoff = t.handoff;
  if (handoff != null &&
      (handoff.isEmpty || handoff.length > _maxTransferHandoffBytes)) {
    invalid();
  }
  final path = t.filePath;
  if (path != null && !_boundedText(path, 4096)) invalid();
  if (t.payloadJson.length > _maxTransferPayloadBytes) invalid();
  try {
    if (jsonDecode(t.payloadJson) is! Map) invalid();
  } on FormatException {
    invalid();
  }
  // What each stage needs before it can be resumed.
  final incoming = t.direction == historyTransferIncoming;
  final firstWithFile = incoming
      ? HistoryTransferStage.incoming.indexOf(HistoryTransferStage.downloading)
      : HistoryTransferStage.outgoing
          .indexOf(HistoryTransferStage.snapshotReady);
  if (stage >= firstWithFile && (!known || handoff == null || path == null)) {
    invalid();
  }
  if (incoming &&
      (t.stage == HistoryTransferStage.downloaded ||
          t.stage == HistoryTransferStage.imported) &&
      t.fileOffset != t.ciphertextSize) {
    invalid();
  }
}

/// What storing [next] over [existing] (the same origin and link) leaves.
/// The identity, direction and deadline never change; the transfer ID,
/// digest, size, handoff and file path are frozen once set (a write
/// without them keeps them, a different value is refused); the stage only
/// moves forward. Throws [HistoryTransferConflict] or [FormatException].
HistoryTransferProgress mergeHistoryTransfer(
    HistoryTransferProgress? existing, HistoryTransferProgress next) {
  validateHistoryTransfer(next);
  if (existing == null) return next;
  if (existing.origin != next.origin ||
      existing.linkId != next.linkId ||
      existing.direction != next.direction ||
      existing.accountId != next.accountId ||
      existing.deviceId != next.deviceId ||
      existing.peerDeviceId != next.peerDeviceId ||
      existing.expiresAt != next.expiresAt) {
    throw const HistoryTransferConflict('another transfer for this link');
  }
  final stages = HistoryTransferStage.of(next.direction);
  if (stages.indexOf(next.stage) < stages.indexOf(existing.stage)) {
    throw const HistoryTransferConflict('a transfer stage cannot go back');
  }
  T? frozen<T>(T? stored, T? replacement, bool Function(T, T) same) {
    if (stored == null) return replacement;
    if (replacement != null && !same(stored, replacement)) {
      throw const HistoryTransferConflict('frozen transfer data changed');
    }
    return stored;
  }

  final merged = HistoryTransferProgress(
    origin: next.origin,
    linkId: next.linkId,
    direction: next.direction,
    accountId: next.accountId,
    deviceId: next.deviceId,
    peerDeviceId: next.peerDeviceId,
    stage: next.stage,
    expiresAt: next.expiresAt,
    transferId:
        frozen<String>(existing.transferId, next.transferId, (a, b) => a == b),
    ciphertextSha256: frozen<List<int>>(
        existing.ciphertextSha256, next.ciphertextSha256, _sameBytes),
    ciphertextSize: frozen<int>(
        existing.ciphertextSize, next.ciphertextSize, (a, b) => a == b),
    handoff: frozen<List<int>>(existing.handoff, next.handoff, _sameBytes),
    filePath:
        frozen<String>(existing.filePath, next.filePath, (a, b) => a == b),
    fileOffset: next.fileOffset,
    payloadJson: next.payloadJson,
  );
  validateHistoryTransfer(merged);
  return merged;
}

/// Whether [transfer] belongs to the active identity: the stored session
/// [session] names its origin, account and device with a token, and an MLS
/// state (which holds the native half) is stored.
bool historyTransferIsActive(HistoryTransferProgress transfer,
    Map<String, Object?>? session, bool cryptoStateStored) {
  final identity = _storedSessionIdentity(session);
  return cryptoStateStored &&
      identity != null &&
      identity.token.isNotEmpty &&
      identity.origin == transfer.origin &&
      identity.accountId == transfer.accountId &&
      identity.deviceId == transfer.deviceId;
}

extension K2TransferSql on EncryptedLocalDatabase {
  static const tables = [
    'local_enrollment_promotions',
    'local_history_transfers',
  ];

  Future<void> _createK2Transfer() async {
    // Kinds and stages are checked in Dart, so a later kind or stage needs
    // no table rebuild; the direction is closed.
    await customStatement(
        'CREATE TABLE IF NOT EXISTS local_enrollment_promotions ('
        'origin TEXT NOT NULL, account_id TEXT NOT NULL, '
        'device_id TEXT NOT NULL, kind TEXT NOT NULL, '
        'promotion_id TEXT NOT NULL, promoted_at INTEGER NOT NULL, '
        'PRIMARY KEY (origin, account_id, device_id), '
        "CHECK (origin <> '' AND account_id <> '' AND device_id <> '' "
        "AND kind <> '' AND promotion_id <> ''))");
    await customStatement('CREATE TABLE IF NOT EXISTS local_history_transfers ('
        'origin TEXT NOT NULL, link_id TEXT NOT NULL, '
        "direction TEXT NOT NULL CHECK (direction IN ('incoming', 'outgoing')), "
        'account_id TEXT NOT NULL, device_id TEXT NOT NULL, '
        'peer_device_id TEXT NOT NULL, stage TEXT NOT NULL, '
        'transfer_id TEXT, ciphertext_sha256 BLOB, ciphertext_size INTEGER, '
        'handoff BLOB, file_path TEXT, '
        'file_offset INTEGER NOT NULL CHECK (file_offset >= 0), '
        'expires_at INTEGER NOT NULL, payload_json TEXT NOT NULL, '
        'PRIMARY KEY (origin, link_id), '
        'CHECK ((transfer_id IS NULL) = (ciphertext_sha256 IS NULL) '
        'AND (ciphertext_sha256 IS NULL) = (ciphertext_size IS NULL)), '
        'CHECK (ciphertext_sha256 IS NULL OR length(ciphertext_sha256) = 32), '
        'CHECK (file_offset <= coalesce(ciphertext_size, 0)), '
        'CHECK (handoff IS NULL OR length(handoff) BETWEEN 1 AND 8192))');
  }

  /// Schema 17 to 18: a pending enrollment whose identity is already the
  /// stored one (its session, signed in or out, and an MLS state) was
  /// activated by schema 17
  /// code that stopped before deleting it. It is recorded in the ledger and
  /// dropped, so it can never be activated again. One without a stored MLS
  /// state stays: its activation may still be owed. Never throws on stored
  /// text.
  Future<void> _ledgerActivatedPendingEnrollment() async {
    final pending = await _readPendingEnrollmentRaw();
    if (pending == null) return;
    final session = _decodeSessionMap(await _readSessionJsonRaw());
    final identity = _storedSessionIdentity(session);
    // The token does not matter: a sign-out that kept the device leaves
    // it empty, and the stored MLS state still says the identity was made
    // active (only an activation stores the state of the session's device).
    if (identity == null ||
        identity.origin != pending.origin ||
        identity.accountId != pending.accountId ||
        identity.deviceId != pending.deviceId ||
        !await _cryptoStateStoredRaw()) {
      return;
    }
    await _insertPromotion(EnrollmentPromotionRow(
      kind: pending.kind,
      origin: pending.origin,
      accountId: pending.accountId,
      deviceId: pending.deviceId,
      promotionId: promotionIdSchemaUpgrade,
      promotedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
    ));
    await _clearPendingEnrollment();
  }

  Future<({String kind, String origin, String accountId, String deviceId})?>
      _readPendingEnrollmentRaw() async {
    final row = await customSelect('SELECT kind, origin, account_id, device_id '
            'FROM local_pending_enrollment WHERE singleton = 1')
        .getSingleOrNull();
    if (row == null) return null;
    return (
      kind: row.read<String>('kind'),
      origin: row.read<String>('origin'),
      accountId: row.read<String>('account_id'),
      deviceId: row.read<String>('device_id'),
    );
  }

  Future<String?> _readSessionJsonRaw() async => (await customSelect(
              'SELECT session_json FROM local_accounts WHERE singleton = 1')
          .getSingleOrNull())
      ?.read<String?>('session_json');

  Future<bool> _cryptoStateStoredRaw() async => (await customSelect(
              'SELECT 1 AS present FROM local_crypto_states WHERE singleton = 1')
          .get())
      .isNotEmpty;

  static Map<String, Object?>? _decodeSessionMap(String? json) {
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _insertPromotion(EnrollmentPromotionRow row) => customStatement(
          'INSERT INTO local_enrollment_promotions (origin, account_id, '
          'device_id, kind, promotion_id, promoted_at) VALUES (?, ?, ?, ?, ?, ?)',
          [
            row.origin,
            row.accountId,
            row.deviceId,
            row.kind,
            row.promotionId,
            row.promotedAt,
          ]);

  Future<List<EnrollmentPromotionRow>> _readPromotionsInTransaction(
      String accountId, String deviceId) async {
    final rows = await customSelect(
        'SELECT * FROM local_enrollment_promotions '
        'WHERE account_id = ? AND device_id = ?',
        variables: [
          Variable.withString(accountId),
          Variable.withString(deviceId),
        ]).get();
    return [
      for (final row in rows)
        EnrollmentPromotionRow(
          kind: row.read<String>('kind'),
          origin: row.read<String>('origin'),
          accountId: row.read<String>('account_id'),
          deviceId: row.read<String>('device_id'),
          promotionId: row.read<String>('promotion_id'),
          promotedAt: row.read<int>('promoted_at'),
        ),
    ];
  }

  /// The ledger rows for this account's [deviceId], on any origin.
  Future<List<EnrollmentPromotionRow>> readEnrollmentPromotions(
          {required String accountId, required String deviceId}) =>
      transaction(() => _readPromotionsInTransaction(accountId, deviceId));

  /// Makes the pending enrollment the active identity in one transaction:
  /// the session, the frozen MLS state (root and records, counter 1),
  /// cursor 0, the ledger row and an optional incoming transfer, with the
  /// pending rows deleted. The history a restored account kept stays.
  /// Every write is a raw statement so a crash can be injected after each.
  ///
  /// A promotion the ledger already holds (same origin, kind and promotion
  /// ID) answers [EnrollmentPromotionOutcome.alreadyPromoted] and only drops
  /// a stale pending row; anything else that does not fit throws
  /// [EnrollmentPromotionRefused] and changes nothing. A signed-out identity
  /// of another device is replaced, as an identity change replaces it (see
  /// [promotionReplacesSignedOutIdentity]).
  Future<EnrollmentPromotionOutcome> promotePendingEnrollment(
          EnrollmentPromotionRequest request) =>
      transaction(() async {
        final ledger = await _readPromotionsInTransaction(
            request.accountId, request.deviceId);
        final pending = await _readPendingEnrollmentInTransaction();
        final existingSession = _decodeSessionMap(await _readSessionJsonRaw());
        final outcome = decideEnrollmentPromotion(
          request: request,
          ledger: ledger,
          pending: pending,
          cryptoStateStored: await _cryptoStateStoredRaw(),
          existingSession: existingSession,
        );
        if (outcome == EnrollmentPromotionOutcome.alreadyPromoted) {
          if (pending != null &&
              pending.accountId == request.accountId &&
              pending.deviceId == request.deviceId) {
            await _clearPendingEnrollment();
          }
          return outcome;
        }
        final state = pending!.state!;
        // A signed-out identity of another device goes first, in this same
        // transaction, as an identity change drops it (the ledger stays).
        if (promotionReplacesSignedOutIdentity(
            request: request, existingSession: existingSession)) {
          await _clearIdentityStateInTransaction();
        }
        await customStatement(
            'INSERT INTO local_accounts (singleton, session_json) VALUES (1, ?) '
            'ON CONFLICT(singleton) DO UPDATE SET session_json = excluded.session_json',
            [jsonEncode(request.session)]);
        await _clearGovernanceObservations();
        await customStatement('DELETE FROM local_crypto_records');
        for (final record in state.records) {
          final sealed = record.sealed;
          if (sealed == null) continue;
          await customStatement(
              'INSERT INTO local_crypto_records (kind, record_id, generation, '
              'sealed) VALUES (?, ?, ?, ?)',
              [
                record.kind,
                Uint8List.fromList(record.recordId),
                record.generation,
                Uint8List.fromList(sealed),
              ]);
        }
        await customStatement(
            'INSERT INTO local_crypto_states (singleton, counter, state_key, '
            'sealed_state) VALUES (1, ?, ?, ?)',
            [
              state.counter,
              Uint8List.fromList(state.stateKey),
              Uint8List.fromList(state.root),
            ]);
        await customStatement(
            'INSERT INTO local_sync_states (singleton, cursor) VALUES (1, 0) '
            'ON CONFLICT(singleton) DO UPDATE SET cursor = 0');
        await _insertPromotion(EnrollmentPromotionRow(
          kind: request.kind,
          origin: request.origin,
          accountId: request.accountId,
          deviceId: request.deviceId,
          promotionId: request.promotionId,
          promotedAt: request.promotedAt,
        ));
        if (request.transfer case final transfer?) {
          await _writeHistoryTransferInTransaction(transfer);
        }
        await _clearPendingEnrollment();
        return outcome;
      });

  Future<HistoryTransferProgress?> _readHistoryTransferInTransaction(
      String origin, String linkId) async {
    final row = await customSelect(
        'SELECT * FROM local_history_transfers WHERE origin = ? AND link_id = ?',
        variables: [
          Variable.withString(origin),
          Variable.withString(linkId),
        ]).getSingleOrNull();
    return row == null ? null : _historyTransferFromRow(row);
  }

  static HistoryTransferProgress _historyTransferFromRow(QueryRow row) {
    final sha = row.read<Uint8List?>('ciphertext_sha256');
    final handoff = row.read<Uint8List?>('handoff');
    return HistoryTransferProgress(
      origin: row.read<String>('origin'),
      linkId: row.read<String>('link_id'),
      direction: row.read<String>('direction'),
      accountId: row.read<String>('account_id'),
      deviceId: row.read<String>('device_id'),
      peerDeviceId: row.read<String>('peer_device_id'),
      stage: row.read<String>('stage'),
      expiresAt: row.read<int>('expires_at'),
      transferId: row.read<String?>('transfer_id'),
      ciphertextSha256: sha == null ? null : List<int>.from(sha),
      ciphertextSize: row.read<int?>('ciphertext_size'),
      handoff: handoff == null ? null : List<int>.from(handoff),
      filePath: row.read<String?>('file_path'),
      fileOffset: row.read<int>('file_offset'),
      payloadJson: row.read<String>('payload_json'),
    );
  }

  /// Stores [next] under [mergeHistoryTransfer]'s rules, only for the active
  /// identity (see [historyTransferIsActive]).
  Future<void> _writeHistoryTransferInTransaction(
      HistoryTransferProgress next) async {
    validateHistoryTransfer(next);
    if (!historyTransferIsActive(
        next,
        _decodeSessionMap(await _readSessionJsonRaw()),
        await _cryptoStateStoredRaw())) {
      throw const HistoryTransferConflict(
          'the transfer is not for the active identity');
    }
    final merged = mergeHistoryTransfer(
        await _readHistoryTransferInTransaction(next.origin, next.linkId),
        next);
    await customStatement(
        'INSERT OR REPLACE INTO local_history_transfers (origin, link_id, '
        'direction, account_id, device_id, peer_device_id, stage, '
        'transfer_id, ciphertext_sha256, ciphertext_size, handoff, file_path, '
        'file_offset, expires_at, payload_json) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          merged.origin,
          merged.linkId,
          merged.direction,
          merged.accountId,
          merged.deviceId,
          merged.peerDeviceId,
          merged.stage,
          merged.transferId,
          merged.ciphertextSha256 == null
              ? null
              : Uint8List.fromList(merged.ciphertextSha256!),
          merged.ciphertextSize,
          merged.handoff == null ? null : Uint8List.fromList(merged.handoff!),
          merged.filePath,
          merged.fileOffset,
          merged.expiresAt,
          merged.payloadJson,
        ]);
  }

  /// The transfer for [origin] and [linkId], or null.
  Future<HistoryTransferProgress?> readHistoryTransfer(
          String origin, String linkId) =>
      transaction(() => _readHistoryTransferInTransaction(origin, linkId));

  /// Every stored transfer, ordered by origin then link (the native order).
  Future<List<HistoryTransferProgress>> readHistoryTransfers() async => [
        for (final row in await customSelect(
                'SELECT * FROM local_history_transfers ORDER BY origin, link_id')
            .get())
          _historyTransferFromRow(row),
      ];

  /// Stores [transfer] (see [mergeHistoryTransfer]).
  Future<void> writeHistoryTransfer(HistoryTransferProgress transfer) =>
      transaction(() => _writeHistoryTransferInTransaction(transfer));

  /// Commits a native transfer mutation and its app progress together, so
  /// neither half can be stored without the other (the handoff and manifest
  /// before any HTTP). [state] is a local MLS state change under the same
  /// expected-counter rules as [EncryptedLocalDatabase.commitLocalMlsState];
  /// the cursor does not move.
  Future<void> commitHistoryTransferState({
    required HistoryTransferProgress transfer,
    required int expectedCounter,
    required int expectedCursor,
    required int counter,
    required List<int> stateKey,
    required List<int> sealedState,
    List<CryptoRecordWrite> recordChanges = const <CryptoRecordWrite>[],
    String? leaseKey,
  }) =>
      transaction(() async {
        await _commitLocalMlsStateInTransaction(
          expectedCounter: expectedCounter,
          expectedCursor: expectedCursor,
          counter: counter,
          stateKey: stateKey,
          sealedState: sealedState,
          recordChanges: recordChanges,
          leaseKey: leaseKey,
        );
        await _writeHistoryTransferInTransaction(transfer);
      });

  /// Deletes the transfer for [origin] and [linkId]; returns whether one
  /// was deleted.
  Future<bool> deleteHistoryTransfer(String origin, String linkId) =>
      transaction(() async {
        final existing =
            await _readHistoryTransferInTransaction(origin, linkId);
        if (existing == null) return false;
        await customStatement(
            'DELETE FROM local_history_transfers WHERE origin = ? AND link_id = ?',
            [origin, linkId]);
        return true;
      });

  Future<void> _clearHistoryTransfers() =>
      customStatement('DELETE FROM local_history_transfers');

  Future<void> _clearEnrollmentPromotions() =>
      customStatement('DELETE FROM local_enrollment_promotions');
}
