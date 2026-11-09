import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// W11 local schema: keys are capped per subject, the key that opens the
/// cached record is never evicted, the version floor only rises, and the
/// tables arrive by upgrade.
String _id(int n) => n.toRadixString(16).padLeft(32, '0');

ProfileKeyEffect _key(
  int n, {
  String kind = profileSubjectAccount,
  String subject = 'acct_a',
  int version = 0,
}) =>
    ProfileKeyEffect(
      kind: kind,
      subjectId: subject,
      key: Uint8List(32)..[0] = n,
      keyId: _id(n),
      version: version,
      receivedAt: n,
    );

StoredProfile _profile(int revision,
        {String keyId = '', String? name = 'Ana', String subject = 'acct_a'}) =>
    StoredProfile(
      kind: profileSubjectAccount,
      subjectId: subject,
      serverVersion: revision,
      keyId: keyId.isEmpty ? _id(1) : keyId,
      revision: revision,
      name: name,
      fetchedAt: 5,
    );

void main() {
  for (final kind in ['drift', 'memory']) {
    group(kind, () {
      late LocalStore store;
      EncryptedLocalDatabase? db;

      setUp(() async {
        if (kind == 'drift') {
          final database = EncryptedLocalDatabase(NativeDatabase.memory());
          db = database;
          store = _DbStore(database);
        } else {
          db = null;
          store = MemoryLocalStore();
        }
      });
      tearDown(() async => db?.close());

      test('at most four keys stay; the oldest go first', () async {
        for (var n = 1; n <= 6; n++) {
          await store.saveProfileKey(_key(n));
        }
        final held =
            await store.loadProfileKeys(profileSubjectAccount, 'acct_a');
        expect(held.map((k) => k.keyId), [_id(3), _id(4), _id(5), _id(6)]);
      });

      test('the key that opens the cached record is never evicted', () async {
        await store.saveProfileKey(_key(1));
        await store.saveProfile(_profile(2, keyId: _id(1)));
        for (var n = 2; n <= 9; n++) {
          await store.saveProfileKey(_key(n));
        }
        final held =
            await store.loadProfileKeys(profileSubjectAccount, 'acct_a');
        expect(
            held.map((k) => k.keyId).toSet(), {_id(1), _id(7), _id(8), _id(9)});
      });

      test('a key already held keeps its place', () async {
        await store.saveProfileKey(_key(1));
        await store.saveProfileKey(_key(2));
        await store.saveProfileKey(ProfileKeyEffect(
            kind: profileSubjectAccount,
            subjectId: 'acct_a',
            key: Uint8List(32)..[0] = 1,
            keyId: _id(1),
            version: 0,
            receivedAt: 99));
        final held =
            await store.loadProfileKeys(profileSubjectAccount, 'acct_a');
        expect(held.map((k) => k.receivedAt), [1, 2]);
      });

      test('all keys of a kind can be listed', () async {
        await store.saveProfileKey(_key(1));
        await store.saveProfileKey(_key(2, subject: 'acct_b'));
        await store.saveProfileKey(
            _key(3, kind: profileSubjectConversation, subject: 'conv_g'));
        expect(
            (await store.loadAllProfileKeys(profileSubjectAccount))
                .map((k) => k.subjectId)
                .toSet(),
            {'acct_a', 'acct_b'});
        expect(await store.loadAllProfileKeys(profileSubjectConversation),
            hasLength(1));
      });

      test('keys of one subject do not touch another', () async {
        await store.saveProfileKey(_key(1));
        await store.saveProfileKey(
            _key(2, kind: profileSubjectConversation, subject: 'conv_g'));
        expect(await store.loadProfileKeys(profileSubjectAccount, 'acct_a'),
            hasLength(1));
        expect(
            await store.loadProfileKeys(profileSubjectConversation, 'conv_g'),
            hasLength(1));
        expect(await store.loadProfileKeys(profileSubjectAccount, 'acct_b'),
            isEmpty);
      });

      test('an account hint raises the floor; a group hint never does',
          () async {
        await store.saveProfileKey(_key(1, version: 7));
        await store.saveProfileKey(_key(2, version: 3));
        final floor = await store.loadProfile(profileSubjectAccount, 'acct_a');
        expect(floor?.versionFloor, 7);
        expect(floor?.isPlaceholder, isTrue);
        await store.saveProfileKey(_key(3,
            kind: profileSubjectConversation, subject: 'conv_g', version: 99));
        expect(await store.loadProfile(profileSubjectConversation, 'conv_g'),
            isNull);
      });

      test('a placeholder is not a profile and a record keeps the floor',
          () async {
        await store.saveProfileKey(_key(1, version: 4));
        expect(await store.loadProfiles(profileSubjectAccount), isEmpty);
        expect(await store.saveProfile(_profile(5)), isTrue);
        final saved = await store.loadProfile(profileSubjectAccount, 'acct_a');
        expect(saved?.versionFloor, 4);
        expect(saved?.name, 'Ana');
        expect(await store.loadProfiles(profileSubjectAccount), hasLength(1));
      });

      test('a record below the stored revision is refused', () async {
        expect(await store.saveProfile(_profile(5)), isTrue);
        expect(await store.saveProfile(_profile(4, name: 'Old')), isFalse);
        expect(await store.saveProfile(_profile(5, name: 'Same')), isTrue);
        expect((await store.loadProfile(profileSubjectAccount, 'acct_a'))?.name,
            'Same');
      });

      test('a photo round-trips and deleting a subject drops all of it',
          () async {
        final photo = Uint8List.fromList([1, 2, 3, 4]);
        await store.saveProfileKey(_key(1));
        await store.saveProfile(StoredProfile(
            kind: profileSubjectAccount,
            subjectId: 'acct_a',
            serverVersion: 2,
            keyId: _id(1),
            revision: 2,
            name: 'Ana',
            photoPng: photo,
            fetchedAt: 1));
        expect(
            (await store.loadProfile(profileSubjectAccount, 'acct_a'))
                ?.photoPng,
            photo);
        await store.deleteProfileSubject(profileSubjectAccount, 'acct_a');
        expect(
            await store.loadProfile(profileSubjectAccount, 'acct_a'), isNull);
        expect(await store.loadProfileKeys(profileSubjectAccount, 'acct_a'),
            isEmpty);
      });

      test('deleting one key leaves the others', () async {
        await store.saveProfileKey(_key(1));
        await store.saveProfileKey(_key(2));
        await store.deleteProfileKey(profileSubjectAccount, 'acct_a', _id(1));
        expect(
            (await store.loadProfileKeys(profileSubjectAccount, 'acct_a'))
                .map((k) => k.keyId),
            [_id(2)]);
      });

      test('profile state reads, writes, lists by prefix and deletes',
          () async {
        await store.saveProfileState('own.key_id', 'x');
        await store.saveProfileState('due.conv_1', '1');
        await store.saveProfileState('due.conv_2', '1');
        expect(await store.loadProfileState('own.key_id'), 'x');
        expect(await store.loadProfileStatePrefix('due.'),
            {'due.conv_1': '1', 'due.conv_2': '1'});
        await store.saveProfileState('due.conv_1', null);
        expect(await store.loadProfileState('due.conv_1'), isNull);
        await store.saveProfileState('own.key_id', 'y');
        expect(await store.loadProfileState('own.key_id'), 'y');
      });
    });
  }

  test('a key effect applied with the message transaction is stored', () async {
    final db = EncryptedLocalDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.applyMessageEffects([_key(1, version: 2), _key(2)]);
    expect(await db.readProfileKeys(profileSubjectAccount, 'acct_a'),
        hasLength(2));
    expect(
        (await db.readProfile(profileSubjectAccount, 'acct_a'))?.versionFloor,
        2);
  });

  test('an older database gains the profile tables on upgrade', () async {
    final dir = await Directory.systemTemp.createTemp('w11-upgrade-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/p.db');
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    await db.readProfile(profileSubjectAccount, 'acct_a');
    for (final table in [
      'local_profile_keys',
      'local_profiles',
      'local_profile_state',
    ]) {
      await db.customStatement('DROP TABLE $table');
    }
    await db.customStatement('PRAGMA user_version = 26');
    await db.close();

    db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.readProfile(profileSubjectAccount, 'acct_a'), isNull);
    await db.storeProfileKey(_key(1));
    expect(await db.readProfileKeys(profileSubjectAccount, 'acct_a'),
        hasLength(1));
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'),
        EncryptedLocalDatabase.currentSchemaVersion);
  });

  test('sign-out clears every profile table', () async {
    final db = EncryptedLocalDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.storeProfileKey(_key(1, version: 3));
    await db.writeProfileState('own.key_id', 'x');
    await db.clearAll();
    expect(await db.readProfileKeys(profileSubjectAccount, 'acct_a'), isEmpty);
    expect(await db.readProfile(profileSubjectAccount, 'acct_a'), isNull);
    expect(await db.readProfileState('own.key_id'), isNull);
  });

  test('profileKeysToEvict never drops the protected or the newest key', () {
    final keys = [
      for (var n = 1; n <= 6; n++)
        StoredProfileKey(
            kind: profileSubjectAccount,
            subjectId: 's',
            keyId: _id(n),
            key: Uint8List(32),
            receivedAt: n),
    ];
    expect(
        profileKeysToEvict(keys, protectedKeyId: _id(1), newestKeyId: _id(6)),
        [_id(2), _id(3)]);
    expect(profileKeysToEvict(keys.take(4).toList()), isEmpty);
  });
}

