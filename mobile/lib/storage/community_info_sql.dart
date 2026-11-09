part of 'encrypted_database.dart';

// Local schema 31 (C3, docs/designs/C3-private-channels-and-info.md): what a
// device received about community info over MLS. Three kinds of row share one
// table: an info key (`info_key`), an announcement of an accepted record
// (`info_update`) and a request for a key (`info_key_request`); plus the cache
// of records this device accepted. Created by raw SQL, like the C6 and L1
// tables, so the generated drift code does not change.
//
// None of it goes into a backup, a history snapshot or a K2 transfer: a
// restored or new device asks the group for keys again (`info_key_request`).
// The keys are secrets: [CommunityInfoEvent.toString] never prints one.

// Rows are per sender and per group: one member (or another group) can
// neither pin a row first so an editor's identical copy is ignored, nor push
// out another sender's rows by flooding. A key that an accepted record uses
// is never evicted (W11's rule).

/// Keys kept per subject, group and sender (design: "up to 4 keys").
const int infoKeysPerSubject = 4;

/// Announcements kept per subject: enough to match the record the server
/// serves after a few quick edits, small enough that a member cannot grow
/// the table.
const int infoUpdatesPerSubject = 8;

/// Key requests kept per subject, so one chatty group cannot grow the table.
const int infoRequestsPerSubject = 16;

enum CommunityInfoEventKind { key, keyRequest, update }

/// One received C3 payload, already validated by the payload codec and tied
/// to its MLS-authenticated sender and conversation.
class CommunityInfoEvent {
  CommunityInfoEvent({
    required this.kind,
    required this.subjectKind,
    required this.subjectId,
    required this.conversationId,
    required this.senderAccountId,
    required this.senderDeviceId,
    this.keyId,
    List<int>? key,
    this.revision,
    this.recordSha256,
    this.seq,
  }) : key = key == null ? null : List<int>.unmodifiable(key);

  final CommunityInfoEventKind kind;
  final String subjectKind;
  final String subjectId;

  /// The conversation (MLS group) the payload arrived in. A key is used only
  /// when this is the group that owns it.
  final String conversationId;
  final String senderAccountId;
  final String senderDeviceId;
  final String? keyId;

  /// The 32-byte key, for [CommunityInfoEventKind.key] only.
  final List<int>? key;
  final int? revision;
  final String? recordSha256;

  /// Arrival order, set by the store on read (null on a new event). Later
  /// rows have larger numbers.
  final int? seq;

  CommunityInfoEvent _withSeq(int value) => CommunityInfoEvent(
        kind: kind,
        subjectKind: subjectKind,
        subjectId: subjectId,
        conversationId: conversationId,
        senderAccountId: senderAccountId,
        senderDeviceId: senderDeviceId,
        keyId: keyId,
        key: key,
        revision: revision,
        recordSha256: recordSha256,
        seq: value,
      );

  /// The row's identity: a repeat of the same key, announcement or request
  /// is one row.
  String get ident => switch (kind) {
        CommunityInfoEventKind.key =>
          'k|$subjectKind|$subjectId|$conversationId|$senderAccountId|$keyId',
        CommunityInfoEventKind.update =>
          'u|$subjectKind|$subjectId|$conversationId|$senderAccountId|$revision|$recordSha256',
        CommunityInfoEventKind.keyRequest =>
          'r|$subjectKind|$subjectId|$conversationId|$senderAccountId|$senderDeviceId',
      };

  bool get isStorable =>
      subjectKind.isNotEmpty &&
      subjectKind.length <= 16 &&
      subjectId.isNotEmpty &&
      subjectId.length <= 64 &&
      conversationId.isNotEmpty &&
      conversationId.length <= 128 &&
      senderAccountId.isNotEmpty &&
      senderAccountId.length <= 128 &&
      senderDeviceId.isNotEmpty &&
      senderDeviceId.length <= 128 &&
      switch (kind) {
        CommunityInfoEventKind.key => keyId?.length == 32 && key?.length == 32,
        CommunityInfoEventKind.update => keyId?.length == 32 &&
            (revision ?? 0) >= 1 &&
            recordSha256?.length == 64,
        CommunityInfoEventKind.keyRequest => true,
      };

  int get _limit => switch (kind) {
        CommunityInfoEventKind.key => infoKeysPerSubject,
        CommunityInfoEventKind.update => infoUpdatesPerSubject,
        CommunityInfoEventKind.keyRequest => infoRequestsPerSubject,
      };

