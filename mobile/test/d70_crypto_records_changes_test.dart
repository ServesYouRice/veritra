import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// D70 S3: the sealed MLS records change only together with the root
/// singleton, in the same SQLite transaction.

final _key = List<int>.filled(32, 7);

CryptoRecordWrite _put(int kind, List<int> id, int generation, int byte) =>
    (kind: kind, recordId: id, generation: generation, sealed: [byte, byte]);

CryptoRecordWrite _drop(int kind, List<int> id, int generation) =>
    (kind: kind, recordId: id, generation: generation, sealed: null);

Future<EncryptedLocalDatabase> _db() async {
  final dir = await Directory.systemTemp.createTemp('d70-changes-');
  addTearDown(() => dir.delete(recursive: true));
  final db = EncryptedLocalDatabase(NativeDatabase(File('${dir.path}/l.db')));
  addTearDown(db.close);
  return db;
}

Future<List<String>> _rows(EncryptedLocalDatabase db) async => [
      for (final r in await db.readCryptoRecords())
        '${r.kind}:${r.recordId.join(',')}:${r.generation}:${r.sealed.first}'
    ];

Future<void> _seed(EncryptedLocalDatabase db) => db.writeCryptoState(
    counter: 1,
    stateKey: _key,
    sealedState: [1],
    cursor: 3,
    recordChanges: [
      _put(1, [], 1, 10),
      _put(2, [5], 1, 20),
      _put(3, [9, 9], 1, 30),
    ]);

StoredCryptoState _state(int counter, List<CryptoRecordChange> changes) =>
    StoredCryptoState(
        counter: counter,
        stateKey: _key,
        sealedState: [counter],
        changes: changes);

CryptoRecordChange _change(int kind, List<int> id, int generation,
        [List<int>? sealed = const [1]]) =>
    CryptoRecordChange(
        kind: kind, recordId: id, generation: generation, sealed: sealed);

