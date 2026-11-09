part of 'encrypted_database.dart';

// Local schema 34 (W11, docs/designs/W11-profiles.md, "Receiving and
// caching"). Raw SQL like the other later tables, so the generated drift code
// does not change. Self-contained: `_createProfiles` is the whole upgrade
// step, so the coordinator can renumber the schema without touching it.
//
// - `local_profile_keys`: the keys this device holds, at most
//   [profileKeysPerSubject] per subject, keyed by key id.
// - `local_profiles`: the records this device accepted. A row with revision 0
//   is a placeholder that only holds an account's version floor.
// - `local_profile_state`: small named values (the own key id, the audience,
//   the rotation-due flags, delivery bookkeeping).
//
// Keys and names never go into a log. They are not in a history snapshot or a
// K2 transfer.

extension ProfileSql on EncryptedLocalDatabase {
  Future<void> _createProfiles() async {
    await customStatement('CREATE TABLE IF NOT EXISTS local_profile_keys ('
        "subject_kind TEXT NOT NULL CHECK(subject_kind IN "
        "('account', 'conversation')), "
        'subject_id TEXT NOT NULL CHECK(length(subject_id) BETWEEN 1 AND 128), '
        'key_id TEXT NOT NULL CHECK(length(key_id) = 32), '
        'key BLOB NOT NULL CHECK(length(key) = 32), '
        'received_at INTEGER NOT NULL, '
        'PRIMARY KEY (subject_kind, subject_id, key_id))');
    await customStatement('CREATE TABLE IF NOT EXISTS local_profiles ('
        "subject_kind TEXT NOT NULL CHECK(subject_kind IN "
        "('account', 'conversation')), "
        'subject_id TEXT NOT NULL CHECK(length(subject_id) BETWEEN 1 AND 128), '
        'server_version INTEGER NOT NULL CHECK(server_version >= 0), '
        'key_id TEXT NOT NULL CHECK(length(key_id) IN (0, 32)), '
        'revision INTEGER NOT NULL CHECK(revision >= 0), '
        'name TEXT, '
        'photo_png BLOB, '
        'fetched_at INTEGER NOT NULL, '
        'version_floor INTEGER NOT NULL DEFAULT 0 CHECK(version_floor >= 0), '
        'PRIMARY KEY (subject_kind, subject_id))');
    await customStatement('CREATE TABLE IF NOT EXISTS local_profile_state ('
        'name TEXT PRIMARY KEY NOT NULL CHECK(length(name) BETWEEN 1 AND 200), '
        'value TEXT NOT NULL)');
  }

  Future<void> _clearProfiles() async {
    await customStatement('DELETE FROM local_profile_keys');
    await customStatement('DELETE FROM local_profiles');
    await customStatement('DELETE FROM local_profile_state');
  }

  Future<List<StoredProfileKey>> readProfileKeys(
      String kind, String subjectId) async {
    final rows = await customSelect(
        'SELECT * FROM local_profile_keys WHERE subject_kind = ? '
        'AND subject_id = ? ORDER BY received_at, key_id',
        variables: [
          Variable.withString(kind),
          Variable.withString(subjectId),
        ]).get();
    return [
      for (final row in rows)
        StoredProfileKey(
          kind: kind,
          subjectId: subjectId,
          keyId: row.read<String>('key_id'),
          key: row.read<Uint8List>('key'),
          receivedAt: row.read<int>('received_at'),
        ),
    ];
  }

  Future<List<StoredProfileKey>> readAllProfileKeys(String kind) async {
    final rows = await customSelect(
        'SELECT * FROM local_profile_keys WHERE subject_kind = ? '
        'ORDER BY subject_id, received_at, key_id',
        variables: [Variable.withString(kind)]).get();
    return [
      for (final row in rows)
        StoredProfileKey(
          kind: kind,
          subjectId: row.read<String>('subject_id'),
          keyId: row.read<String>('key_id'),
          key: row.read<Uint8List>('key'),
          receivedAt: row.read<int>('received_at'),
        ),
    ];
  }

  /// Adds a received key and, for an account, raises its version floor. A key
  /// already held is left as it is, so a repeated send cannot reorder the
  /// eviction. Runs inside the transaction of the message that carried it.
  Future<void> storeProfileKey(ProfileKeyEffect effect) async {
    final kind = effect.kind;
    final held = await readProfileKeys(kind, effect.subjectId);
    if (!held.any((k) => k.keyId == effect.keyId)) {
      await customStatement(
          'INSERT INTO local_profile_keys (subject_kind, subject_id, key_id, '
          'key, received_at) VALUES (?, ?, ?, ?, ?)',
          [
            kind,
            effect.subjectId,
            effect.keyId,
            Uint8List.fromList(effect.key),
            effect.receivedAt,
          ]);
      final profile = await readProfile(kind, effect.subjectId);
      final all = [
        ...held,
        StoredProfileKey(
            kind: kind,
            subjectId: effect.subjectId,
            keyId: effect.keyId,
            key: Uint8List.fromList(effect.key),
            receivedAt: effect.receivedAt),
      ];
      for (final id in profileKeysToEvict(all,
          protectedKeyId: profile?.keyId, newestKeyId: effect.keyId)) {
        await customStatement(
            'DELETE FROM local_profile_keys WHERE subject_kind = ? '
            'AND subject_id = ? AND key_id = ?',
            [kind, effect.subjectId, id]);
      }
    }
    if (kind == profileSubjectAccount && effect.raisesFloor) {
      await raiseProfileFloor(effect.subjectId, effect.version);
    }
  }

