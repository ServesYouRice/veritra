import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import 'schema_fixtures.dart';

/// Fails onUpgrade right after it wrote the new version, inside its
/// transaction.
class _FailAfterVersion extends EncryptedLocalDatabase {
  _FailAfterVersion(super.executor);

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) async {
    await super.customStatement(statement, args);
    if (statement.startsWith('PRAGMA user_version =')) {
      throw StateError('upgrade failed after the version was written');
    }
  }
}

const _session = Session(
    baseUrl: 'https://example.test',
    token: 't',
    accountId: 'acct_a',
    deviceId: 'dev_a');

const _sessionJson =
    '{"base_url":"https://example.test","token":"t","account_id":"acct_a",'
    '"device_id":"dev_a"}';

Future<int> _version(EncryptedLocalDatabase db) async =>
    (await db.customSelect('PRAGMA user_version').getSingle())
        .read<int>('user_version');

Future<bool> _hasRecordsTable(EncryptedLocalDatabase db) async => (await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table' "
            "AND name='local_crypto_records'")
        .get())
    .isNotEmpty;

Future<void> _seedRecords(EncryptedLocalDatabase db) async {
  await db.customStatement(
      'INSERT INTO local_crypto_records (kind, record_id, generation, sealed) '
      "VALUES (2, x'0102', 3, x'aa'), (1, x'', 3, x'bb')");
}

Future<void> _seedState(EncryptedLocalDatabase db) async {
  await db.writeSessionJson(_sessionJson);
  await db.writeCryptoState(
      counter: 3, stateKey: List.filled(32, 7), sealedState: [9], cursor: 5);
  await _seedRecords(db);
}

Future<(Directory, File)> _tempFile() async {
  final dir = await Directory.systemTemp.createTemp('d70-records-');
  addTearDown(() => dir.delete(recursive: true));
  return (dir, File('${dir.path}/local.db'));
}

