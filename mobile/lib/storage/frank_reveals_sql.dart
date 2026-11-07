part of 'encrypted_database.dart';

// Local schema 19 (C6, docs/designs/C6-reports-franking.md, D95): what a
// receiver keeps so it can report a message later, and the pinned report keys
// of the instance owners. Both tables are created by raw SQL, like the K2 and
// notice tables, so the generated drift code does not change. Neither ever
// goes into a backup, a history snapshot, a K2 transfer or a log.

/// Longest `P` (the canonical payload bytes) a reveal keeps: the payload cap.
const int frankRevealMaxPayloadBytes = 64 * 1024;

/// The 32-byte franking key `kf`.
const int frankRevealKeyBytes = 32;

/// What a receiver keeps with a received, franked message: the franking key
/// `kf` and the exact canonical payload bytes `P` the sender's commitment
/// covers, plus the server's id of the envelope (needed to report it). With
/// the envelope's conversation, sender device and action id (which the
/// message row's key already holds) it is everything a report reveals
/// (`docs/crypto.md`, "Franking v1").
///
/// A reveal exists only while the message it belongs to is live: the row
/// goes with the message when it is deleted, hidden, expired or purged. `P`
/// holds the message text, so [toString] never prints it.
class FrankReveal {
  FrankReveal({
    required this.messageKey,
    required this.conversationId,
    required this.envelopeId,
    required List<int> frankKey,
    required List<int> payload,
  })  : frankKey = List<int>.unmodifiable(frankKey),
        payload = List<int>.unmodifiable(payload);

  /// The key of the message row (`<sender_device_id>:<action_id>`).
  final String messageKey;
  final String conversationId;

  /// The server's id of the message envelope.
  final String envelopeId;
  final List<int> frankKey;

  /// The canonical payload bytes `P`, exactly as the sender's commitment
  /// covers them.
  final List<int> payload;

  /// Whether the table would accept this reveal. A reveal that is not is
  /// skipped, never thrown on: it rides in the transaction that consumes an
  /// MLS message, which must not roll back for a report that cannot be made.
  bool get isStorable =>
      messageKey.isNotEmpty &&
      conversationId.isNotEmpty &&
      envelopeId.isNotEmpty &&
      messageKey.length <= 256 &&
      conversationId.length <= 128 &&
      envelopeId.length <= 128 &&
      frankKey.length == frankRevealKeyBytes &&
      payload.isNotEmpty &&
      payload.length <= frankRevealMaxPayloadBytes;

  @override
  String toString() => 'FrankReveal($messageKey)';
}

/// An instance owner's report public key that this app pinned (D95), per
/// server origin. Report screens seal to a key only while it matches its pin;
/// a key the server changes is refused until the person pins the new one
/// after checking its fingerprint.
class ReportKeyPin {
  ReportKeyPin({
    required this.origin,
    required this.ownerAccountId,
    required List<int> publicKey,
    required this.keyRev,
    required this.pinnedAt,
  }) : publicKey = List<int>.unmodifiable(publicKey);

  /// The canonical server origin.
  final String origin;
  final String ownerAccountId;
  final List<int> publicKey;

  /// The revision the server reported when the key was pinned.
  final int keyRev;

  /// Epoch milliseconds.
  final int pinnedAt;

  @override
  String toString() => 'ReportKeyPin($ownerAccountId)';
}

extension FrankRevealSql on EncryptedLocalDatabase {
  /// The tables schema 19 adds (for fixtures that build older databases).
  static const tables = ['local_frank_reveals', 'local_report_key_pins'];

  Future<void> _createFrankReveals() async {
    // message_key references the message row, so a purge, an expiry or a
    // history reset takes the reveal with it. The trigger below covers the
    // two ways a row stays but its content goes (delete for everyone, hide):
    // those keep the row as a tombstone, so the cascade never fires.
    await customStatement('CREATE TABLE IF NOT EXISTS local_frank_reveals ('
        'message_key TEXT PRIMARY KEY NOT NULL REFERENCES local_messages(key) ON DELETE CASCADE,'
        'conversation_id TEXT NOT NULL, envelope_id TEXT NOT NULL,'
        'frank_key BLOB NOT NULL CHECK(length(frank_key)=$frankRevealKeyBytes),'
        'payload BLOB NOT NULL CHECK(length(payload) BETWEEN 1 AND $frankRevealMaxPayloadBytes),'
        'stored_at INTEGER NOT NULL)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS local_frank_reveals_conversation ON local_frank_reveals '
        '(conversation_id)');
    await customStatement(
        'CREATE TRIGGER IF NOT EXISTS local_frank_reveals_tombstone '
        'AFTER UPDATE OF deleted_at, hidden_at ON local_messages '
        'WHEN NEW.deleted_at IS NOT NULL OR NEW.hidden_at IS NOT NULL '
        'BEGIN DELETE FROM local_frank_reveals WHERE message_key = NEW.key; END');
    await customStatement('CREATE TABLE IF NOT EXISTS local_report_key_pins ('
        'origin TEXT NOT NULL, owner_account_id TEXT NOT NULL,'
        'public_key BLOB NOT NULL CHECK(length(public_key)=32),'
        'key_rev INTEGER NOT NULL CHECK(key_rev>=1),'
        'pinned_at INTEGER NOT NULL,'
        'PRIMARY KEY(origin, owner_account_id))');
  }

