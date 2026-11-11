import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

class _FailUpgrade extends EncryptedLocalDatabase {
  _FailUpgrade(super.executor);

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) async {
    await super.customStatement(statement, args);
    if (statement.contains('CREATE TABLE IF NOT EXISTS local_governance')) {
      throw StateError('simulated storage failure during upgrade');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 11, 11, 1, 2, 3, 4, 5);
  final genesis = GovernanceState.genesis('owner');
  final open = genesis.copyWith(
      rev: 1, election: Election(opened: 1, electorate: {'alice'}));
  const session = Session(
      baseUrl: 'https://chat.example.org',
      token: 'token',
      accountId: 'owner',
      deviceId: 'device');

  GovernanceObservationChange change(GovernanceState state, DateTime at,
          {String sender = 'alice', String group = 'shared'}) =>
      GovernanceObservationChange(
          groupId: group,
          state: state,
          authenticatedSender: sender,
          receivedAt: at);

  StoredCryptoState crypto(int counter,
          {List<CryptoRecordChange> changes = const []}) =>
      StoredCryptoState(
          counter: counter,
          stateKey: List.filled(32, 1),
          sealedState: [counter],
          changes: changes);

  MlsStateTransition transition(
          int previous, GovernanceObservationChange observation,
          {int? cursor, String? id}) =>
      MlsStateTransition(
          messageId: id ?? 'event_${previous + 1}',
          conversationId: 'conversation',
          expectedCounter: previous,
          expectedCursor: cursor ?? previous,
          cursor: (cursor ?? previous) + 1,
          state: crypto(previous + 1),
          governanceObservation: observation);

  late Directory directory;
  final databases = <EncryptedLocalDatabase>[];
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.current.createTemp('c4-observations-');
  });
  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
    await SecureLocalStore.releaseInstanceLocks();
    await directory.delete(recursive: true);
  });

  SecureLocalStore secure({MlsCommitFailureInjector? failure}) =>
      SecureLocalStore(
          storage: const FlutterSecureStorage(),
          directoryProvider: () async => directory,
          mlsCommitFailureInjector: failure,
          databaseFactory: (file, keyHex) {
            final database = openEncryptedLocalDatabase(file, keyHex);
            databases.add(database);
            return database;
          });

  Future<void> closeDatabases() async {
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
  }

  for (final memory in [true, false]) {
    final label = memory ? 'memory' : 'SQLite';
    LocalStore store() => memory ? MemoryLocalStore() : secure();

    test('$label: accepted events preserve waits; owner activity blocks a vote',
        () async {
      final s = store();
      await s.commitMlsTransition(transition(0, change(genesis, now)));
      final first = await s.loadGovernanceObservations('shared');
      expect(first, GovernanceObservations.firstSeen(genesis, now));
      final openedAt = now.add(ownerInactivityWait);
      await s.commitMlsTransition(transition(1, change(open, openedAt)));
      final seen = (await s.loadGovernanceObservations('shared'))!;
      expect(seen.lastOwnerActivity, now);
      expect(seen.electionSeen, openedAt);
      await s.commitMlsTransition(
          transition(2, change(open, openedAt.add(electionWait))));
      expect(await s.loadGovernanceObservations('shared'), seen);
      expect(
          mayVoteNow(
              now: openedAt.add(electionWait),
              openedSeen: seen.electionSeen!,
              lastOwnerActivity: seen.lastOwnerActivity),
          isTrue);
      final ownerAt = openedAt.add(electionWait);
      await s.commitMlsTransition(
          transition(3, change(open, ownerAt, sender: 'owner')));
      final active = (await s.loadGovernanceObservations('shared'))!;
      expect(active.lastOwnerActivity, ownerAt);
      expect(active.electionSeen, openedAt);
      expect(
          mayVoteNow(
              now: ownerAt,
              openedSeen: active.electionSeen!,
              lastOwnerActivity: active.lastOwnerActivity),
          isFalse);
      await s.commitMlsTransition(
          transition(4, change(open, now, sender: 'owner')));
      expect(await s.loadGovernanceObservations('shared'), active);
      final cancelled = open.copyWith(rev: 2, clearElection: true);
      await s.commitMlsTransition(
          transition(5, change(cancelled, ownerAt, sender: 'owner')));
      expect(
          (await s.loadGovernanceObservations('shared'))!.electionSeen, isNull);
      expect(await s.loadGovernanceObservations('another-group'), isNull);
    });

    test('$label: replay and stale counter cannot overwrite observations',
        () async {
      final s = store();
      await s.commitMlsTransition(transition(0, change(genesis, now)));
      final before = await s.loadGovernanceObservations('shared');
      await expectLater(
          s.commitMlsTransition(
              transition(0, change(open, now.add(ownerInactivityWait)))),
          throwsStateError);
      await expectLater(
          s.commitMlsTransition(transition(
              1, change(open, now.add(ownerInactivityWait)),
              id: 'event_1')),
          throwsStateError);
      expect(await s.loadGovernanceObservations('shared'), before);
      expect((await s.loadCryptoState())!.counter, 1);
      expect(await s.loadSyncCursor(), 1);
    });

    test(
        '$label: own messages and accepted local commits update clocks atomically',
        () async {
      final s = store();
      await s.commitMlsTransition(transition(0, change(open, now)));
      final at = now.add(const Duration(days: 2));
      final outgoing = OutgoingApplicationStateTransition(
          expectedCounter: 1,
          expectedCursor: 1,
          state: crypto(2),
          envelope: MessageEnvelope(
              conversationId: 'conversation',
              idempotencyKey: 'outgoing',
              ciphertext: [1],
              cryptoProtocol: 'mls10-openmls-v1'),
          governanceObservation: change(open, at, sender: 'owner'));
      await s.commitOutgoingApplicationTransition(outgoing);
      expect((await s.loadGovernanceObservations('shared'))!.lastOwnerActivity,
          at);
      await expectLater(
          s.commitOutgoingApplicationTransition(outgoing), throwsStateError);
      final transferred = open.copyWith(
          rev: 2, owner: 'alice', ownerRev: 2, clearElection: true);
      await s.commitLocalMlsState(
          expectedCounter: 2,
          expectedCursor: 1,
          state: crypto(3),
          governanceObservation: change(
              transferred, at.add(const Duration(days: 1)),
              sender: 'owner'));
      final observed = (await s.loadGovernanceObservations('shared'))!;
      expect(observed.owner, 'alice');
      expect(observed.ownerRev, 2);
      expect(observed.lastOwnerActivity, at.add(const Duration(days: 1)));
      expect(observed.electionSeen, isNull);
    });

    test('$label: clocks follow crypto lifetime and never travel in a backup',
        () async {
      final s = store();
      await s.saveSession(session);
      await s.commitMlsTransition(transition(0, change(open, now)));
      final backup = await s.exportBackup();
      expect(utf8.decode(backup), isNot(contains('election_seen')));
      await s.clearCachedState(preserveOutbox: true);
      expect(await s.loadGovernanceObservations('shared'), isNotNull);
      await s.saveSession(session);
      expect(await s.loadGovernanceObservations('shared'), isNotNull);
      await s.restoreBackup(backup);
      expect(await s.loadGovernanceObservations('shared'), isNull);
      await s.saveSession(session);
      await s.commitMlsTransition(transition(0, change(open, now)));
      // Replacing all crypto starts observations afresh.
      await s.saveCryptoState(crypto(2), 1);
      expect(await s.loadGovernanceObservations('shared'), isNull);
      await s.commitMlsTransition(transition(2, change(open, now), cursor: 1));
      await s.saveSession(const Session(
          baseUrl: 'https://chat.example.org',
          token: 'other',
          accountId: 'other',
          deviceId: 'other-device'));
      expect(await s.loadGovernanceObservations('shared'), isNull);
      await s.commitMlsTransition(transition(0, change(open, now)));
      await s.clear();
      expect(await s.loadGovernanceObservations('shared'), isNull);
    });

    test('$label: deleting an MLS group also drops its clocks', () async {
      final s = store();
      await s.commitMlsTransition(transition(0, change(open, now)));
      await s.commitMlsTransition(
          transition(1, change(genesis, now, group: 'other')));
      await s.commitLocalMlsState(
          expectedCounter: 2,
          expectedCursor: 2,
          governanceObservation: change(open, now.add(const Duration(days: 1))),
          state: crypto(3, changes: [
            CryptoRecordChange(
                kind: cryptoRecordKindGroup,
                recordId: utf8.encode('shared'),
                generation: 3,
                sealed: null)
          ]));
      expect(await s.loadGovernanceObservations('shared'), isNull);
      expect(await s.loadGovernanceObservations('other'), isNotNull);
    });
  }

  test(
      'SQLite: close and reopen preserves microsecond clocks and election identity',
      () async {
    final first = secure();
    await first.commitMlsTransition(transition(0, change(open, now)));
    final observed = await first.loadGovernanceObservations('shared');
    await closeDatabases();
    final reopened = secure();
    expect(await reopened.loadGovernanceObservations('shared'), observed);
    expect((await reopened.loadCryptoState())!.counter, 1);
    expect(await reopened.loadSyncCursor(), 1);
  });

  for (final stage in MlsCommitStage.values) {
    test(
        'SQLite: failure at ${stage.name} rolls observations back with MLS and cursor',
        () async {
      var fail = false;
      final s = secure(failure: (point) async {
        if (fail && point == stage) throw StateError('injected failure');
      });
      await s.commitMlsTransition(transition(0, change(genesis, now)));
      final before = await s.loadGovernanceObservations('shared');
      fail = true;
      final next = transition(1, change(open, now.add(ownerInactivityWait)));
      await expectLater(s.commitMlsTransition(next), throwsStateError);
      expect(await s.loadGovernanceObservations('shared'), before);
      expect((await s.loadCryptoState())!.counter, 1);
      expect(await s.loadSyncCursor(), 1);
      fail = false;
      await s.commitMlsTransition(next);
      expect((await s.loadGovernanceObservations('shared'))!.electionOpened, 1);
    });
  }

  Future<File> schema34() async {
    final file = File('${directory.path}/upgrade.db');
    final db = EncryptedLocalDatabase(NativeDatabase(file));
    await db.writeMetadata('retained', 'value');
    await db.customStatement('DROP TABLE local_governance_observations');
    await db.customStatement('PRAGMA user_version = 34');
    await db.close();
    return file;
  }

  test('schema 34 upgrades to assigned schema 38 with empty local clocks',
      () async {
    final db = EncryptedLocalDatabase(NativeDatabase(await schema34()));
    databases.add(db);
    expect(await db.readMetadata('retained'), 'value');
    expect(await db.readGovernanceObservations('shared'), isNull);
    expect(
        (await db.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        38);
  });

  test('failed schema 38 upgrade rolls back table and version; retry succeeds',
      () async {
    final file = await schema34();
    final failing = _FailUpgrade(NativeDatabase(file));
    await expectLater(failing.readMetadata('retained'), throwsStateError);
    await failing.close();
    final raw = sqlite3.open(file.path);
    expect(raw.select('PRAGMA user_version').single['user_version'], 34);
    expect(
        raw.select(
            "SELECT name FROM sqlite_master WHERE name = 'local_governance_observations'"),
        isEmpty);
    raw.close();
    final retry = EncryptedLocalDatabase(NativeDatabase(file));
    databases.add(retry);
    expect(await retry.readMetadata('retained'), 'value');
    expect(await retry.readGovernanceObservations('shared'), isNull);
  });
}
