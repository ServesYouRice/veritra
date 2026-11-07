import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import 'schema_fixtures.dart';

/// K2 local schema 18 (docs/designs/K2-native-state-migration.md, "Atomic
/// persistence and upgrade rules"): the enrollment promotion ledger and the
/// history transfer progress. Review finding 4 on schema 17: a restore can
/// reactivate a frozen pre-join identity, so the ledger, not an empty MLS
/// state, decides whether an identity was already promoted.

const _origin = 'https://chat.example.org';
const _claimToken = 'claim-SENTINEL-k2s18-token';
final _handoff = utf8.encode('handoff-SENTINEL-k2s18-bytes');
final _stateKey = List<int>.generate(32, (i) => 0xB0 + (i % 16));
final _root = utf8.encode('root-SENTINEL-k2s18-mls');
final _recordSealed = utf8.encode('record-SENTINEL-k2s18-kp');

/// The frozen first state of the new identity, as a seal makes it.
StoredCryptoState _frozenState() => StoredCryptoState(
      counter: 1,
      stateKey: List<int>.from(_stateKey),
      sealedState: List<int>.from(_root),
      changes: [
        CryptoRecordChange(
            kind: cryptoRecordKindDevice,
            recordId: const [],
            generation: 1,
            sealed: utf8.encode('device-record')),
        CryptoRecordChange(
            kind: cryptoRecordKindKeyPackage,
            recordId: const [7, 7],
            generation: 1,
            sealed: _recordSealed),
      ],
    );

const _newSession = Session(
  baseUrl: _origin,
  token: 'tok_new',
  accountId: 'acct_me',
  deviceId: 'dev_new',
  username: 'alice',
  deviceSecret: 'secret_new',
);

const _otherSession = Session(
  baseUrl: _origin,
  token: 'tok_other',
  accountId: 'acct_me',
  deviceId: 'dev_other',
  username: 'alice',
  deviceSecret: 'secret_other',
);

PendingEnrollment _pendingLink({String deviceId = 'dev_new'}) =>
    PendingEnrollment(
      kind: PendingEnrollment.kindDeviceLinkV3,
      origin: _origin,
      accountId: 'acct_me',
      deviceId: deviceId,
      payloadJson: jsonEncode({'claim_token': _claimToken}),
      state: _frozenState(),
    );

HistoryTransferProgress _incoming({
  String stage = HistoryTransferStage.awaitingHandoff,
  String deviceId = 'dev_new',
  List<int>? handoff,
  String? transferId,
  int? size,
  String? path,
  int offset = 0,
}) =>
    HistoryTransferProgress(
      origin: _origin,
      linkId: 'link_1',
      direction: historyTransferIncoming,
      accountId: 'acct_me',
      deviceId: deviceId,
      peerDeviceId: 'dev_old',
      stage: stage,
      expiresAt: DateTime.utc(2026, 11, 13).millisecondsSinceEpoch,
      transferId: transferId,
      ciphertextSha256: transferId == null ? null : List<int>.filled(32, 0x3C),
      ciphertextSize: transferId == null ? null : size ?? 4096,
      handoff: handoff,
      filePath: path,
      fileOffset: offset,
      payloadJson: jsonEncode({'claim_token': _claimToken}),
    );

final _transferId = 'ab' * 32;

EnrollmentPromotion _promotion({
  Session session = _newSession,
  String promotionId = 'request-digest-1',
  StoredCryptoState? state,
  HistoryTransferProgress? transfer,
  String kind = PendingEnrollment.kindDeviceLinkV3,
}) =>
    EnrollmentPromotion(
      kind: kind,
      session: session,
      promotionId: promotionId,
      expectedState: state ?? _frozenState(),
      promotedAt: DateTime.utc(2026, 11, 6, 12),
      transfer: transfer,
    );

Future<File> _tempFile() async {
  final dir = await Directory.systemTemp.createTemp('k2-s18-');
  addTearDown(() => dir.delete(recursive: true));
  return File('${dir.path}/local.db');
}

Future<int> _version(EncryptedLocalDatabase db) async =>
    (await db.customSelect('PRAGMA user_version').getSingle())
        .read<int>('user_version');

/// Fails the next statement [fails] accepts, inside its transaction, while
/// [armed]: a crash at that stage.
class _FailAt extends EncryptedLocalDatabase {
  _FailAt(super.executor, this.fails, {this.armed = true});
  final bool Function(String statement) fails;
  bool armed;

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) async {
    await super.customStatement(statement, args);
    if (armed && fails(statement)) {
      armed = false;
      throw StateError('stopped after a statement');
    }
  }
}

String _sessionJson(Session s) => jsonEncode({
      'base_url': s.baseUrl,
      'token': s.token,
      'account_id': s.accountId,
      'device_id': s.deviceId,
    });

