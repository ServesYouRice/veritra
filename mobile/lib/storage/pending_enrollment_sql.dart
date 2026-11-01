part of 'encrypted_database.dart';

/// One device enrollment that is not an active session yet (schema 17): a
/// K0 account recovery claim waiting out its delay, or a K2 v3 device link
/// between reservation and promotion (`docs/designs/K2-native-state-migration.md`,
/// "Atomic persistence and upgrade rules"; K0 recovery design, client flow
/// step 4). It holds bearer credentials and the new identity's sealed MLS
/// state, so it lives only in this encrypted database: no backup, history
/// snapshot or log ever carries it (D71, D73).
///
/// A device makes one new identity at a time, so there is at most one row.
/// Its MLS state is frozen once written: a retry must reopen exactly that
/// identity, never a regenerated one.
///
/// A class, not a record, so [toString] (in an error, a log or a test
/// failure) names the kind only, never a credential or key.
class PendingEnrollmentRow {
  const PendingEnrollmentRow({
    required this.kind,
    required this.origin,
    required this.accountId,
    required this.deviceId,
    required this.payloadJson,
    this.state,
  });

  final String kind;
  final String origin;
  final String accountId;
  final String deviceId;
  final String payloadJson;
  final PendingEnrollmentState? state;

  @override
  String toString() => 'PendingEnrollmentRow($kind)';
}

/// One record change of a pending enrollment's sealed MLS state (D70).
typedef PendingEnrollmentRecord = ({
  int kind,
  List<int> recordId,
  int generation,
  List<int>? sealed,
});

/// The new identity's sealed MLS state: counter, key, root and records.
class PendingEnrollmentState {
  const PendingEnrollmentState({
    required this.counter,
    required this.stateKey,
    required this.root,
    required this.records,
  });

  final int counter;
  final List<int> stateKey;
  final List<int> root;
  final List<PendingEnrollmentRecord> records;

  @override
  String toString() => 'PendingEnrollmentState($counter)';
}

/// The waiting K0 claim as schema 16 stored it, in the metadata table.
const String _legacyPendingRecoveryName = 'setting:k0.pending_recovery';

/// [PendingEnrollmentRow.kind] of a K0 account recovery claim.
const String pendingEnrollmentKindAccountRecovery = 'k0_recovery';

/// [PendingEnrollmentRow.kind] of a K2 v3 device link.
const String pendingEnrollmentKindDeviceLinkV3 = 'k2_link_v3';

class PendingEnrollmentConflict implements Exception {
  const PendingEnrollmentConflict();
  @override
  String toString() => 'another device enrollment is pending';
}

extension PendingEnrollmentSql on EncryptedLocalDatabase {
  static const tables = [
    'local_pending_enrollment',
    'local_pending_enrollment_records',
  ];

  Future<void> _createPendingEnrollment() async {
    await customStatement(
        'CREATE TABLE IF NOT EXISTS local_pending_enrollment ('
        'singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton = 1), '
        'kind TEXT NOT NULL, origin TEXT NOT NULL, account_id TEXT NOT NULL, '
        'device_id TEXT NOT NULL, payload_json TEXT NOT NULL, '
        'state_counter INTEGER, state_key BLOB, state_root BLOB, '
        'CHECK ((state_counter IS NULL) = (state_key IS NULL) '
        'AND (state_key IS NULL) = (state_root IS NULL)))');
    // The state's record changes in the order the seal listed them.
    await customStatement(
        'CREATE TABLE IF NOT EXISTS local_pending_enrollment_records ('
        'position INTEGER PRIMARY KEY NOT NULL CHECK(position >= 0), '
        'kind INTEGER NOT NULL, record_id BLOB NOT NULL, '
        'generation INTEGER NOT NULL, sealed BLOB)');
  }

  /// Schema 16 to 17: the waiting K0 claim moves from its metadata setting
  /// into the table, in the upgrade's transaction. Only what the schema 16
  /// loader read as a whole claim moves; anything else (an abandoned `''`,
  /// an unreadable value) was never shown and is dropped. Nothing here
  /// throws on the stored text or echoes it: it holds credentials.
  ///
  /// A row already in the table (a downgraded app that kept it, then
  /// upgraded again) is kept; a setting written meanwhile is then dropped,
  /// since a device holds one enrollment.
  Future<void> _movePendingRecoverySetting() async {
    final rows = await customSelect(
        'SELECT value FROM local_metadata WHERE name = ?',
        variables: [Variable.withString(_legacyPendingRecoveryName)]).get();
    if (rows.isEmpty) return;
    PendingEnrollmentRow? row;
    try {
      row = legacyPendingRecoveryRow(rows.single.read<String>('value'));
    } catch (_) {
      row = null;
    }
    if (row != null && await _readPendingEnrollmentInTransaction() == null) {
      await _insertPendingEnrollment(row);
    }
    await customStatement('DELETE FROM local_metadata WHERE name = ?',
        [_legacyPendingRecoveryName]);
  }

