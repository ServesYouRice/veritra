import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/account_recovery.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import 'schema_fixtures.dart';

/// K2 pending-enrollment storage (local schema 17,
/// docs/designs/K2-native-state-migration.md) and the move of K0's waiting
/// recovery claim out of its schema 16 setting (K0 recovery design, client
/// flow step 4).

const _legacyName = 'setting:k0.pending_recovery';
const _claimToken = 'claim-SENTINEL-k2s17-token';
const _deviceSecret = 'secret-SENTINEL-k2s17-device';
final _stateKey = List<int>.generate(32, (i) => 0xA0 + (i % 16));
final _root = utf8.encode('root-SENTINEL-k2s17-mls');
final _recordSealed = utf8.encode('record-SENTINEL-k2s17-group');

PendingAccountRecovery _claim({bool needsLogin = false}) =>
    PendingAccountRecovery(
      origin: 'https://chat.example.org',
      username: 'alice',
      accountId: 'acct_me',
      deviceId: 'dev_new',
      deviceName: 'Phone',
      requestId: 'arr_1',
      claimToken: _claimToken,
      deviceSecret: _deviceSecret,
      readyAt: DateTime.utc(2026, 11, 8, 12, 30),
      needsLogin: needsLogin,
      mlsState: StoredCryptoState(
        counter: 1,
        stateKey: _stateKey,
        sealedState: _root,
        changes: [
          CryptoRecordChange(
              kind: cryptoRecordKindDevice,
              recordId: const [],
              generation: 1,
              sealed: utf8.encode('device-record')),
          CryptoRecordChange(
              kind: cryptoRecordKindKeyPackage,
              recordId: const [9, 8, 7],
              generation: 1,
              sealed: _recordSealed),
          const CryptoRecordChange(
              kind: cryptoRecordKindGroup,
              recordId: [1, 2],
              generation: 1,
              sealed: null),
        ],
      ),
    );

void _expectSameClaim(
    PendingAccountRecovery? actual, PendingAccountRecovery e) {
  expect(actual, isNotNull);
  final a = actual!;
  expect(a.origin, e.origin);
  expect(a.username, e.username);
  expect(a.accountId, e.accountId);
  expect(a.deviceId, e.deviceId);
  expect(a.deviceName, e.deviceName);
  expect(a.requestId, e.requestId);
  expect(a.claimToken, e.claimToken);
  expect(a.deviceSecret, e.deviceSecret);
  expect(a.readyAt, e.readyAt);
  expect(a.needsLogin, e.needsLogin);
  expect(a.mlsState.counter, e.mlsState.counter);
  expect(a.mlsState.stateKey, e.mlsState.stateKey);
  expect(a.mlsState.sealedState, e.mlsState.sealedState);
  expect(a.mlsState.changes, hasLength(e.mlsState.changes.length));
  for (var i = 0; i < e.mlsState.changes.length; i++) {
    final x = a.mlsState.changes[i];
    final y = e.mlsState.changes[i];
    expect(x.kind, y.kind);
    expect(x.recordId, y.recordId);
    expect(x.generation, y.generation);
    expect(x.sealed, y.sealed);
  }
}

/// The row as a [PendingEnrollment], the way [SecureLocalStore] reads it.
PendingEnrollment? _enrollment(PendingEnrollmentRow? row) {
  if (row == null) return null;
  final state = row.state;
  return PendingEnrollment(
    kind: row.kind,
    origin: row.origin,
    accountId: row.accountId,
    deviceId: row.deviceId,
    payloadJson: row.payloadJson,
    state: state == null
        ? null
        : StoredCryptoState(
            counter: state.counter,
            stateKey: state.stateKey,
            sealedState: state.root,
            changes: [
              for (final r in state.records)
                CryptoRecordChange(
                    kind: r.kind,
                    recordId: r.recordId,
                    generation: r.generation,
                    sealed: r.sealed),
            ],
          ),
  );
}

