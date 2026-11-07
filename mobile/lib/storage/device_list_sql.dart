part of 'encrypted_database.dart';

// Local schema 26 (L1-3, D94; docs/designs/L1-approved-device-list.md,
// "Pins, rollback and forks" and "The approval hold"). Raw SQL like the other
// later tables, so the generated drift code does not change. None of it goes
// into a backup, a history snapshot, a K2 transfer or a log.
//
// - `local_device_list_heads`: per account, the pinned head (version, its
//   `list_hash`, the list identity, the head statement), a state (`ok` or
//   `conflict`) and when it was last checked.
// - `local_device_list_keys`: every pair the pinned chain ever listed, with
//   the version that added it and the one that removed it (0 while listed).
// - `local_device_list_conflicts`: the two statements that prove a fork.
// - `local_approval_leaves`: per conversation, every leaf of its group as
//   this device judged it. A conversation is held while any row is not
//   `approved` (the approval hold); a conversation with no rows was never
//   audited and is judged before it is used.

extension DeviceListSql on EncryptedLocalDatabase {
  Future<void> _createDeviceLists() async {
    await customStatement('CREATE TABLE IF NOT EXISTS local_device_list_heads ('
        'account_id TEXT PRIMARY KEY NOT NULL '
        'CHECK(length(account_id) BETWEEN 1 AND 128), '
        'version INTEGER NOT NULL CHECK(version >= 1), '
        'list_hash BLOB NOT NULL CHECK(length(list_hash) = 32), '
        'list_id BLOB NOT NULL CHECK(length(list_id) = 32), '
        'head_statement BLOB NOT NULL '
        'CHECK(length(head_statement) BETWEEN 1 AND 4096), '
        "state TEXT NOT NULL CHECK(state IN ('ok', 'conflict')), "
        'checked_at INTEGER NOT NULL)');
    await customStatement('CREATE TABLE IF NOT EXISTS local_device_list_keys ('
        'account_id TEXT NOT NULL, '
        'device_id BLOB NOT NULL CHECK(length(device_id) BETWEEN 1 AND 128), '
        'signing_key BLOB NOT NULL CHECK(length(signing_key) = 32), '
        'added_version INTEGER NOT NULL CHECK(added_version >= 1), '
        'removed_version INTEGER NOT NULL CHECK(removed_version >= 0), '
        'PRIMARY KEY (account_id, device_id, signing_key))');
    await customStatement(
        'CREATE TABLE IF NOT EXISTS local_device_list_conflicts ('
        'account_id TEXT NOT NULL, '
        'version INTEGER NOT NULL, '
        'pinned_statement BLOB NOT NULL, '
        'other_statement BLOB NOT NULL, '
        'recorded_at INTEGER NOT NULL, '
        'PRIMARY KEY (account_id, version))');
    await customStatement('CREATE TABLE IF NOT EXISTS local_approval_leaves ('
        'conversation_id TEXT NOT NULL '
        'CHECK(length(conversation_id) BETWEEN 1 AND 128), '
        'account_id BLOB NOT NULL CHECK(length(account_id) BETWEEN 1 AND 128), '
        'device_id BLOB NOT NULL CHECK(length(device_id) BETWEEN 1 AND 128), '
        'signing_key BLOB NOT NULL CHECK(length(signing_key) = 32), '
        "verdict TEXT NOT NULL CHECK(verdict IN "
        "('approved', 'removed', 'unapproved', 'checking')), "
        'updated_at INTEGER NOT NULL, '
        'PRIMARY KEY (conversation_id, account_id, device_id))');
  }

  Future<void> _clearDeviceLists() async {
    await customStatement('DELETE FROM local_device_list_heads');
    await customStatement('DELETE FROM local_device_list_keys');
    await customStatement('DELETE FROM local_device_list_conflicts');
    await customStatement('DELETE FROM local_approval_leaves');
  }

  Future<DeviceListPin?> readDeviceListPin(String accountId) async {
    final head = await customSelect(
        'SELECT * FROM local_device_list_heads WHERE account_id = ?',
        variables: [Variable.withString(accountId)]).getSingleOrNull();
    if (head == null) return null;
    final keys = await customSelect(
        'SELECT * FROM local_device_list_keys WHERE account_id = ? '
        'ORDER BY added_version, device_id',
        variables: [Variable.withString(accountId)]).get();
    return DeviceListPin(
      accountId: accountId,
      version: head.read<int>('version'),
      listHash: head.read<Uint8List>('list_hash'),
      listId: head.read<Uint8List>('list_id'),
      headStatement: head.read<Uint8List>('head_statement'),
      conflict: head.read<String>('state') == 'conflict',
      checkedAt: head.read<int>('checked_at'),
      keys: [
        for (final row in keys)
          DeviceListKeyRow(
            deviceId: row.read<Uint8List>('device_id'),
            signingKey: row.read<Uint8List>('signing_key'),
            addedVersion: row.read<int>('added_version'),
            removedVersion: row.read<int>('removed_version'),
          ),
      ],
    );
  }