  Future<void> raiseProfileFloor(String accountId, int floor) async {
    await customStatement(
        'INSERT INTO local_profiles (subject_kind, subject_id, '
        "server_version, key_id, revision, fetched_at, version_floor) "
        "VALUES ('account', ?, 0, '', 0, 0, ?) "
        'ON CONFLICT(subject_kind, subject_id) DO UPDATE SET '
        'version_floor = MAX(version_floor, excluded.version_floor)',
        [accountId, floor]);
  }

  Future<void> deleteProfileKey(String kind, String subjectId, String keyId) =>
      customStatement(
          'DELETE FROM local_profile_keys WHERE subject_kind = ? '
          'AND subject_id = ? AND key_id = ?',
          [kind, subjectId, keyId]);

  StoredProfile _profileFrom(QueryRow row) => StoredProfile(
        kind: row.read<String>('subject_kind'),
        subjectId: row.read<String>('subject_id'),
        serverVersion: row.read<int>('server_version'),
        keyId: row.read<String>('key_id'),
        revision: row.read<int>('revision'),
        name: row.read<String?>('name'),
        photoPng: row.read<Uint8List?>('photo_png'),
        fetchedAt: row.read<int>('fetched_at'),
        versionFloor: row.read<int>('version_floor'),
      );

  Future<StoredProfile?> readProfile(String kind, String subjectId) async {
    final row = await customSelect(
        'SELECT * FROM local_profiles WHERE subject_kind = ? '
        'AND subject_id = ?',
        variables: [
          Variable.withString(kind),
          Variable.withString(subjectId),
        ]).getSingleOrNull();
    return row == null ? null : _profileFrom(row);
  }

  Future<List<StoredProfile>> readProfiles(String kind) async {
    final rows = await customSelect(
        'SELECT * FROM local_profiles WHERE subject_kind = ? '
        'AND revision > 0',
        variables: [Variable.withString(kind)]).get();
    return [for (final row in rows) _profileFrom(row)];
  }

  /// Stores an accepted record. The version floor only ever rises. A record
  /// below the stored revision is refused, so a slow fetch cannot roll the
  /// cache back. Returns whether it was written.
  Future<bool> writeProfile(StoredProfile profile) => transaction(() async {
        final current = await readProfile(profile.kind, profile.subjectId);
        if (current != null && profile.revision < current.revision) {
          return false;
        }
        final floor = profile.versionFloor > (current?.versionFloor ?? 0)
            ? profile.versionFloor
            : (current?.versionFloor ?? 0);
        await customStatement(
            'INSERT OR REPLACE INTO local_profiles (subject_kind, subject_id, '
            'server_version, key_id, revision, name, photo_png, fetched_at, '
            'version_floor) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [
              profile.kind,
              profile.subjectId,
              profile.serverVersion,
              profile.keyId,
              profile.revision,
              profile.name,
              profile.photoPng == null
                  ? null
                  : Uint8List.fromList(profile.photoPng!),
              profile.fetchedAt,
              floor,
            ]);
        return true;
      });

  /// Deletes a subject's cached profile and all its keys (blocking, no shared
  /// conversation left, leaving a group).
  Future<void> deleteProfileSubject(String kind, String subjectId) =>
      transaction(() async {
        await customStatement(
            'DELETE FROM local_profile_keys WHERE subject_kind = ? '
            'AND subject_id = ?',
            [kind, subjectId]);
        await customStatement(
            'DELETE FROM local_profiles WHERE subject_kind = ? '
            'AND subject_id = ?',
            [kind, subjectId]);
      });

  Future<String?> readProfileState(String name) async {
    final row = await customSelect(
        'SELECT value FROM local_profile_state WHERE name = ?',
        variables: [Variable.withString(name)]).getSingleOrNull();
    return row?.read<String>('value');
  }

  Future<void> writeProfileState(String name, String? value) => value == null
      ? customStatement(
          'DELETE FROM local_profile_state WHERE name = ?', [name])
      : customStatement(
          'INSERT OR REPLACE INTO local_profile_state (name, value) '
          'VALUES (?, ?)',
          [name, value]);

  Future<Map<String, String>> readProfileStatePrefix(String prefix) async {
    final rows = await customSelect(
        'SELECT name, value FROM local_profile_state '
        "WHERE substr(name, 1, ?) = ?",
        variables: [
          Variable.withInt(prefix.length),
          Variable.withString(prefix),
        ]).get();
    return {
      for (final row in rows)
        row.read<String>('name'): row.read<String>('value'),
    };
  }
}