/// Fails the upgrade right after the first statement starting with
/// [prefix] ran, inside its transaction: a crash at that stage.
class _FailAfter extends EncryptedLocalDatabase {
  _FailAfter(super.executor, this.prefix);
  final String prefix;

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) async {
    await super.customStatement(statement, args);
    if (statement.startsWith(prefix)) {
      throw StateError('upgrade stopped at $prefix');
    }
  }
}

Future<File> _tempFile() async {
  final dir = await Directory.systemTemp.createTemp('k2-pending-');
  addTearDown(() => dir.delete(recursive: true));
  return File('${dir.path}/local.db');
}

const _sessionJson =
    '{"base_url":"https://chat.example.org","token":"t","account_id":"acct_me",'
    '"device_id":"dev_old"}';

/// A schema 16 database, optionally holding [legacy] in the K0 setting.
Future<void> _schema16(File file, {String? legacy}) async {
  final db = EncryptedLocalDatabase(NativeDatabase(file));
  await db.writeSessionJson(_sessionJson);
  await db.writeCryptoState(
      counter: 4, stateKey: List.filled(32, 1), sealedState: [5], cursor: 8);
  if (legacy != null) await db.writeMetadata(_legacyName, legacy);
  await db.writeMetadata('setting:k0.recovery_follow_up', 'kept');
  await stripPendingEnrollmentSchema(db);
  await db.customStatement('PRAGMA user_version = 16');
  await db.close();
}

Future<int> _version(EncryptedLocalDatabase db) async =>
    (await db.customSelect('PRAGMA user_version').getSingle())
        .read<int>('user_version');