void main() {
  group('database', () {
    test('a full write replaces every earlier record', () async {
      final db = await _db();
      await _seed(db);
      expect(await _rows(db), ['1::1:10', '2:5:1:20', '3:9,9:1:30']);
      await db.writeCryptoState(
          counter: 2,
          stateKey: _key,
          sealedState: [2],
          cursor: 3,
          recordChanges: [_put(1, [], 2, 11)]);
      expect(await _rows(db), ['1::2:11']);
    });

    test('a local transition upserts and deletes with the root', () async {
      final db = await _db();
      await _seed(db);
      await db.commitLocalMlsState(
          expectedCounter: 1,
          expectedCursor: 3,
          counter: 2,
          stateKey: _key,
          sealedState: [
            2
          ],
          recordChanges: [
            _put(2, [5], 2, 21),
            _put(2, [6], 2, 22),
            _drop(3, [9, 9], 2),
          ]);
      expect(await _rows(db), ['1::1:10', '2:5:2:21', '2:6:2:22']);
      expect((await db.readCryptoState())?.sealedState, [2]);
    });

    test('a stale transition writes no record', () async {
      final db = await _db();
      await _seed(db);
      await expectLater(
          db.commitLocalMlsState(
              expectedCounter: 0,
              expectedCursor: 3,
              counter: 1,
              stateKey: _key,
              sealedState: [
                2
              ],
              recordChanges: [
                _drop(2, [5], 1)
              ]),
          throwsStateError);
      expect(await _rows(db), hasLength(3));
    });

    test('a failure after the records rolls them back with the root', () async {
      final db = await _db();
      await _seed(db);
      await expectLater(
          db.commitMlsTransition(
              messageId: 'm1',
              conversationId: 'c1',
              expectedCounter: 1,
              expectedCursor: 3,
              counter: 2,
              stateKey: _key,
              sealedState: [2],
              cursor: 4,
              upsertedEnvelopes: const [],
              deletedEnvelopeIds: const [],
              recordChanges: [
                _drop(2, [5], 2),
                _put(3, [1], 2, 40)
              ],
              failureInjector: (stage) async {
                if (stage == MlsCommitStage.afterRecords) {
                  throw StateError('injected');
                }
              }),
          throwsStateError);
      expect(await _rows(db), ['1::1:10', '2:5:1:20', '3:9,9:1:30']);
      expect((await db.readCryptoState())?.counter, 1);
    });

    test('the snapshot holds the root and its records', () async {
      final db = await _db();
      await _seed(db);
      final snapshot = await db.readCryptoSnapshot();
      expect(snapshot.state?.counter, 1);
      expect(snapshot.records, hasLength(3));
    });

    group('migration', () {
      Future<void> migrate(EncryptedLocalDatabase db,
              {int expectedCounter = 1,
              List<int> expected = const [1],
              int counter = 2,
              MlsCommitFailureInjector? failureInjector}) =>
          db.commitCryptoMigration(
              expectedCounter: expectedCounter,
              expectedSealedState: expected,
              counter: counter,
              stateKey: _key,
              sealedState: [4, 0],
              recordChanges: [
                _put(1, [], 2, 50),
                _put(2, [7], 2, 51)
              ],
              failureInjector: failureInjector);

      test('replaces the blob, drops leftovers and keeps the cursor', () async {
        final db = await _db();
        await _seed(db);
        await migrate(db);
        expect(await _rows(db), ['1::2:50', '2:7:2:51']);
        final state = await db.readCryptoState();
        expect(state?.counter, 2);
        expect(state?.sealedState, [4, 0]);
        expect(await db.readCursor(), 3);
      });

      test('refuses a changed or stale state', () async {
        final db = await _db();
        await _seed(db);
        await expectLater(migrate(db, expected: [9]), throwsStateError);
        await expectLater(
            migrate(db, expectedCounter: 0, counter: 1), throwsStateError);
        await expectLater(migrate(db, counter: 3), throwsStateError);
        expect(await _rows(db), hasLength(3));
        expect((await db.readCryptoState())?.sealedState, [1]);
      });

      for (final stage in [
        MlsCommitStage.afterValidation,
        MlsCommitStage.afterRecords,
        MlsCommitStage.afterState,
      ]) {
        test('a crash at ${stage.name} leaves the old state whole', () async {
          final db = await _db();
          await _seed(db);
          await expectLater(
              migrate(db, failureInjector: (current) async {
                if (current == stage) throw StateError('injected');
              }),
              throwsStateError);
          expect(await _rows(db), hasLength(3));
          expect((await db.readCryptoState())?.sealedState, [1]);
          await migrate(db);
          expect((await db.readCryptoState())?.counter, 2);
        });
      }
    });
  });

  group('MemoryLocalStore', () {
    test('applies changes with each state write', () async {
      final store = MemoryLocalStore();
      await store.saveCryptoState(
          _state(1, [
            _change(1, [], 1),
            _change(2, [5], 1),
          ]),
          0);
      await store.commitLocalMlsState(
          expectedCounter: 1,
          expectedCursor: 0,
          state: _state(2, [
            _change(2, [5], 2, null),
            _change(3, [8], 2),
          ]));
      final snapshot = await store.loadCryptoSnapshot();
      expect(snapshot.state?.counter, 2);
      expect(snapshot.state?.changes, isEmpty);
      expect(
          snapshot.records.map((r) => '${r.kind}:${r.recordId.join(',')}:'
              '${r.generation}'),
          ['1::1', '3:8:2']);
      await store.saveCryptoState(_state(3, [_change(1, [], 3)]), 0);
      expect(await store.loadCryptoRecords(), hasLength(1));
    });

    test('refuses changes from another generation or naming a record twice',
        () async {
      final store = MemoryLocalStore();
      for (final changes in [
        [
          _change(2, [5], 2)
        ],
        [_change(0, [], 1)],
        [
          _change(4, [1], 1)
        ],
        [
          _change(1, [1], 1)
        ],
        [_change(2, [], 1)],
        [_change(2, List.filled(256, 1), 1)],
        [
          _change(2, [5], 1, const [])
        ],
        [
          _change(2, [5], 1),
          _change(2, [5], 1, null)
        ],
      ]) {
        await expectLater(store.saveCryptoState(_state(1, changes), 0),
            throwsFormatException);
      }
      expect(await store.loadCryptoState(), isNull);
    });

    test('migrates by compare-and-swap and drops leftovers', () async {
      final store = MemoryLocalStore();
      await store.saveCryptoState(
          StoredCryptoState(counter: 4, stateKey: _key, sealedState: [3]), 2);
      store.seedCryptoRecordsForTest([
        StoredCryptoRecord(kind: 2, recordId: [1], generation: 9, sealed: [1]),
      ]);
      final next = _state(5, [
        _change(1, [], 5),
        _change(2, [6], 5)
      ]);
      await expectLater(
          store.commitCryptoMigration(
              expectedCounter: 4, expectedSealedState: [2], state: next),
          throwsStateError);
      await expectLater(
          store.commitCryptoMigration(
              expectedCounter: 4,
              expectedSealedState: [3],
              state: _state(5, [
                _change(2, [6], 5)
              ])),
          throwsFormatException);
      await store.commitCryptoMigration(
          expectedCounter: 4, expectedSealedState: [3], state: next);
      final records = await store.loadCryptoRecords();
      expect(records.map((r) => '${r.kind}:${r.recordId.join(',')}'),
          ['1:', '2:6']);
      expect(await store.loadSyncCursor(), 2);
    });
  });
}