  @override
  String toString() =>
      'CommunityInfoEvent(${kind.name}, $subjectKind, $subjectId)';
}

/// A record this device accepted (announced by an allowed editor, opened
/// with a key from the owning group): the blob as served, so it can be
/// opened again, and what it was checked against.
class AcceptedCommunityInfo {
  AcceptedCommunityInfo({
    required this.subjectKind,
    required this.subjectId,
    required this.revision,
    required this.keyId,
    required List<int> blob,
  }) : blob = List<int>.unmodifiable(blob);

  final String subjectKind;
  final String subjectId;
  final int revision;
  final String keyId;
  final List<int> blob;

  @override
  String toString() => 'AcceptedCommunityInfo($subjectKind, $subjectId)';
}

/// The bounded per-subject rule both stores apply: a repeat is ignored, and
/// past the limit the oldest rows of that kind and subject go.
List<CommunityInfoEvent> addCommunityInfoEvent(
    List<CommunityInfoEvent> rows, CommunityInfoEvent event,
    {Set<String> protectedKeyIds = const <String>{}}) {
  if (!event.isStorable) return rows;
  if (rows.any((r) => r.ident == event.ident)) {
    // A repeated key request is a new request (a device asking again after
    // missing a rotation): it moves to the end. Keys and announcements keep
    // their first arrival.
    if (event.kind != CommunityInfoEventKind.keyRequest) return rows;
    rows = rows.where((r) => r.ident != event.ident).toList();
  }
  var top = 0;
  for (final row in rows) {
    if ((row.seq ?? 0) > top) top = row.seq!;
  }
  final next = [...rows, event._withSeq(top + 1)];
  final same = next
      .where((r) =>
          r.kind == event.kind &&
          r.subjectKind == event.subjectKind &&
          r.subjectId == event.subjectId &&
          r.conversationId == event.conversationId &&
          r.senderAccountId == event.senderAccountId &&
          !(r.kind == CommunityInfoEventKind.key &&
              protectedKeyIds.contains(r.keyId)))
      .toList();
  final drop = same.length - event._limit;
  if (drop <= 0) return next;
  final gone = same.take(drop).map((r) => r.ident).toSet();
  return next.where((r) => !gone.contains(r.ident)).toList();
}

/// Rows eviction may take: never a key an accepted record uses.
const String _unprotected = "NOT (kind = 'key' AND key_id IN "
    '(SELECT key_id FROM local_info_records))';

extension CommunityInfoSql on EncryptedLocalDatabase {
  /// The tables schema 31 adds (for fixtures that build older databases).
  static const tables = ['local_info_events', 'local_info_records'];

  Future<void> _createCommunityInfo() async {
    await customStatement('CREATE TABLE IF NOT EXISTS local_info_events ('
        'seq INTEGER PRIMARY KEY AUTOINCREMENT,'
        'ident TEXT NOT NULL UNIQUE,'
        "kind TEXT NOT NULL CHECK(kind IN ('key','keyRequest','update')),"
        'subject_kind TEXT NOT NULL, subject_id TEXT NOT NULL,'
        'conversation_id TEXT NOT NULL, sender_account_id TEXT NOT NULL,'
        'sender_device_id TEXT NOT NULL,'
        'key_id TEXT, info_key BLOB CHECK(info_key IS NULL OR length(info_key)=32),'
        'revision INTEGER, record_sha256 TEXT)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS local_info_events_subject ON local_info_events '
        '(subject_kind, subject_id, kind, seq)');
    await customStatement('CREATE TABLE IF NOT EXISTS local_info_records ('
        'subject_kind TEXT NOT NULL, subject_id TEXT NOT NULL,'
        'revision INTEGER NOT NULL CHECK(revision>=1),'
        'key_id TEXT NOT NULL CHECK(length(key_id)=32),'
        'blob BLOB NOT NULL,'
        'PRIMARY KEY(subject_kind, subject_id))');
  }