  Future<void> _insertPendingEnrollment(PendingEnrollmentRow row) async {
    final state = row.state;
    await customStatement(
        'INSERT INTO local_pending_enrollment (singleton, kind, origin, '
        'account_id, device_id, payload_json, state_counter, state_key, '
        'state_root) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          row.kind,
          row.origin,
          row.accountId,
          row.deviceId,
          row.payloadJson,
          state?.counter,
          state == null ? null : Uint8List.fromList(state.stateKey),
          state == null ? null : Uint8List.fromList(state.root),
        ]);
    await _insertPendingRecords(state);
  }

  Future<void> _insertPendingRecords(PendingEnrollmentState? state) async {
    if (state == null) return;
    var position = 0;
    for (final record in state.records) {
      await customStatement(
          'INSERT INTO local_pending_enrollment_records '
          '(position, kind, record_id, generation, sealed) VALUES (?, ?, ?, ?, ?)',
          [
            position++,
            record.kind,
            Uint8List.fromList(record.recordId),
            record.generation,
            record.sealed == null ? null : Uint8List.fromList(record.sealed!),
          ]);
    }
  }

  Future<PendingEnrollmentRow?> _readPendingEnrollmentInTransaction() async {
    final row = await customSelect(
            'SELECT * FROM local_pending_enrollment WHERE singleton = 1')
        .getSingleOrNull();
    if (row == null) return null;
    final counter = row.read<int?>('state_counter');
    final key = row.read<Uint8List?>('state_key');
    final root = row.read<Uint8List?>('state_root');
    final records = <PendingEnrollmentRecord>[
      for (final r in await customSelect(
              'SELECT * FROM local_pending_enrollment_records ORDER BY position')
          .get())
        (
          kind: r.read<int>('kind'),
          recordId: List<int>.from(r.read<Uint8List>('record_id')),
          generation: r.read<int>('generation'),
          sealed: r.read<Uint8List?>('sealed') == null
              ? null
              : List<int>.from(r.read<Uint8List>('sealed')),
        ),
    ];
    return PendingEnrollmentRow(
      kind: row.read<String>('kind'),
      origin: row.read<String>('origin'),
      accountId: row.read<String>('account_id'),
      deviceId: row.read<String>('device_id'),
      payloadJson: row.read<String>('payload_json'),
      state: counter == null || key == null || root == null
          ? null
          : PendingEnrollmentState(
              counter: counter,
              stateKey: List<int>.from(key),
              root: List<int>.from(root),
              records: records,
            ),
    );
  }

  /// The pending enrollment, or null.
  Future<PendingEnrollmentRow?> readPendingEnrollment() =>
      transaction(_readPendingEnrollmentInTransaction);

  /// Stores [row] as the pending enrollment. Fails closed with
  /// [PendingEnrollmentConflict] when another enrollment (another kind,
  /// origin, account or device) is pending, and when [row] would replace a
  /// stored MLS state with a different one: once sealed, the identity is
  /// frozen until promotion or abandonment. A [row] without a state keeps
  /// the stored one.
  Future<void> writePendingEnrollment(PendingEnrollmentRow row) =>
      transaction(() async {
        final existing = await _readPendingEnrollmentInTransaction();
        final write = mergePendingEnrollment(existing, row);
        if (existing != null) await _clearPendingEnrollment();
        await _insertPendingEnrollment(write);
      });

  /// Deletes the pending enrollment if it is of [kind] (and of [deviceId],
  /// when given). Returns whether a row was deleted.
  Future<bool> deletePendingEnrollment(
          {required String kind, String? deviceId}) =>
      transaction(() async {
        final existing = await _readPendingEnrollmentInTransaction();
        if (existing == null ||
            existing.kind != kind ||
            (deviceId != null && existing.deviceId != deviceId)) {
          return false;
        }
        await _clearPendingEnrollment();
        return true;
      });

  Future<void> _clearPendingEnrollment() async {
    await customStatement('DELETE FROM local_pending_enrollment_records');
    await customStatement('DELETE FROM local_pending_enrollment');
  }
}

