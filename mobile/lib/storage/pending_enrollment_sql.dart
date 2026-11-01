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
typedef PendingEnrollmentRow = ({
  String kind,
  String origin,
  String accountId,
  String deviceId,
  String payloadJson,
  PendingEnrollmentState? state,
});

/// One record change of a pending enrollment's sealed MLS state (D70).
typedef PendingEnrollmentRecord = ({
  int kind,
  List<int> recordId,
  int generation,
  List<int>? sealed,
});

/// The new identity's sealed MLS state: counter, key, root and records.
typedef PendingEnrollmentState = ({
  int counter,
  List<int> stateKey,
  List<int> root,
  List<PendingEnrollmentRecord> records,
});

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
    await customStatement('CREATE TABLE local_pending_enrollment ('
        'singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton = 1), '
        'kind TEXT NOT NULL, origin TEXT NOT NULL, account_id TEXT NOT NULL, '
        'device_id TEXT NOT NULL, payload_json TEXT NOT NULL, '
        'state_counter INTEGER, state_key BLOB, state_root BLOB, '
        'CHECK ((state_counter IS NULL) = (state_key IS NULL) '
        'AND (state_key IS NULL) = (state_root IS NULL)))');
    // The state's record changes in the order the seal listed them.
    await customStatement('CREATE TABLE local_pending_enrollment_records ('
        'position INTEGER PRIMARY KEY NOT NULL CHECK(position >= 0), '
        'kind INTEGER NOT NULL, record_id BLOB NOT NULL, '
        'generation INTEGER NOT NULL, sealed BLOB)');
  }

  /// Schema 16 to 17: the waiting K0 claim moves from its metadata setting
  /// into the table, in the upgrade's transaction. Only what the K0 loader
  /// reads as a whole claim moves; anything else (an abandoned `''`, an
  /// unreadable value) was never shown and is dropped. Nothing here throws
  /// on the stored text or echoes it: it holds credentials.
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
    if (row != null) await _insertPendingEnrollment(row);
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
    return (
      kind: row.read<String>('kind'),
      origin: row.read<String>('origin'),
      accountId: row.read<String>('account_id'),
      deviceId: row.read<String>('device_id'),
      payloadJson: row.read<String>('payload_json'),
      state: counter == null || key == null || root == null
          ? null
          : (
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
  return (
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

/// The schema 16 K0 claim as a row, exactly as the K0 loader reads it
/// ([PendingAccountRecovery.decode]); null for anything it would ignore.
PendingEnrollmentRow? legacyPendingRecoveryRow(String raw) {
  final claim = PendingAccountRecovery.decode(raw);
  if (claim == null) return null;
  final state = claim.mlsState;
  return (
    kind: pendingEnrollmentKindAccountRecovery,
    origin: claim.origin,
    accountId: claim.accountId,
    deviceId: claim.deviceId,
    payloadJson: claim.encodePayload(),
    state: (
      counter: state.counter,
      stateKey: state.stateKey,
      root: state.sealedState,
      records: [
        for (final change in state.changes)
          (
            kind: change.kind,
            recordId: change.recordId,
            generation: change.generation,
            sealed: change.sealed,
          ),
      ],
    ),
  );
}