  /// Stores [events] inside the caller's transaction (the MLS commit that
  /// consumed them). An event that is not storable is skipped, never thrown
  /// on, so a bad payload cannot roll back the ratchet.
  Future<void> _writeCommunityInfoInTransaction(
      List<CommunityInfoEvent> events) async {
    for (final event in events) {
      if (!event.isStorable) continue;
      await customStatement(
          '${event.kind == CommunityInfoEventKind.keyRequest ? 'INSERT OR REPLACE' : 'INSERT OR IGNORE'} INTO local_info_events '
          '(ident, kind, subject_kind, subject_id, conversation_id, '
          'sender_account_id, sender_device_id, key_id, info_key, revision, '
          'record_sha256) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            event.ident,
            event.kind.name,
            event.subjectKind,
            event.subjectId,
            event.conversationId,
            event.senderAccountId,
            event.senderDeviceId,
            event.keyId,
            event.key == null ? null : Uint8List.fromList(event.key!),
            event.revision,
            event.recordSha256,
          ]);
      await customStatement(
          'DELETE FROM local_info_events WHERE kind = ?1 AND subject_kind = ?2 '
          'AND subject_id = ?3 AND conversation_id = ?4 '
          'AND sender_account_id = ?5 AND $_unprotected '
          'AND seq NOT IN (SELECT seq FROM local_info_events '
          'WHERE kind = ?1 AND subject_kind = ?2 AND subject_id = ?3 '
          'AND conversation_id = ?4 AND sender_account_id = ?5 '
          'AND $_unprotected ORDER BY seq DESC LIMIT ?6)',
          <Object?>[
            event.kind.name,
            event.subjectKind,
            event.subjectId,
            event.conversationId,
            event.senderAccountId,
            event._limit,
          ]);
    }
  }

  /// The received events of [kind] for one subject, oldest first.
  Future<List<CommunityInfoEvent>> readCommunityInfoEvents(
      CommunityInfoEventKind kind, String subjectKind, String subjectId) async {
    final rows = await customSelect(
        'SELECT * FROM local_info_events WHERE kind = ? AND subject_kind = ? '
        'AND subject_id = ? ORDER BY seq',
        variables: [
          Variable.withString(kind.name),
          Variable.withString(subjectKind),
          Variable.withString(subjectId),
        ]).get();
    return [
      for (final row in rows)
        CommunityInfoEvent(
          kind: kind,
          subjectKind: row.read<String>('subject_kind'),
          subjectId: row.read<String>('subject_id'),
          conversationId: row.read<String>('conversation_id'),
          senderAccountId: row.read<String>('sender_account_id'),
          senderDeviceId: row.read<String>('sender_device_id'),
          keyId: row.readNullable<String>('key_id'),
          key: row.readNullable<Uint8List>('info_key'),
          revision: row.readNullable<int>('revision'),
          recordSha256: row.readNullable<String>('record_sha256'),
          seq: row.read<int>('seq'),
        ),
    ];
  }

  /// Writes events outside any MLS commit: this device's own keys, which it
  /// creates itself and never receives.
  Future<void> writeCommunityInfoEvents(List<CommunityInfoEvent> events) =>
      transaction(() => _writeCommunityInfoInTransaction(events));

  Future<AcceptedCommunityInfo?> readAcceptedCommunityInfo(
      String subjectKind, String subjectId) async {
    final row = await customSelect(
        'SELECT * FROM local_info_records WHERE subject_kind = ? AND subject_id = ?',
        variables: [
          Variable.withString(subjectKind),
          Variable.withString(subjectId),
        ]).getSingleOrNull();
    if (row == null) return null;
    return AcceptedCommunityInfo(
      subjectKind: subjectKind,
      subjectId: subjectId,
      revision: row.read<int>('revision'),
      keyId: row.read<String>('key_id'),
      blob: row.read<Uint8List>('blob'),
    );
  }

  /// Replaces the accepted record, but never with a lower revision.
  Future<void> writeAcceptedCommunityInfo(AcceptedCommunityInfo info) =>
      customStatement(
          'INSERT INTO local_info_records (subject_kind, subject_id, revision, key_id, blob) '
          'VALUES (?, ?, ?, ?, ?) ON CONFLICT(subject_kind, subject_id) DO UPDATE SET '
          'revision = excluded.revision, key_id = excluded.key_id, blob = excluded.blob '
          'WHERE excluded.revision >= local_info_records.revision',
          <Object?>[
            info.subjectKind,
            info.subjectId,
            info.revision,
            info.keyId,
            Uint8List.fromList(info.blob),
          ]);

  Future<void> _clearCommunityInfo() async {
    await customStatement('DELETE FROM local_info_events');
    await customStatement('DELETE FROM local_info_records');
  }
}
