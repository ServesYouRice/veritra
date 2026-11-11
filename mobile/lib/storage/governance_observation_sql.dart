part of 'encrypted_database.dart';

// Device-local clocks. Never included in backups or copied history: a new
// device must observe the inactivity and election waits for itself.
extension GovernanceObservationSql on EncryptedLocalDatabase {
  Future<void> _createGovernanceObservations() => customStatement('''
    CREATE TABLE IF NOT EXISTS local_governance_observations (
      group_id TEXT PRIMARY KEY NOT NULL CHECK(length(group_id) BETWEEN 1 AND 128),
      owner TEXT CHECK(owner IS NULL OR length(owner) BETWEEN 1 AND 128),
      owner_rev INTEGER NOT NULL CHECK(owner_rev >= 0),
      last_owner_activity INTEGER NOT NULL,
      election_opened INTEGER CHECK(election_opened IS NULL OR election_opened >= 0),
      election_seen INTEGER,
      CHECK((election_opened IS NULL) = (election_seen IS NULL))
    )
  ''');

  Future<GovernanceObservations?> readGovernanceObservations(
      String groupId) async {
    final row = await customSelect(
        'SELECT * FROM local_governance_observations WHERE group_id = ?',
        variables: [Variable.withString(groupId)]).getSingleOrNull();
    if (row == null) return null;
    final seen = row.read<int?>('election_seen');
    return GovernanceObservations(
      owner: row.read<String?>('owner'),
      ownerRev: row.read<int>('owner_rev'),
      lastOwnerActivity: DateTime.fromMicrosecondsSinceEpoch(
          row.read<int>('last_owner_activity'),
          isUtc: true),
      electionOpened: row.read<int?>('election_opened'),
      electionSeen: seen == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(seen, isUtc: true),
    );
  }

  // Called only inside an MLS transaction after its counter/cursor guard.
  Future<void> _applyGovernanceObservation(
      GovernanceObservationChange? change) async {
    if (change == null) return;
    final next =
        change.reduce(await readGovernanceObservations(change.groupId));
    await customStatement('''
      INSERT INTO local_governance_observations VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(group_id) DO UPDATE SET
        owner = excluded.owner, owner_rev = excluded.owner_rev,
        last_owner_activity = excluded.last_owner_activity,
        election_opened = excluded.election_opened, election_seen = excluded.election_seen
    ''', [
      change.groupId,
      next.owner,
      next.ownerRev,
      next.lastOwnerActivity.microsecondsSinceEpoch,
      next.electionOpened,
      next.electionSeen?.microsecondsSinceEpoch
    ]);
  }

  Future<void> _clearGovernanceObservations() =>
      customStatement('DELETE FROM local_governance_observations');
}