void main() {
  test('fresh create has the records table at schema 16', () async {
    final (_, file) = await _tempFile();
    final db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.readCryptoRecords(), isEmpty);
    expect(await _hasRecordsTable(db), isTrue);
    expect(EncryptedLocalDatabase.currentSchemaVersion, 16);
    expect(await _version(db), 16);
  });

  test('schema 15 upgrades to 16 keeping crypto state and history', () async {
    final (_, file) = await _tempFile();
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    await db.writeSessionJson(_sessionJson);
    await db.writeCryptoState(
        counter: 4,
        stateKey: List.filled(32, 1),
        sealedState: [5, 6],
        cursor: 8);
    await stripCryptoRecordsSchema(db);
    await db.customStatement('PRAGMA user_version = 15');
    await db.close();

    db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final state = await db.readCryptoState();
    expect(state?.counter, 4);
    expect(state?.sealedState, [5, 6]);
    expect(await db.readCursor(), 8);
    expect(await db.readSessionJson(), _sessionJson);
    expect(await _hasRecordsTable(db), isTrue);
    expect(await db.readCryptoRecords(), isEmpty);
    expect(await _version(db), 16);
  });

  test('a failed 15 to 16 upgrade rolls back and the next open retries it',
      () async {
    final (_, file) = await _tempFile();
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    await db.writeCryptoState(
        counter: 2, stateKey: List.filled(32, 1), sealedState: [5], cursor: 1);
    await stripCryptoRecordsSchema(db);
    await db.customStatement('PRAGMA user_version = 15');
    await db.close();

    final failing = _FailAfterVersion(NativeDatabase(file));
    await expectLater(failing.readCryptoState(), throwsA(anything));
    expect(failing.upgradeStarted, isTrue);
    await failing.close();

    final raw = sqlite3.open(file.path);
    try {
      expect(raw.select('PRAGMA user_version').single['user_version'], 15);
      expect(
          raw.select("SELECT name FROM sqlite_master WHERE type='table' "
              "AND name='local_crypto_records'"),
          isEmpty);
    } finally {
      raw.close();
    }

    db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect((await db.readCryptoState())?.counter, 2);
    expect(await _hasRecordsTable(db), isTrue);
    expect(await _version(db), 16);
  });

  test('records read back ordered by kind, then id bytes', () async {
    final (_, file) = await _tempFile();
    final db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await _seedRecords(db);
    final rows = await db.readCryptoRecords();
    expect(
        rows.map((r) => '${r.kind}:${r.recordId.join(',')}:${r.generation}'), [
      '1::3',
      '2:1,2:3',
    ]);
  });

  group('every SQL path that deletes the crypto state deletes the records', () {
    late EncryptedLocalDatabase db;

    setUp(() async {
      final (_, file) = await _tempFile();
      db = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(db.close);
      await _seedState(db);
      expect(await db.readCryptoRecords(), hasLength(2));
    });

    final paths = <String, Future<void> Function(EncryptedLocalDatabase)>{
      'identity reset (sign-in as a new identity)': (db) =>
          db.writeSessionJson(_sessionJson, clearIdentityState: true),
      'legacy import': (db) => db.importLegacy(
          sessionJson: _sessionJson,
          conversations: const [],
          envelopes: const [],
          outbox: const [],
          cryptoState: (
            counter: 1,
            stateKey: List.filled(32, 2),
            sealedState: [1]
          ),
          cursor: 0),
      'backup restore': (db) => db.restoreBackupState(
          sessionJson: _sessionJson, conversations: [], envelopes: []),
      'clearAll (clear, sign-out wipe, quarantine)': (db) => db.clearAll(),
    };
    for (final entry in paths.entries) {
      test(entry.key, () async {
        await entry.value(db);
        expect(await db.readCryptoRecords(), isEmpty);
      });
    }

    test('paths that keep the crypto state keep the records', () async {
      await db.clearCachedState();
      await db.writeSessionJson(null);
      await db.writeSessionJson(_sessionJson);
      await db.commitLocalMlsState(
          expectedCounter: 3,
          expectedCursor: 5,
          counter: 4,
          stateKey: List.filled(32, 7),
          sealedState: [10]);
      expect((await db.readCryptoState())?.counter, 4);
      expect(await db.readCryptoRecords(), hasLength(2));
    });
  });

  group('MemoryLocalStore drops records with the crypto state', () {
    final seed = [
      StoredCryptoRecord(kind: 2, recordId: [9], generation: 1, sealed: [1]),
      StoredCryptoRecord(kind: 1, recordId: [], generation: 1, sealed: [2]),
      StoredCryptoRecord(kind: 2, recordId: [1, 0], generation: 1, sealed: [3]),
    ];

    Future<MemoryLocalStore> seeded() async {
      final store = MemoryLocalStore();
      await store.saveSession(_session);
      await store.commitLocalMlsState(
          expectedCounter: 0,
          expectedCursor: 0,
          state: StoredCryptoState(
              counter: 1, stateKey: List.filled(32, 3), sealedState: [4]));
      store.seedCryptoRecordsForTest(seed);
      expect(
          (await store.loadCryptoRecords())
              .map((r) => '${r.kind}:${r.recordId.join(',')}'),
          [
            '1:',
            '2:1,0',
            '2:9',
          ]);
      return store;
    }

    test('identity change', () async {
      final store = await seeded();
      await store.saveSession(const Session(
          baseUrl: 'https://example.test',
          token: 't',
          accountId: 'acct_b',
          deviceId: 'dev_b'));
      expect(await store.loadCryptoRecords(), isEmpty);
    });

    test('backup restore', () async {
      final store = await seeded();
      final backup = await store.exportBackup();
      await store.restoreBackup(backup);
      expect(await store.loadCryptoRecords(), isEmpty);
    });

    test('clear', () async {
      final store = await seeded();
      await store.clear();
      expect(await store.loadCryptoRecords(), isEmpty);
    });

    test('quarantine reset', () async {
      final store = await seeded();
      await store.quarantineUnreadableDatabase(confirmed: true);
      expect(await store.loadCryptoRecords(), isEmpty);
    });

    test('cached-state clear and same-identity sign-in keep them', () async {
      final store = await seeded();
      await store.clearCachedState();
      await store.saveSession(_session);
      expect(await store.loadCryptoRecords(), hasLength(3));
    });
  });
}