  /// Replaces the pin of [pin.accountId] only while the stored one is still
  /// at [expectedVersion] (null: none stored), so a pin only moves forward
  /// along what this device verified. Returns whether it was written.
  Future<bool> writeDeviceListPin(DeviceListPin pin,
          {required int? expectedVersion}) =>
      transaction(() async {
        final current = await customSelect(
            'SELECT version, state FROM local_device_list_heads '
            'WHERE account_id = ?',
            variables: [Variable.withString(pin.accountId)]).getSingleOrNull();
        final currentVersion = current?.read<int>('version');
        if (currentVersion != expectedVersion) return false;
        if (current != null && current.read<String>('state') == 'conflict') {
          // A conflict is sticky; only [resetDeviceListPin] clears it.
          return false;
        }
        if (currentVersion != null && pin.version < currentVersion) {
          return false;
        }
        await customStatement(
            'INSERT OR REPLACE INTO local_device_list_heads (account_id, '
            'version, list_hash, list_id, head_statement, state, checked_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?)',
            [
              pin.accountId,
              pin.version,
              Uint8List.fromList(pin.listHash),
              Uint8List.fromList(pin.listId),
              Uint8List.fromList(pin.headStatement),
              pin.conflict ? 'conflict' : 'ok',
              pin.checkedAt,
            ]);
        await customStatement(
            'DELETE FROM local_device_list_keys WHERE account_id = ?',
            [pin.accountId]);
        for (final key in pin.keys) {
          await customStatement(
              'INSERT INTO local_device_list_keys (account_id, device_id, '
              'signing_key, added_version, removed_version) '
              'VALUES (?, ?, ?, ?, ?)',
              [
                pin.accountId,
                Uint8List.fromList(key.deviceId),
                Uint8List.fromList(key.signingKey),
                key.addedVersion,
                key.removedVersion,
              ]);
        }
        return true;
      });

  /// Records when [accountId]'s pin was last checked (nothing newer seen).
  Future<void> touchDeviceListPin(String accountId, int checkedAt) =>
      customStatement(
          'UPDATE local_device_list_heads SET checked_at = ? '
          'WHERE account_id = ?',
          [checkedAt, accountId]);

  /// Marks [accountId] as in conflict and keeps both statements as proof.
  Future<void> writeDeviceListConflict({
    required String accountId,
    required int version,
    required List<int> pinnedStatement,
    required List<int> otherStatement,
    required int recordedAt,
  }) =>
      transaction(() async {
        await customStatement(
            "UPDATE local_device_list_heads SET state = 'conflict' "
            'WHERE account_id = ?',
            [accountId]);
        await customStatement(
            'INSERT OR IGNORE INTO local_device_list_conflicts (account_id, '
            'version, pinned_statement, other_statement, recorded_at) '
            'VALUES (?, ?, ?, ?, ?)',
            [
              accountId,
              version,
              Uint8List.fromList(pinnedStatement),
              Uint8List.fromList(otherStatement),
              recordedAt,
            ]);
      });

  Future<List<ApprovalLeaf>> readApprovalLeaves(String conversationId) async {
    final rows = await customSelect(
        'SELECT * FROM local_approval_leaves WHERE conversation_id = ? '
        'ORDER BY account_id, device_id',
        variables: [Variable.withString(conversationId)]).get();
    return rows.map(_leafFromRow).toList(growable: false);
  }

  Future<List<String>> readHeldConversations() async {
    final rows = await customSelect(
            'SELECT DISTINCT conversation_id FROM local_approval_leaves '
            "WHERE verdict != 'approved' ORDER BY conversation_id")
        .get();
    return [for (final row in rows) row.read<String>('conversation_id')];
  }

  ApprovalLeaf _leafFromRow(QueryRow row) => ApprovalLeaf(
        conversationId: row.read<String>('conversation_id'),
        accountId: row.read<Uint8List>('account_id'),
        deviceId: row.read<Uint8List>('device_id'),
        signingKey: row.read<Uint8List>('signing_key'),
        verdict: LeafVerdict.values.byName(row.read<String>('verdict')),
        updatedAt: row.read<int>('updated_at'),
      );

  Future<void> writeApprovalLeaves(ApprovalLeafChange change) =>
      transaction(() => _writeApprovalLeavesInTransaction(change));

  Future<void> _writeApprovalLeavesInTransaction(
      ApprovalLeafChange? change) async {
    if (change == null) return;
    if (change.replaceAll) {
      await customStatement(
          'DELETE FROM local_approval_leaves WHERE conversation_id = ?',
          [change.conversationId]);
    }
    for (final leaf in change.leaves) {
      if (!leaf.isStorable) continue;
      await customStatement(
          'INSERT OR REPLACE INTO local_approval_leaves (conversation_id, '
          'account_id, device_id, signing_key, verdict, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?)',
          [
            change.conversationId,
            Uint8List.fromList(leaf.accountId),
            Uint8List.fromList(leaf.deviceId),
            Uint8List.fromList(leaf.signingKey),
            leaf.verdict.name,
            leaf.updatedAt,
          ]);
    }
  }

  Future<void> deleteApprovalLeaves(String conversationId) => customStatement(
      'DELETE FROM local_approval_leaves WHERE conversation_id = ?',
      [conversationId]);
}