/// The profile calls of [SecureLocalStore], straight on a database.
class _DbStore extends MemoryLocalStore {
  _DbStore(this.db);
  final EncryptedLocalDatabase db;

  @override
  Future<List<StoredProfileKey>> loadProfileKeys(
          String kind, String subjectId) =>
      db.readProfileKeys(kind, subjectId);

  @override
  Future<void> saveProfileKey(ProfileKeyEffect key) =>
      db.transaction(() => db.storeProfileKey(key));

  @override
  Future<List<StoredProfileKey>> loadAllProfileKeys(String kind) =>
      db.readAllProfileKeys(kind);

  @override
  Future<void> deleteProfileKey(String kind, String subjectId, String keyId) =>
      db.deleteProfileKey(kind, subjectId, keyId);

  @override
  Future<StoredProfile?> loadProfile(String kind, String subjectId) =>
      db.readProfile(kind, subjectId);

  @override
  Future<List<StoredProfile>> loadProfiles(String kind) =>
      db.readProfiles(kind);

  @override
  Future<bool> saveProfile(StoredProfile profile) => db.writeProfile(profile);

  @override
  Future<void> deleteProfileSubject(String kind, String subjectId) =>
      db.deleteProfileSubject(kind, subjectId);

  @override
  Future<String?> loadProfileState(String name) => db.readProfileState(name);

  @override
  Future<void> saveProfileState(String name, String? value) =>
      db.writeProfileState(name, value);

  @override
  Future<Map<String, String>> loadProfileStatePrefix(String prefix) =>
      db.readProfileStatePrefix(prefix);
}