  /// Stores [reveals] inside the caller's transaction. A reveal is kept only
  /// when its message row exists and is live: an edit, a reaction or a
  /// delete has no row of its own, and a message that arrived already
  /// expired was never stored, so each of those writes nothing (and never
  /// fails the commit that carries it).
  Future<void> _writeFrankRevealsInTransaction(
      List<FrankReveal> reveals) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final reveal in reveals) {
      if (!reveal.isStorable) continue;
      await customStatement(
          'INSERT OR IGNORE INTO local_frank_reveals '
          '(message_key, conversation_id, envelope_id, frank_key, payload, stored_at) '
          'SELECT ?, ?, ?, ?, ?, ? WHERE EXISTS ('
          'SELECT 1 FROM local_messages WHERE key = ? '
          'AND deleted_at IS NULL AND hidden_at IS NULL)',
          <Object?>[
            reveal.messageKey,
            reveal.conversationId,
            reveal.envelopeId,
            Uint8List.fromList(reveal.frankKey),
            Uint8List.fromList(reveal.payload),
            now,
            reveal.messageKey,
          ]);
    }
  }

  /// The reveal kept for the message [messageKey], or null.
  Future<FrankReveal?> readFrankReveal(String messageKey) async {
    final row = await customSelect(
        'SELECT message_key, conversation_id, envelope_id, frank_key, payload '
        'FROM local_frank_reveals WHERE message_key = ?',
        variables: [Variable.withString(messageKey)]).getSingleOrNull();
    if (row == null) return null;
    return FrankReveal(
      messageKey: row.read<String>('message_key'),
      conversationId: row.read<String>('conversation_id'),
      envelopeId: row.read<String>('envelope_id'),
      frankKey: row.read<Uint8List>('frank_key'),
      payload: row.read<Uint8List>('payload'),
    );
  }

  Future<void> _clearFrankReveals() =>
      customStatement('DELETE FROM local_frank_reveals');

  Future<void> _clearReportKeyPins() =>
      customStatement('DELETE FROM local_report_key_pins');

  ReportKeyPin _reportKeyPinFromRow(QueryRow row) => ReportKeyPin(
        origin: row.read<String>('origin'),
        ownerAccountId: row.read<String>('owner_account_id'),
        publicKey: row.read<Uint8List>('public_key'),
        keyRev: row.read<int>('key_rev'),
        pinnedAt: row.read<int>('pinned_at'),
      );

  Future<ReportKeyPin?> readReportKeyPin(
      String origin, String ownerAccountId) async {
    final row = await customSelect(
        'SELECT origin, owner_account_id, public_key, key_rev, pinned_at '
        'FROM local_report_key_pins WHERE origin = ? AND owner_account_id = ?',
        variables: [
          Variable.withString(origin),
          Variable.withString(ownerAccountId),
        ]).getSingleOrNull();
    return row == null ? null : _reportKeyPinFromRow(row);
  }

  Future<List<ReportKeyPin>> readReportKeyPins(String origin) async {
    final rows = await customSelect(
        'SELECT origin, owner_account_id, public_key, key_rev, pinned_at '
        'FROM local_report_key_pins WHERE origin = ? ORDER BY owner_account_id',
        variables: [Variable.withString(origin)]).get();
    return rows.map(_reportKeyPinFromRow).toList(growable: false);
  }

  /// Pins [pin], replacing the owner's earlier pin for the origin. This is
  /// the one deliberate act that accepts a key (and a changed one).
  Future<void> writeReportKeyPin(ReportKeyPin pin) async {
    if (pin.origin.isEmpty ||
        pin.ownerAccountId.isEmpty ||
        pin.publicKey.length != 32 ||
        pin.keyRev < 1) {
      throw const FormatException('invalid report key pin');
    }
    await customStatement(
        'INSERT OR REPLACE INTO local_report_key_pins '
        '(origin, owner_account_id, public_key, key_rev, pinned_at) '
        'VALUES (?, ?, ?, ?, ?)',
        <Object?>[
          pin.origin,
          pin.ownerAccountId,
          Uint8List.fromList(pin.publicKey),
          pin.keyRev,
          pin.pinnedAt,
        ]);
  }

  Future<void> deleteReportKeyPin(String origin, String ownerAccountId) =>
      customStatement(
          'DELETE FROM local_report_key_pins WHERE origin = ? AND owner_account_id = ?',
          <Object?>[origin, ownerAccountId]);
}