bool _containsBytes(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('schema 17', () {
    test('a fresh database has the pending-enrollment tables', () async {
      final db = EncryptedLocalDatabase(NativeDatabase(await _tempFile()));
      addTearDown(db.close);
      expect(EncryptedLocalDatabase.currentSchemaVersion, 17);
      expect(await db.readPendingEnrollment(), isNull);
      expect(await _version(db), 17);
    });

    test('16 to 17 with no claim keeps the device state', () async {
      final file = await _tempFile();
      await _schema16(file);
      final db = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(await db.readPendingEnrollment(), isNull);
      expect((await db.readCryptoState())?.counter, 4);
      expect(await db.readCursor(), 8);
      expect(await db.readSessionJson(), _sessionJson);
      expect(await db.readMetadata('setting:k0.recovery_follow_up'), 'kept');
      expect(await _version(db), 17);
    });

    for (final needsLogin in [false, true]) {
      test(
          '16 to 17 moves a waiting K0 claim whole '
          '(needsLogin: $needsLogin)', () async {
        final file = await _tempFile();
        final claim = _claim(needsLogin: needsLogin);
        await _schema16(file, legacy: claim.encode());
        final db = EncryptedLocalDatabase(NativeDatabase(file));
        addTearDown(db.close);
        final row = await db.readPendingEnrollment();
        expect(row?.kind, PendingEnrollment.kindAccountRecovery);
        expect(row?.origin, claim.origin);
        expect(row?.accountId, claim.accountId);
        expect(row?.deviceId, claim.deviceId);
        _expectSameClaim(
            PendingAccountRecovery.fromEnrollment(_enrollment(row)), claim);
        expect(await db.readMetadata(_legacyName), isNull);
        expect(await db.readMetadata('setting:k0.recovery_follow_up'), 'kept');
        expect((await db.readCryptoState())?.counter, 4);
        expect(await _version(db), 17);
      });
    }

    final unreadable = <String, String>{
      'an abandoned claim': '',
      'garbage': '{"v":1,"claim_token":"$_claimToken"',
      'another version': jsonEncode({'v': 2, 'claim_token': _claimToken}),
      'a claim missing its state': jsonEncode(
          Map<String, Object?>.from(jsonDecode(_claim().encode()) as Map)
            ..remove('mls')),
    };
    for (final entry in unreadable.entries) {
      test('16 to 17 drops ${entry.key} and still opens', () async {
        final file = await _tempFile();
        await _schema16(file, legacy: entry.value);
        final db = EncryptedLocalDatabase(NativeDatabase(file));
        addTearDown(db.close);
        expect(await db.readPendingEnrollment(), isNull);
        expect(await db.readMetadata(_legacyName), isNull);
        expect((await db.readCryptoState())?.counter, 4);
        expect(await _version(db), 17);
      });
    }

    const stages = <String>[
      'CREATE TABLE local_pending_enrollment (',
      'CREATE TABLE local_pending_enrollment_records',
      'INSERT INTO local_pending_enrollment (',
      'INSERT INTO local_pending_enrollment_records',
      'DELETE FROM local_metadata WHERE name = ?',
      'PRAGMA user_version =',
    ];
    for (final stage in stages) {
      test('a crash after "$stage" keeps schema 16 and the claim', () async {
        final file = await _tempFile();
        final claim = _claim(needsLogin: true);
        final legacy = claim.encode();
        await _schema16(file, legacy: legacy);

        final failing = _FailAfter(NativeDatabase(file), stage);
        await expectLater(failing.readCryptoState(), throwsA(anything));
        expect(failing.upgradeStarted, isTrue);
        await failing.close();

        final raw = sqlite3.open(file.path);
        try {
          expect(raw.select('PRAGMA user_version').single['user_version'], 16);
          expect(
              raw.select("SELECT name FROM sqlite_master WHERE type='table' "
                  "AND name LIKE 'local_pending_enrollment%'"),
              isEmpty);
          expect(
              raw.select('SELECT value FROM local_metadata WHERE name = ?',
                  [_legacyName]).single['value'],
              legacy);
        } finally {
          raw.close();
        }

        final db = EncryptedLocalDatabase(NativeDatabase(file));
        addTearDown(db.close);
        _expectSameClaim(
            PendingAccountRecovery.fromEnrollment(
                _enrollment(await db.readPendingEnrollment())),
            claim);
        expect(await db.readMetadata(_legacyName), isNull);
        expect(await _version(db), 17);
      });
    }

    test('an upgrade from before 16 also creates the tables', () async {
      final file = await _tempFile();
      var db = EncryptedLocalDatabase(NativeDatabase(file));
      await db.writeCryptoState(
          counter: 2,
          stateKey: List.filled(32, 1),
          sealedState: [5],
          cursor: 1);
      await stripCryptoRecordsSchema(db);
      await db.customStatement('PRAGMA user_version = 15');
      await db.close();
      db = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(await db.readPendingEnrollment(), isNull);
      expect((await db.readCryptoState())?.counter, 2);
      expect(await _version(db), 17);
    });
  });

  group('SQL paths', () {
    late EncryptedLocalDatabase db;
    final claim = _claim();

    setUp(() async {
      db = EncryptedLocalDatabase(NativeDatabase(await _tempFile()));
      addTearDown(db.close);
      await db.writeSessionJson(_sessionJson);
      await db.writePendingEnrollment(_row(claim));
    });

    test('an identity change keeps the claim (its activation may follow)',
        () async {
      await db.writeSessionJson(
          '{"base_url":"https://chat.example.org","token":"t2",'
          '"account_id":"acct_me","device_id":"dev_new"}',
          clearIdentityState: true);
      expect(await db.readPendingEnrollment(), isNotNull);
    });

    test('a cached clear and a backup restore keep the claim', () async {
      await db.clearCachedState();
      await db.restoreBackupState(
          sessionJson: _sessionJson, conversations: [], envelopes: []);
      expect(await db.readPendingEnrollment(), isNotNull);
    });

    test('clearAll drops it', () async {
      await db.clearAll();
      expect(await db.readPendingEnrollment(), isNull);
      expect(
          await db
              .customSelect('SELECT * FROM local_pending_enrollment_records')
              .get(),
          isEmpty);
    });
  });

  // The same rules for both stores.
  final stores = <String, Future<LocalStore> Function()>{
    'memory': () async => MemoryLocalStore(),
    'sqlite': () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final directory = await Directory.systemTemp.createTemp('k2-pending-s-');
      final databases = <EncryptedLocalDatabase>[];
      addTearDown(() async {
        for (final database in databases) {
          await database.close();
        }
        await SecureLocalStore.releaseInstanceLocks();
        await directory.delete(recursive: true);
      });
      return SecureLocalStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
        databaseFactory: (file, keyHex) {
          final database = openEncryptedLocalDatabase(file, keyHex);
          databases.add(database);
          return database;
        },
      );
    },
  };

  for (final entry in stores.entries) {
    group('${entry.key} store', () {
      late LocalStore store;
      setUp(() async => store = await entry.value());

      test('round-trips a claim and updates its fields', () async {
        final claim = _claim();
        await store.savePendingEnrollment(claim.toEnrollment());
        _expectSameClaim(
            PendingAccountRecovery.fromEnrollment(
                await store.loadPendingEnrollment()),
            claim);
        final later = claim.copyWith(needsLogin: true);
        await store.savePendingEnrollment(later.toEnrollment());
        _expectSameClaim(
            PendingAccountRecovery.fromEnrollment(
                await store.loadPendingEnrollment()),
            later);
      });

      test('refuses a second enrollment and a changed identity', () async {
        final claim = _claim();
        await store.savePendingEnrollment(claim.toEnrollment());
        final other = PendingEnrollment(
            kind: PendingEnrollment.kindDeviceLinkV3,
            origin: claim.origin,
            accountId: claim.accountId,
            deviceId: claim.deviceId,
            payloadJson: '{}');
        await expectLater(store.savePendingEnrollment(other),
            throwsA(isA<PendingEnrollmentConflict>()));
        final otherDevice = PendingEnrollment(
            kind: PendingEnrollment.kindAccountRecovery,
            origin: claim.origin,
            accountId: claim.accountId,
            deviceId: 'dev_other',
            payloadJson: claim.encodePayload(),
            state: claim.mlsState);
        await expectLater(store.savePendingEnrollment(otherDevice),
            throwsA(isA<PendingEnrollmentConflict>()));
        final regenerated = PendingEnrollment(
            kind: PendingEnrollment.kindAccountRecovery,
            origin: claim.origin,
            accountId: claim.accountId,
            deviceId: claim.deviceId,
            payloadJson: claim.encodePayload(),
            state: StoredCryptoState(
                counter: 1,
                stateKey: List.filled(32, 3),
                sealedState: claim.mlsState.sealedState));
        await expectLater(store.savePendingEnrollment(regenerated),
            throwsA(isA<PendingEnrollmentConflict>()));
        _expectSameClaim(
            PendingAccountRecovery.fromEnrollment(
                await store.loadPendingEnrollment()),
            claim);
      });

      test('a K2 reservation gets its identity once, then keeps it', () async {
        const reservation = PendingEnrollment(
            kind: PendingEnrollment.kindDeviceLinkV3,
            origin: 'https://chat.example.org',
            accountId: 'acct_me',
            deviceId: 'dev_new',
            payloadJson: '{"stage":"reserved"}');
        await store.savePendingEnrollment(reservation);
        expect((await store.loadPendingEnrollment())?.state, isNull);
        final sealed = _claim().mlsState;
        await store.savePendingEnrollment(PendingEnrollment(
            kind: reservation.kind,
            origin: reservation.origin,
            accountId: reservation.accountId,
            deviceId: reservation.deviceId,
            payloadJson: '{"stage":"claim_frozen"}',
            state: sealed));
        // A later write without a state keeps the stored identity.
        await store.savePendingEnrollment(PendingEnrollment(
            kind: reservation.kind,
            origin: reservation.origin,
            accountId: reservation.accountId,
            deviceId: reservation.deviceId,
            payloadJson: '{"stage":"claimed"}'));
        final loaded = await store.loadPendingEnrollment();
        expect(loaded?.payloadJson, '{"stage":"claimed"}');
        expect(loaded?.state?.stateKey, sealed.stateKey);
        expect(loaded?.state?.sealedState, sealed.sealedState);
        expect(loaded?.state?.changes, hasLength(3));
      });

      test('deletes only its own kind and device; clear drops it', () async {
        final claim = _claim();
        await store.savePendingEnrollment(claim.toEnrollment());
        expect(
            await store.deletePendingEnrollment(
                kind: PendingEnrollment.kindDeviceLinkV3),
            isFalse);
        expect(
            await store.deletePendingEnrollment(
                kind: PendingEnrollment.kindAccountRecovery,
                deviceId: 'dev_other'),
            isFalse);
        expect(await store.loadPendingEnrollment(), isNotNull);
        expect(
            await store.deletePendingEnrollment(
                kind: PendingEnrollment.kindAccountRecovery,
                deviceId: claim.deviceId),
            isTrue);
        expect(await store.loadPendingEnrollment(), isNull);

        await store.savePendingEnrollment(claim.toEnrollment());
        await store.clear();
        expect(await store.loadPendingEnrollment(), isNull);
      });

      test('a session change to another device keeps it', () async {
        await store.saveSession(const Session(
            baseUrl: 'https://chat.example.org',
            token: 'tok',
            accountId: 'acct_me',
            deviceId: 'dev_old'));
        await store.savePendingEnrollment(_claim().toEnrollment());
        await store.saveSession(const Session(
            baseUrl: 'https://chat.example.org',
            token: 'tok2',
            accountId: 'acct_me',
            deviceId: 'dev_new'));
        expect(await store.loadPendingEnrollment(), isNotNull);
      });
    });
  }

  test('neither a backup nor a history snapshot carries it (D71, D73)',
      () async {
    final store = await stores['sqlite']!();
    await store.saveSession(const Session(
        baseUrl: 'https://chat.example.org',
        token: 'tok',
        accountId: 'acct_me',
        deviceId: 'dev_old',
        username: 'alice',
        deviceSecret: 'old-secret'));
    await store.saveCryptoState(
        StoredCryptoState(
            counter: 1,
            stateKey: List<int>.filled(32, 1),
            sealedState: utf8.encode('device-state')),
        0);
    await store.saveSnapshot(
        <Conversation>[Conversation(id: 'conv_1', kind: 'dm', title: 'Chat')],
        const <String, List<ReceivedMessageEnvelope>>{},
        0);
    await store.savePendingEnrollment(_claim().toEnrollment());
    expect(await store.loadPendingEnrollment(), isNotNull);

    final backup = await store.exportBackup();
    final history = await store.exportHistorySnapshot();
    for (final forbidden in <List<int>>[
      utf8.encode(_claimToken),
      utf8.encode(_deviceSecret),
      utf8.encode('dev_new'),
      utf8.encode('arr_1'),
      utf8.encode(base64Encode(_stateKey)),
      _stateKey,
      _root,
      utf8.encode(base64Encode(_root)),
      _recordSealed,
      utf8.encode(base64Encode(_recordSealed)),
    ]) {
      expect(_containsBytes(backup, forbidden), isFalse,
          reason: 'backup: ${utf8.decode(forbidden, allowMalformed: true)}');
      expect(_containsBytes(history, forbidden), isFalse,
          reason: 'history: ${utf8.decode(forbidden, allowMalformed: true)}');
    }
    expect(utf8.decode(backup), contains('acct_me'));
  });
}

PendingEnrollmentRow _row(PendingAccountRecovery claim) {
  final state = claim.mlsState;
  return (
    kind: PendingEnrollment.kindAccountRecovery,
    origin: claim.origin,
    accountId: claim.accountId,
    deviceId: claim.deviceId,
    payloadJson: claim.encodePayload(),
    state: (
      counter: state.counter,
      stateKey: state.stateKey,
      root: state.sealedState,
      records: [
        for (final c in state.changes)
          (
            kind: c.kind,
            recordId: c.recordId,
            generation: c.generation,
            sealed: c.sealed,
          ),
      ],
    ),
  );
}