/// What storing [next] over [existing] leaves (see
/// [PendingEnrollmentSql.writePendingEnrollment]); throws
/// [PendingEnrollmentConflict] where that must fail.
PendingEnrollmentRow mergePendingEnrollment(
    PendingEnrollmentRow? existing, PendingEnrollmentRow next) {
  if (existing == null) return next;
  if (existing.kind != next.kind ||
      existing.origin != next.origin ||
      existing.accountId != next.accountId ||
      existing.deviceId != next.deviceId) {
    throw const PendingEnrollmentConflict();
  }
  final stored = existing.state;
  if (stored == null) return next;
  final replacement = next.state;
  if (replacement != null && !_samePendingState(stored, replacement)) {
    throw const PendingEnrollmentConflict();
  }
  return PendingEnrollmentRow(
    kind: next.kind,
    origin: next.origin,
    accountId: next.accountId,
    deviceId: next.deviceId,
    payloadJson: next.payloadJson,
    state: stored,
  );
}

bool _samePendingState(PendingEnrollmentState a, PendingEnrollmentState b) {
  if (a.counter != b.counter ||
      !_sameBytes(a.stateKey, b.stateKey) ||
      !_sameBytes(a.root, b.root) ||
      a.records.length != b.records.length) {
    return false;
  }
  for (var i = 0; i < a.records.length; i++) {
    final x = a.records[i];
    final y = b.records[i];
    if (x.kind != y.kind ||
        x.generation != y.generation ||
        !_sameBytes(x.recordId, y.recordId) ||
        (x.sealed == null) != (y.sealed == null) ||
        (x.sealed != null && !_sameBytes(x.sealed!, y.sealed!))) {
      return false;
    }
  }
  return true;
}

/// The schema 16 K0 claim as a row; null for anything the schema 16 loader
/// ignored. A frozen copy of that loader's v1 decoder (K0 R4's
/// `PendingAccountRecovery.decode`), so a later change to the live claim
/// format cannot change what this upgrade moves. The payload it writes is
/// the v1 payload `PendingAccountRecovery.fromEnrollment` reads. Never
/// echoes [raw]: it holds credentials.
PendingEnrollmentRow? legacyPendingRecoveryRow(String raw) {
  if (raw.isEmpty) return null;
  try {
    final json = jsonDecode(raw);
    if (json is! Map || json['v'] != 1) return null;
    final mls = json['mls'] as Map;
    final readyAtText = json['ready_at'];
    if (readyAtText is! String || readyAtText.isEmpty) return null;
    final readyAt = DateTime.tryParse(readyAtText)?.toUtc();
    if (readyAt == null) return null;
    String text(String name) {
      final value = json[name];
      if (value is! String || value.isEmpty) {
        throw const FormatException('pending recovery');
      }
      return value;
    }

    final origin = text('origin');
    final username = text('username');
    final accountId = text('account_id');
    final deviceId = text('device_id');
    final deviceName = text('device_name');
    final requestId = text('request_id');
    final claimToken = text('claim_token');
    final deviceSecret = text('device_secret');
    final counter = (mls['counter'] as num).toInt();
    final stateKey = base64Decode(mls['key'] as String);
    final root = base64Decode(mls['root'] as String);
    final records = <PendingEnrollmentRecord>[
      for (final record in mls['records'] as List)
        (
          kind: ((record as Map)['kind'] as num).toInt(),
          recordId: base64Decode(record['id'] as String),
          generation: (record['generation'] as num).toInt(),
          sealed: record['sealed'] == null
              ? null
              : base64Decode(record['sealed'] as String),
        ),
    ];
    return PendingEnrollmentRow(
      kind: pendingEnrollmentKindAccountRecovery,
      origin: origin,
      accountId: accountId,
      deviceId: deviceId,
      payloadJson: jsonEncode(<String, Object?>{
        'v': 1,
        'username': username,
        'device_name': deviceName,
        'request_id': requestId,
        'claim_token': claimToken,
        'device_secret': deviceSecret,
        'ready_at': readyAt.toIso8601String(),
        'needs_login': json['needs_login'] == true,
      }),
      state: PendingEnrollmentState(
          counter: counter, stateKey: stateKey, root: root, records: records),
    );
  } catch (_) {
    return null;
  }
}