PendingEnrollmentRow _row(PendingEnrollment p) {
  final state = p.state!;
  return PendingEnrollmentRow(
    kind: p.kind,
    origin: p.origin,
    accountId: p.accountId,
    deviceId: p.deviceId,
    payloadJson: p.payloadJson,
    state: PendingEnrollmentState(
      counter: state.counter,
      stateKey: state.stateKey,
      root: state.sealedState,
      records: [
        for (final c in state.changes)
          (
            kind: c.kind,
            recordId: c.recordId,
            generation: c.generation,
            sealed: c.sealed
          ),
      ],
    ),
  );
}

/// A schema 17 database: [session] with an MLS state when [withState], and
/// a pending K2 link for dev_new.
Future<void> _schema17(File file,
    {required Session session, required bool withState}) async {
  final db = EncryptedLocalDatabase(NativeDatabase(file));
  await db.writeSessionJson(_sessionJson(session));
  if (withState) {
    await db.writeCryptoState(
        counter: 6, stateKey: List.filled(32, 2), sealedState: [6], cursor: 9);
  }
  await db.writePendingEnrollment(_row(_pendingLink()));
  await stripK2TransferSchema(db);
  await db.customStatement('PRAGMA user_version = 17');
  await db.close();
}

bool _contains(List<int> haystack, List<int> needle) {
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

  group('schema 18 upgrade', () {
    test('a fresh database has the ledger and transfer tables', () async {
      final db = EncryptedLocalDatabase(NativeDatabase(await _tempFile()));
      addTearDown(db.close);
      expect(EncryptedLocalDatabase.currentSchemaVersion, 18);
      expect(await db.readHistoryTransfers(), isEmpty);
      expect(
          await db.readEnrollmentPromotions(
              accountId: 'acct_me', deviceId: 'dev_new'),
          isEmpty);
      expect(await _version(db), 18);
    });

    test('17 to 18 keeps a pending link another session is waiting on',
        () async {
      final file = await _tempFile();
      await _schema17(file, session: _otherSession, withState: true);
      final db = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect((await db.readPendingEnrollment())?.deviceId, 'dev_new');
      expect((await db.readCryptoState())?.counter, 6);
      expect(await db.readCursor(), 9);
      expect(
          await db.readEnrollmentPromotions(
              accountId: 'acct_me', deviceId: 'dev_new'),
          isEmpty);
      expect(await _version(db), 18);
    });

    test('17 to 18 keeps an activation still owed (same session, no state)',
        () async {
      final file = await _tempFile();
      await _schema17(file, session: _newSession, withState: false);
      final db = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect((await db.readPendingEnrollment())?.deviceId, 'dev_new');
      expect(
          await db.readEnrollmentPromotions(
              accountId: 'acct_me', deviceId: 'dev_new'),
          isEmpty);
    });

    test('17 to 18 ledgers a pending identity that is already active',
        () async {
      final file = await _tempFile();
      await _schema17(file, session: _newSession, withState: true);
      final db = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final ledger = await db.readEnrollmentPromotions(
          accountId: 'acct_me', deviceId: 'dev_new');
      expect(ledger.single.promotionId, promotionIdSchemaUpgrade);
      expect(ledger.single.kind, PendingEnrollment.kindDeviceLinkV3);
      expect(ledger.single.origin, _origin);
      expect(await db.readPendingEnrollment(), isNull);
      expect(
          await db
              .customSelect('SELECT * FROM local_pending_enrollment_records')
              .get(),
          isEmpty);
      // The active state is untouched.
      expect((await db.readCryptoState())?.counter, 6);
      expect(await db.readCursor(), 9);
    });

    test('17 to 18 ledgers an active identity that later signed out', () async {
      final file = await _tempFile();
      await _schema17(file,
          session: const Session(
              baseUrl: _origin,
              token: '',
              accountId: 'acct_me',
              deviceId: 'dev_new',
              deviceSecret: 'secret_new'),
          withState: true);
      final db = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(
          (await db.readEnrollmentPromotions(
                  accountId: 'acct_me', deviceId: 'dev_new'))
              .single
              .promotionId,
          promotionIdSchemaUpgrade);
      expect(await db.readPendingEnrollment(), isNull);
      expect((await db.readCryptoState())?.counter, 6);
    });

    final stages = <String, bool Function(String)>{
      'create ledger': (s) => s
          .startsWith('CREATE TABLE IF NOT EXISTS local_enrollment_promotions'),
      'create transfers': (s) =>
          s.startsWith('CREATE TABLE IF NOT EXISTS local_history_transfers'),
      'ledger insert': (s) =>
          s.startsWith('INSERT INTO local_enrollment_promotions'),
      'pending records delete': (s) =>
          s == 'DELETE FROM local_pending_enrollment_records',
      'pending delete': (s) => s == 'DELETE FROM local_pending_enrollment',
      'version': (s) => s.startsWith('PRAGMA user_version ='),
    };
    for (final stage in stages.entries) {
      test('a crash after ${stage.key} keeps schema 17 and the pending row',
          () async {
        final file = await _tempFile();
        await _schema17(file, session: _newSession, withState: true);

        final failing = _FailAt(NativeDatabase(file), stage.value);
        await expectLater(failing.readCryptoState(), throwsA(anything));
        expect(failing.upgradeStarted, isTrue);
        await failing.close();

        final raw = sqlite3.open(file.path);
        try {
          expect(raw.select('PRAGMA user_version').single['user_version'], 17);
          expect(
              raw.select("SELECT name FROM sqlite_master WHERE type='table' "
                  "AND name IN ('local_enrollment_promotions', "
                  "'local_history_transfers')"),
              isEmpty);
          final pending =
              raw.select('SELECT * FROM local_pending_enrollment').single;
          expect(pending['device_id'], 'dev_new');
          expect(pending['state_key'], _stateKey);
          expect(pending['state_root'], _root);
          expect(raw.select('SELECT * FROM local_pending_enrollment_records'),
              hasLength(2));
        } finally {
          raw.close();
        }

        final db = EncryptedLocalDatabase(NativeDatabase(file));
        addTearDown(db.close);
        expect(await db.readPendingEnrollment(), isNull);
        expect(
            (await db.readEnrollmentPromotions(
                    accountId: 'acct_me', deviceId: 'dev_new'))
                .single
                .promotionId,
            promotionIdSchemaUpgrade);
        expect(await _version(db), 18);
      });
    }

    test('16 to 18 moves a K0 claim, then ledgers it if already active',
        () async {
      // K0 R4's v1 setting for dev_new, whose session and state are stored:
      // schema 16 code activated it and stopped before deleting the claim.
      const legacy = '{"v":1,"origin":"https://chat.example.org",'
          '"username":"alice","account_id":"acct_me","device_id":"dev_new",'
          '"device_name":"Phone","request_id":"arr_1",'
          '"claim_token":"$_claimToken","device_secret":"s",'
          '"ready_at":"2026-11-08T12:30:00.000Z","needs_login":false,'
          '"mls":{"counter":1,'
          '"key":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=",'
          '"root":"cm9vdC12MS1maXh0dXJl","records":[]}}';
      final file = await _tempFile();
      var db = EncryptedLocalDatabase(NativeDatabase(file));
      await db.writeSessionJson(_sessionJson(_newSession));
      await db.writeCryptoState(
          counter: 3,
          stateKey: List.filled(32, 2),
          sealedState: [6],
          cursor: 4);
      await db.writeMetadata('setting:k0.pending_recovery', legacy);
      await stripPendingEnrollmentSchema(db);
      await db.customStatement('PRAGMA user_version = 16');
      await db.close();

      db = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(await db.readPendingEnrollment(), isNull);
      expect(await db.readMetadata('setting:k0.pending_recovery'), isNull);
      final ledger = await db.readEnrollmentPromotions(
          accountId: 'acct_me', deviceId: 'dev_new');
      expect(ledger.single.kind, PendingEnrollment.kindAccountRecovery);
      expect((await db.readCryptoState())?.counter, 3);
      expect(await _version(db), 18);
    });

    test('a downgrade to 17 and a re-upgrade keep the ledger', () async {
      final file = await _tempFile();
      var db = EncryptedLocalDatabase(NativeDatabase(file));
      await db.writePendingEnrollment(_row(_pendingLink()));
      final request = EnrollmentPromotionRequest(
        kind: PendingEnrollment.kindDeviceLinkV3,
        origin: _origin,
        accountId: 'acct_me',
        deviceId: 'dev_new',
        promotionId: 'request-digest-1',
        session: jsonDecode(_sessionJson(_newSession)) as Map<String, Object?>,
        expectedState: _row(_pendingLink()).state!,
        promotedAt: 1,
      );
      expect(await db.promotePendingEnrollment(request),
          EnrollmentPromotionOutcome.promoted);
      await db.customStatement('PRAGMA user_version = 17');
      await db.close();
      db = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(
          await db.readEnrollmentPromotions(
              accountId: 'acct_me', deviceId: 'dev_new'),
          hasLength(1));
      expect(await _version(db), 18);
    });
  });

  group('SQL promotion', () {
    final stages = <String, bool Function(String)>{
      'session': (s) => s.startsWith('INSERT INTO local_accounts'),
      'records clear': (s) => s == 'DELETE FROM local_crypto_records',
      'record insert': (s) => s.startsWith('INSERT INTO local_crypto_records'),
      'state insert': (s) => s.startsWith('INSERT INTO local_crypto_states'),
      'cursor': (s) => s.startsWith('INSERT INTO local_sync_states'),
      'ledger': (s) => s.startsWith('INSERT INTO local_enrollment_promotions'),
      'transfer': (s) =>
          s.startsWith('INSERT OR REPLACE INTO local_history_transfers'),
      'pending records delete': (s) =>
          s == 'DELETE FROM local_pending_enrollment_records',
      'pending delete': (s) => s == 'DELETE FROM local_pending_enrollment',
    };
    for (final stage in stages.entries) {
      test('a crash after the ${stage.key} write changes nothing', () async {
        final file = await _tempFile();
        final db = _FailAt(NativeDatabase(file), stage.value, armed: false);
        addTearDown(db.close);
        await db.writeSessionJson(_sessionJson(
            restoredAccountSession(baseUrl: _origin, accountId: 'acct_me')));
        await db.writePendingEnrollment(_row(_pendingLink()));
        final request = EnrollmentPromotionRequest(
          kind: PendingEnrollment.kindDeviceLinkV3,
          origin: _origin,
          accountId: 'acct_me',
          deviceId: 'dev_new',
          promotionId: 'request-digest-1',
          session:
              jsonDecode(_sessionJson(_newSession)) as Map<String, Object?>,
          expectedState: _row(_pendingLink()).state!,
          promotedAt: 1,
          transfer: _incoming(),
        );
        db.armed = true;
        await expectLater(
            db.promotePendingEnrollment(request), throwsA(isA<StateError>()));

        expect(await db.readCryptoState(), isNull);
        expect(await db.readCryptoRecords(), isEmpty);
        expect(jsonDecode((await db.readSessionJson())!)['token'], '');
        expect(
            await db.readEnrollmentPromotions(
                accountId: 'acct_me', deviceId: 'dev_new'),
            isEmpty);
        expect(await db.readHistoryTransfers(), isEmpty);
        final pending = await db.readPendingEnrollment();
        expect(pending?.state?.root, _root);
        expect(pending?.state?.records, hasLength(2));

        // The retry after the crash promotes.
        expect(await db.promotePendingEnrollment(request),
            EnrollmentPromotionOutcome.promoted);
        expect((await db.readCryptoState())?.counter, 1);
        expect(await db.readHistoryTransfers(), hasLength(1));
      });
    }

    test('a crash while replacing a signed-out identity keeps it whole',
        () async {
      final file = await _tempFile();
      final db = _FailAt(NativeDatabase(file),
          (s) => s.startsWith('INSERT INTO local_accounts'),
          armed: false);
      addTearDown(db.close);
      final signedOut = jsonEncode({
        'base_url': _origin,
        'token': '',
        'account_id': 'acct_me',
        'device_id': 'dev_old',
      });
      await db.writeSessionJson(signedOut);
      await db.writeCryptoState(
          counter: 7,
          stateKey: List.filled(32, 7),
          sealedState: [7],
          cursor: 5);
      await db.writePendingEnrollment(_row(_pendingLink()));
      final request = EnrollmentPromotionRequest(
        kind: PendingEnrollment.kindDeviceLinkV3,
        origin: _origin,
        accountId: 'acct_me',
        deviceId: 'dev_new',
        promotionId: 'request-digest-1',
        session: jsonDecode(_sessionJson(_newSession)) as Map<String, Object?>,
        expectedState: _row(_pendingLink()).state!,
        promotedAt: 1,
      );
      db.armed = true;
      await expectLater(
          db.promotePendingEnrollment(request), throwsA(isA<StateError>()));
      expect(await db.readSessionJson(), signedOut);
      expect((await db.readCryptoState())?.counter, 7);
      expect(await db.readCursor(), 5);
      expect(
          await db.readEnrollmentPromotions(
              accountId: 'acct_me', deviceId: 'dev_new'),
          isEmpty);
      expect((await db.readPendingEnrollment())?.deviceId, 'dev_new');

      expect(await db.promotePendingEnrollment(request),
          EnrollmentPromotionOutcome.promoted);
      expect((await db.readCryptoState())?.counter, 1);
      expect(await db.readCursor(), 0);
    });

    test('a signed-in identity of another device is never replaced', () async {
      final db = EncryptedLocalDatabase(NativeDatabase(await _tempFile()));
      addTearDown(db.close);
      await db.writeSessionJson(_sessionJson(_otherSession));
      await db.writePendingEnrollment(_row(_pendingLink()));
      await expectLater(
          db.promotePendingEnrollment(EnrollmentPromotionRequest(
            kind: PendingEnrollment.kindDeviceLinkV3,
            origin: _origin,
            accountId: 'acct_me',
            deviceId: 'dev_new',
            promotionId: 'request-digest-1',
            session:
                jsonDecode(_sessionJson(_newSession)) as Map<String, Object?>,
            expectedState: _row(_pendingLink()).state!,
            promotedAt: 1,
          )),
          throwsA(isA<EnrollmentPromotionRefused>()));
      expect(await db.readSessionJson(), _sessionJson(_otherSession));
    });

    test('a stale pending row beside its ledger row never loads', () async {
      final db = EncryptedLocalDatabase(NativeDatabase(await _tempFile()));
      addTearDown(db.close);
      await db.writePendingEnrollment(_row(_pendingLink()));
      final request = EnrollmentPromotionRequest(
        kind: PendingEnrollment.kindDeviceLinkV3,
        origin: _origin,
        accountId: 'acct_me',
        deviceId: 'dev_new',
        promotionId: 'request-digest-1',
        session: jsonDecode(_sessionJson(_newSession)) as Map<String, Object?>,
        expectedState: _row(_pendingLink()).state!,
        promotedAt: 1,
      );
      await db.promotePendingEnrollment(request);
      // As an older build (schema 17 code after a downgrade) might leave it.
      await db.customStatement(
          'INSERT INTO local_pending_enrollment (singleton, kind, origin, '
          'account_id, device_id, payload_json, state_counter, state_key, '
          "state_root) VALUES (1, 'k2_link_v3', ?, 'acct_me', 'dev_new', "
          "'{}', 1, ?, ?)",
          [_origin, _stateKey, _root]);
      expect(await db.readPendingEnrollment(), isNull);
      expect(
          await db.customSelect('SELECT * FROM local_pending_enrollment').get(),
          isEmpty);
      await expectLater(db.writePendingEnrollment(_row(_pendingLink())),
          throwsA(isA<PendingEnrollmentConflict>()));
    });
  });

  // The same rules for both stores.
  final stores = <String, Future<LocalStore> Function()>{
    'memory': () async => MemoryLocalStore(),
    'sqlite': () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final directory = await Directory.systemTemp.createTemp('k2-s18-s-');
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
        // The store's rules are under test, not the cipher.
        databaseFactory: (file, keyHex) {
          final database = EncryptedLocalDatabase(NativeDatabase(file));
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

      Future<void> promoted({HistoryTransferProgress? transfer}) async {
        await store.savePendingEnrollment(_pendingLink());
        expect(
            await store
                .promotePendingEnrollment(_promotion(transfer: transfer)),
            EnrollmentPromotionOutcome.promoted);
      }

      test('promotes the frozen identity in one step', () async {
        await store.saveSession(
            restoredAccountSession(baseUrl: _origin, accountId: 'acct_me'));
        await store.saveDraft('conv_1', 'restored draft');
        await promoted(transfer: _incoming());

        final session = (await store.loadSession())!;
        expect(session.deviceId, 'dev_new');
        expect(session.token, 'tok_new');
        final state = (await store.loadCryptoState())!;
        expect(state.counter, 1);
        expect(state.stateKey, _stateKey);
        expect(state.sealedState, _root);
        final records = await store.loadCryptoRecords();
        expect(records, hasLength(2));
        expect(
            records.any((r) =>
                r.kind == cryptoRecordKindKeyPackage &&
                r.sealed.toString() == _recordSealed.toString()),
            isTrue);
        expect(await store.loadSyncCursor(), 0);
        expect(await store.loadPendingEnrollment(), isNull);
        expect(
            await store.isEnrollmentPromoted(
                accountId: 'acct_me', deviceId: 'dev_new'),
            isTrue);
        expect((await store.loadHistoryTransfer(_origin, 'link_1'))?.stage,
            HistoryTransferStage.awaitingHandoff);
        // The restored account's local data stays: no identity reset.
        expect((await store.loadDrafts())['conv_1']?.text, 'restored draft');
      });

      test('a retry after a lost outcome never reopens the frozen state',
          () async {
        await promoted();
        // The identity moves on.
        final next = StoredCryptoState(
            counter: 2,
            stateKey: List<int>.from(_stateKey),
            sealedState: utf8.encode('root-2'));
        await store.commitLocalMlsState(
            expectedCounter: 1, expectedCursor: 0, state: next);
        expect(await store.promotePendingEnrollment(_promotion()),
            EnrollmentPromotionOutcome.alreadyPromoted);
        expect((await store.loadCryptoState())!.counter, 2);
        expect((await store.loadCryptoState())!.sealedState,
            utf8.encode('root-2'));
        await expectLater(
            store.promotePendingEnrollment(_promotion(promotionId: 'other')),
            throwsA(isA<EnrollmentPromotionRefused>()));
        await expectLater(
            store.promotePendingEnrollment(
                _promotion(kind: PendingEnrollment.kindAccountRecovery)),
            throwsA(isA<EnrollmentPromotionRefused>()));
      });

      // Finding 4: each path that empties the MLS state but keeps the
      // identity promoted.
      final emptiers = <String, Future<void> Function(LocalStore)>{
        'a backup restore': (s) async {
          final backup = await s.exportBackup();
          await s.restoreBackup(backup);
        },
        'an identity change and back': (s) async {
          await s.saveSession(_otherSession);
          await s.saveSession(_newSession);
        },
      };
      for (final emptier in emptiers.entries) {
        test('after ${emptier.key} the frozen identity stays dead', () async {
          await store.saveSnapshot(const <Conversation>[],
              const <String, List<ReceivedMessageEnvelope>>{}, 0);
          await promoted(transfer: _incoming());
          await emptier.value(store);
          expect(await store.loadCryptoState(), isNull);
          expect(await store.loadHistoryTransfers(), isEmpty);
          expect(
              await store.isEnrollmentPromoted(
                  accountId: 'acct_me', deviceId: 'dev_new'),
              isTrue);
          // No path brings the frozen state back.
          await expectLater(store.savePendingEnrollment(_pendingLink()),
              throwsA(isA<PendingEnrollmentConflict>()));
          expect(await store.loadPendingEnrollment(), isNull);
          final sessionBefore = await store.loadSession();
          expect(await store.promotePendingEnrollment(_promotion()),
              EnrollmentPromotionOutcome.alreadyPromoted);
          expect(await store.loadCryptoState(), isNull);
          expect((await store.loadSession())?.token, sessionBefore?.token);
          // A new enrollment of another device is unaffected.
          await store.savePendingEnrollment(_pendingLink(deviceId: 'dev_3'));
          expect((await store.loadPendingEnrollment())?.deviceId, 'dev_3');
        });
      }

      test('refuses without a matching pending identity', () async {
        await expectLater(store.promotePendingEnrollment(_promotion()),
            throwsA(isA<EnrollmentPromotionRefused>()));
        await store.savePendingEnrollment(_pendingLink());
        // Another frozen state than the one opened.
        final changed = _frozenState();
        await expectLater(
            store.promotePendingEnrollment(_promotion(
                state: StoredCryptoState(
                    counter: 1,
                    stateKey: changed.stateKey,
                    sealedState: utf8.encode('another root'),
                    changes: changed.changes))),
            throwsA(isA<EnrollmentPromotionRefused>()));
        // A session for another device than the pending one.
        await expectLater(
            store.promotePendingEnrollment(_promotion(session: _otherSession)),
            throwsA(isA<EnrollmentPromotionRefused>()));
        // Another kind than the pending one.
        await expectLater(
            store.promotePendingEnrollment(
                _promotion(kind: PendingEnrollment.kindAccountRecovery)),
            throwsA(isA<EnrollmentPromotionRefused>()));
        expect(await store.loadCryptoState(), isNull);
        expect((await store.loadPendingEnrollment())?.deviceId, 'dev_new');
        expect(
            await store.isEnrollmentPromoted(
                accountId: 'acct_me', deviceId: 'dev_new'),
            isFalse);
      });

      test('refuses over another active identity', () async {
        await store.saveSession(_otherSession);
        await store.savePendingEnrollment(_pendingLink());
        // Another device is signed in.
        await expectLater(store.promotePendingEnrollment(_promotion()),
            throwsA(isA<EnrollmentPromotionRefused>()));
        // An MLS state is stored.
        await store.saveCryptoState(
            StoredCryptoState(
                counter: 4,
                stateKey: List<int>.filled(32, 4),
                sealedState: const [4]),
            3);
        await expectLater(store.promotePendingEnrollment(_promotion()),
            throwsA(isA<EnrollmentPromotionRefused>()));
        expect((await store.loadCryptoState())!.counter, 4);
        expect((await store.loadSession())!.deviceId, 'dev_other');
        expect(await store.loadPendingEnrollment(), isNotNull);
      });

      // A sign-out that kept the device leaves its session (no token) and
      // MLS state; the sign-in screen then offers a recovery or a link. The
      // server has completed the claim by the time it is promoted, so a
      // refusal here would strand the new identity: it replaces the
      // signed-out one, as an identity change does.
      test('replaces a signed-out device of the same account', () async {
        await store.saveSession(const Session(
            baseUrl: _origin,
            token: '',
            accountId: 'acct_me',
            deviceId: 'dev_old',
            deviceSecret: 'secret_old'));
        await store.saveCryptoState(
            StoredCryptoState(
                counter: 7,
                stateKey: List<int>.filled(32, 7),
                sealedState: const [7]),
            5);
        await store.saveDraft('conv_old', 'old draft');
        await promoted(transfer: _incoming());
        final session = (await store.loadSession())!;
        expect(session.deviceId, 'dev_new');
        expect(session.token, 'tok_new');
        final state = (await store.loadCryptoState())!;
        expect(state.counter, 1);
        expect(state.sealedState, _root);
        expect(await store.loadCryptoRecords(), hasLength(2));
        expect(await store.loadSyncCursor(), 0);
        expect(await store.loadDrafts(), isEmpty);
        expect(await store.loadPendingEnrollment(), isNull);
        expect(await store.loadHistoryTransfers(), hasLength(1));
        expect(
            await store.isEnrollmentPromoted(
                accountId: 'acct_me', deviceId: 'dev_new'),
            isTrue);
      });

      test('replaces a signed-out identity of another account', () async {
        await store.saveSession(const Session(
            baseUrl: _origin,
            token: '',
            accountId: 'acct_other',
            deviceId: 'dev_other',
            deviceSecret: 'secret_other'));
        await store.saveCryptoState(
            StoredCryptoState(
                counter: 7,
                stateKey: List<int>.filled(32, 7),
                sealedState: const [7]),
            5);
        await store.saveDraft('conv_old', 'old draft');
        await promoted();
        expect((await store.loadSession())!.accountId, 'acct_me');
        expect((await store.loadCryptoState())!.counter, 1);
        expect(await store.loadDrafts(), isEmpty);
      });

      test('never replaces the pending identity\'s own stored state', () async {
        // Signed out as the pending identity with its MLS state stored: the
        // identity was made active once, so the frozen state stays refused.
        await store.saveSession(const Session(
            baseUrl: _origin,
            token: '',
            accountId: 'acct_me',
            deviceId: 'dev_new',
            deviceSecret: 'secret_new'));
        await store.saveCryptoState(
            StoredCryptoState(
                counter: 4,
                stateKey: List<int>.filled(32, 4),
                sealedState: const [4]),
            3);
        await store.saveDraft('conv_1', 'kept draft');
        await store.savePendingEnrollment(_pendingLink());
        await expectLater(store.promotePendingEnrollment(_promotion()),
            throwsA(isA<EnrollmentPromotionRefused>()));
        expect((await store.loadCryptoState())!.counter, 4);
        expect((await store.loadDrafts())['conv_1']?.text, 'kept draft');
        expect((await store.loadSession())!.token, '');
      });

      test('resumes over a session an older build saved before its state',
          () async {
        await store.saveSession(_newSession);
        await promoted();
        expect((await store.loadCryptoState())!.counter, 1);
      });

      test('clear drops the ledger with the pending enrollment', () async {
        await promoted(transfer: _incoming());
        await store.clear();
        expect(
            await store.isEnrollmentPromoted(
                accountId: 'acct_me', deviceId: 'dev_new'),
            isFalse);
        expect(await store.loadHistoryTransfers(), isEmpty);
        expect(await store.loadPendingEnrollment(), isNull);
      });

      test('a cached clear keeps transfers and the ledger', () async {
        await promoted(transfer: _incoming());
        await store.clearCachedState();
        expect(await store.loadHistoryTransfers(), hasLength(1));
        expect(
            await store.isEnrollmentPromoted(
                accountId: 'acct_me', deviceId: 'dev_new'),
            isTrue);
      });

      group('transfer progress', () {
        test('is only for the active identity', () async {
          await expectLater(store.saveHistoryTransfer(_incoming()),
              throwsA(isA<HistoryTransferConflict>()));
          await promoted();
          await expectLater(
              store.saveHistoryTransfer(_incoming(deviceId: 'dev_x')),
              throwsA(isA<HistoryTransferConflict>()));
          await store.saveHistoryTransfer(_incoming());
          expect(await store.loadHistoryTransfers(), hasLength(1));
        });

        test('freezes the handoff, digest and path; stages only go forward',
            () async {
          await promoted(transfer: _incoming());
          final downloading = _incoming(
              stage: HistoryTransferStage.downloading,
              handoff: _handoff,
              transferId: _transferId,
              path: '/private/k2.part',
              offset: 100);
          await store.saveHistoryTransfer(downloading);
          // A write without the frozen fields keeps them.
          await store.saveHistoryTransfer(downloading.copyWith(fileOffset: 0));
          final kept = (await store.loadHistoryTransfer(_origin, 'link_1'))!;
          expect(kept.handoff, _handoff);
          expect(kept.transferId, _transferId);
          expect(kept.filePath, '/private/k2.part');
          expect(kept.fileOffset, 0);
          for (final changed in <HistoryTransferProgress>[
            _incoming(
                stage: HistoryTransferStage.downloading,
                handoff: utf8.encode('another handoff'),
                transferId: _transferId,
                path: '/private/k2.part'),
            _incoming(
                stage: HistoryTransferStage.downloading,
                handoff: _handoff,
                transferId: 'cd' * 32,
                path: '/private/k2.part'),
            _incoming(
                stage: HistoryTransferStage.downloading,
                handoff: _handoff,
                transferId: _transferId,
                path: '/private/other.part'),
            _incoming(), // back to awaiting the handoff
          ]) {
            await expectLater(store.saveHistoryTransfer(changed),
                throwsA(isA<HistoryTransferConflict>()));
          }
          final done = downloading.copyWith(
              stage: HistoryTransferStage.downloaded, fileOffset: 4096);
          await store.saveHistoryTransfer(done);
          expect((await store.loadHistoryTransfer(_origin, 'link_1'))?.stage,
              HistoryTransferStage.downloaded);
          expect(await store.deleteHistoryTransfer(_origin, 'link_1'), isTrue);
          expect(await store.deleteHistoryTransfer(_origin, 'link_1'), isFalse);
        });

        test('refuses rows a stage cannot resume from', () async {
          await promoted();
          for (final invalid in <HistoryTransferProgress>[
            // Downloading with no handoff or file.
            _incoming(stage: HistoryTransferStage.downloading),
            // Downloaded before the whole file is here.
            _incoming(
                stage: HistoryTransferStage.downloaded,
                handoff: _handoff,
                transferId: _transferId,
                path: '/p',
                offset: 10),
            // An offset past the size.
            _incoming(
                stage: HistoryTransferStage.downloading,
                handoff: _handoff,
                transferId: _transferId,
                path: '/p',
                offset: 5000),
            // A stage of the other direction.
            _incoming(stage: HistoryTransferStage.uploaded),
          ]) {
            await expectLater(store.saveHistoryTransfer(invalid),
                throwsA(isA<FormatException>()));
          }
          expect(await store.loadHistoryTransfers(), isEmpty);
        });

        test('commits with the native state, or not at all', () async {
          await promoted(transfer: _incoming());
          final next = StoredCryptoState(
              counter: 2,
              stateKey: List<int>.from(_stateKey),
              sealedState: utf8.encode('root-2'));
          final downloading = _incoming(
              stage: HistoryTransferStage.downloading,
              handoff: _handoff,
              transferId: _transferId,
              path: '/p');
          await expectLater(
              store.commitHistoryTransferState(
                  expectedCounter: 5,
                  expectedCursor: 0,
                  state: StoredCryptoState(
                      counter: 6,
                      stateKey: List<int>.from(_stateKey),
                      sealedState: utf8.encode('root-6')),
                  transfer: downloading),
              throwsA(anything));
          expect((await store.loadCryptoState())!.counter, 1);
          expect((await store.loadHistoryTransfer(_origin, 'link_1'))?.stage,
              HistoryTransferStage.awaitingHandoff);
          // A refused transfer leaves the state as it was too.
          await expectLater(
              store.commitHistoryTransferState(
                  expectedCounter: 1,
                  expectedCursor: 0,
                  state: next,
                  transfer: _incoming(stage: HistoryTransferStage.downloading)),
              throwsA(anything));
          expect((await store.loadCryptoState())!.counter, 1);
          await store.commitHistoryTransferState(
              expectedCounter: 1,
              expectedCursor: 0,
              state: next,
              transfer: downloading);
          expect((await store.loadCryptoState())!.counter, 2);
          expect((await store.loadHistoryTransfer(_origin, 'link_1'))?.stage,
              HistoryTransferStage.downloading);
          expect(await store.loadSyncCursor(), 0);
        });
      });

      test('neither a backup nor a history snapshot carries them', () async {
        await store.saveSnapshot(const <Conversation>[],
            const <String, List<ReceivedMessageEnvelope>>{}, 0);
        await promoted(
            transfer: _incoming(
                stage: HistoryTransferStage.downloading,
                handoff: _handoff,
                transferId: _transferId,
                path: '/private/SENTINEL-k2s18.part'));
        final backup = await store.exportBackup();
        final history = await store.exportHistorySnapshot();
        for (final forbidden in <List<int>>[
          utf8.encode(_claimToken),
          _handoff,
          utf8.encode(base64Encode(_handoff)),
          utf8.encode('SENTINEL-k2s18.part'),
          utf8.encode('request-digest-1'),
          utf8.encode('link_1'),
          utf8.encode(_transferId),
        ]) {
          expect(_contains(backup, forbidden), isFalse);
          expect(_contains(history, forbidden), isFalse);
        }
      });
    });
  }

  test('rows print no credential, key or handoff', () {
    final text = [
      _incoming(
          stage: HistoryTransferStage.downloading,
          handoff: _handoff,
          transferId: _transferId,
          path: '/p'),
      _promotion(),
      const EnrollmentPromotionRow(
          kind: 'k2_link_v3',
          origin: _origin,
          accountId: 'acct_me',
          deviceId: 'dev_new',
          promotionId: 'request-digest-1',
          promotedAt: 1),
      const EnrollmentPromotionRefused('another session is active'),
      const HistoryTransferConflict('frozen transfer data changed'),
    ].join(' ');
    for (final secret in [
      _claimToken,
      'handoff-SENTINEL',
      'dev_new',
      'acct_me',
      'request-digest-1',
      _transferId,
      'tok_new',
    ]) {
      expect(text, isNot(contains(secret)));
    }
  });
}
