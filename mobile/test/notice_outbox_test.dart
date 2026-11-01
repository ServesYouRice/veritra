import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import 'schema_fixtures.dart';

const owner = LocalNoticeOwner(
    origin: 'https://example.test', accountId: 'alice', deviceId: 'phone');
const session = Session(
    baseUrl: 'https://example.test',
    token: 'private-token',
    accountId: 'alice',
    deviceId: 'phone');
final now = DateTime.now().millisecondsSinceEpoch;

LocalNoticeReference ref(int event, String key,
        {String sender = 'bob', int? created, int? expires}) =>
    LocalNoticeReference(
        owner: owner,
        eventId: event,
        messageKey: 'sender:$key',
        serverMessageId: 'server-$key',
        conversationId: 'conv',
        senderAccountId: sender,
        senderDeviceId: 'sender',
        createdAt: created ?? now,
        expiresAt: expires);
InsertMessageEffect effect(String key,
        {String sender = 'bob',
        String kind = 'text',
        String state = 'received',
        int? created,
        int? expires,
        bool hidden = false}) =>
    InsertMessageEffect(
        key: 'sender:$key',
        serverMessageId: 'server-$key',
        conversationId: 'conv',
        senderAccountId: sender,
        senderDeviceId: 'sender',
        kind: kind,
        body: 'message text never copied into notice metadata',
        createdAt: created ?? now,
        expiresAt: expires,
        state: state,
        senderHidden: hidden);

Future<void> commit(LocalStore store, List<MessageEffect> effects,
    List<LocalNoticeReference> refs,
    {void Function()? fence}) async {
  final state = (await store.loadCryptoState())!,
      cursor = await store.loadSyncCursor();
  await store.commitMlsTransition(MlsStateTransition(
      messageId: 'event-${cursor + 1}',
      conversationId: 'conv',
      expectedCounter: state.counter,
      expectedCursor: cursor,
      state: StoredCryptoState(
          counter: state.counter + 1,
          stateKey: state.stateKey,
          sealedState: [9]),
      cursor: cursor + 1,
      messageEffects: effects,
      noticeReferences: refs,
      checkCanCommit: fence));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final sql in [false, true]) {
    group(sql ? 'SQLite' : 'memory', () {
      late LocalStore store;
      late Directory directory;
      EncryptedLocalDatabase? database;
      setUp(() async {
        FlutterSecureStorage.setMockInitialValues({});
        directory = await Directory.systemTemp.createTemp('notice-outbox-');
        database = null;
        store = sql
            ? SecureLocalStore(
                directoryProvider: () async => directory,
                databaseFactory: (_, __) => database ??=
                    EncryptedLocalDatabase(NativeDatabase.memory()))
            : MemoryLocalStore();
        await store.saveSession(session);
        await store.saveCryptoState(
            StoredCryptoState(
                counter: 1, stateKey: List.filled(32, 7), sealedState: [8]),
            0);
        await store.saveSnapshot([Conversation(id: 'conv', kind: 'dm')], {}, 0);
      });
      tearDown(() async {
        await database?.close();
        await SecureLocalStore.releaseInstanceLocks();
        await directory.delete(recursive: true);
      });

      test('foreground watermark preserves newer frozen and unfrozen refs',
          () async {
        await commit(store, [effect('a')], [ref(1, 'a')]);
        await commit(store, [effect('b')], [ref(2, 'b')]);
        final original = (await store.freezeNoticeDecision(
            owner, [ref(1, 'a').id, ref(2, 'b').id],
            now: now))!;
        await commit(store, [effect('c')], [ref(3, 'c')]);
        await store.suppressNoticesThrough(owner, 1, now: now);
        final pending = (await store.pendingNoticeDecision(owner, now: now))!;
        expect(pending.id, original.id);
        expect(pending.referenceIds, original.referenceIds);
        expect(pending.references.map((r) => r.eventId), [2]);
        expect(
            (await store.pendingNoticeReferences(owner, now: now))
                .map((r) => r.eventId),
            [3]);
        await expectLater(
            store.suppressNoticesThrough(owner, 4, now: now), throwsStateError);
        await store.suppressNoticesThrough(owner, 2, now: now);
        expect(await store.pendingNoticeDecision(owner, now: now), isNull);
        expect(
            (await store.pendingNoticeReferences(owner, now: now))
                .map((r) => r.eventId),
            [3]);
      });

      test(
          'reference commits with cursor and contains metadata only; duplicate rows do not recapture',
          () async {
        await commit(store, [effect('a')], [ref(1, 'a')]);
        expect(await store.loadSyncCursor(), 1);
        expect((await store.loadCryptoState())!.counter, 2);
        final pending = await store.pendingNoticeReferences(owner, now: now);
        expect(pending, hasLength(1));
        expect(pending.single.queuedAt, greaterThan(0));
        expect(jsonEncode(pending.single.toJson()),
            isNot(contains('message text')));
        await store.suppressNoticeReferences(owner, [pending.single.id],
            now: now);
        await commit(store, [effect('a')], [ref(2, 'a')]);
        expect(await store.pendingNoticeReferences(owner, now: now), isEmpty);
      });

      test('own, hidden, invalid, actions and copied rows never enqueue',
          () async {
        await commit(store, [effect('own', sender: 'alice')],
            [ref(1, 'own', sender: 'alice')]);
        await commit(
            store, [effect('hidden', hidden: true)], [ref(2, 'hidden')]);
        await commit(
            store, [effect('invalid', kind: 'invalid')], [ref(3, 'invalid')]);
        await commit(
            store, [effect('action', kind: 'action')], [ref(4, 'action')]);
        await commit(
            store, [effect('copied', state: 'restored')], [ref(5, 'copied')]);
        await commit(store, [effect('copied')], [ref(6, 'copied')]);
        expect(await store.pendingNoticeReferences(owner, now: now), isEmpty);
      });

      test(
          'mismatched reference and revoked commit fence roll back ratchet, row and cursor',
          () async {
        await expectLater(
            commit(store, [effect('a')], [ref(1, 'a', sender: 'other')]),
            throwsStateError);
        expect(await store.loadSyncCursor(), 0);
        expect((await store.loadCryptoState())!.counter, 1);
        expect(await store.loadMessages('conv'), isEmpty);
        var calls = 0;
        await expectLater(
            commit(store, [effect('a')], [ref(1, 'a')], fence: () {
              if (++calls > 1) throw StateError('permit revoked');
            }),
            throwsStateError);
        expect(await store.pendingNoticeReferences(owner, now: now), isEmpty);
        expect(await store.loadSyncCursor(), 0);
      });

      test(
          'per-event references preserve earlier mention candidate after later message deletion',
          () async {
        await commit(store, [effect('earlier')], [ref(1, 'earlier')]);
        await commit(store, [effect('newer')], [ref(2, 'newer')]);
        await commit(store, [
          DeleteMessageEffect(
              targetKey: 'sender:newer',
              deleterAccountId: 'bob',
              conversationId: 'conv',
              at: now + 1)
        ], []);
        final refs = await store.pendingNoticeReferences(owner, now: now);
        expect(
            refs.map((r) => r.messageKey), ['sender:earlier', 'sender:newer']);
        final messages = {
          for (final m in await store.loadMessages('conv')) m.key: m
        };
        expect(messages['sender:earlier']!.body, isNotNull);
        expect(messages['sender:newer']!.body, isNull);
      });

      test(
          'frozen ID retries after lost native/SQL result and never consumes newer events',
          () async {
        await commit(store, [effect('a')], [ref(1, 'a')]);
        final first =
            (await store.pendingNoticeReferences(owner, now: now)).single;
        final decision =
            (await store.freezeNoticeDecision(owner, [first.id], now: now))!;
        expect(decision.id, matches(RegExp(r'^[0-9a-f]{32}$')));
        await store.finishNoticeDecision(
            owner, decision.id, LocalNoticeOutcome.unavailable,
            now: now);
        expect((await store.pendingNoticeDecision(owner, now: now))!.id,
            decision.id);
        expect(
            (await store.freezeNoticeDecision(owner, [first.id], now: now))!.id,
            decision.id);
        await commit(store, [effect('b')], [ref(2, 'b')]);
        final newer =
            (await store.pendingNoticeReferences(owner, now: now)).single;
        expect(newer.messageKey, 'sender:b');
        expect(await store.freezeNoticeDecision(owner, [newer.id], now: now),
            isNull);
        var calls = 0;
        await expectLater(
            store.finishNoticeDecision(
                owner, decision.id, LocalNoticeOutcome.shown, now: now,
                checkCanCommit: () {
              if (++calls > 1) throw StateError('permit revoked');
            }),
            throwsStateError);
        expect((await store.pendingNoticeDecision(owner, now: now))!.id,
            decision.id);
        await store.finishNoticeDecision(
            owner, decision.id, LocalNoticeOutcome.shown,
            now: now);
        await store.finishNoticeDecision(
            owner, decision.id, LocalNoticeOutcome.shown,
            now: now);
        await expectLater(
            store.finishNoticeDecision(
                owner, decision.id, LocalNoticeOutcome.suppressed,
                now: now),
            throwsStateError);
        expect(await store.pendingNoticeDecision(owner, now: now), isNull);
        expect((await store.pendingNoticeReferences(owner, now: now)).single.id,
            newer.id);
      });

      test(
          'policy suppression, freshness pruning and owner changes stay private',
          () async {
        await commit(store, [effect('a', expires: now + 60000)],
            [ref(1, 'a', expires: now + 60000)]);
        final item =
            (await store.pendingNoticeReferences(owner, now: now)).single;
        final decision =
            (await store.freezeNoticeDecision(owner, [item.id], now: now))!;
        await store.finishNoticeDecision(
            owner, decision.id, LocalNoticeOutcome.suppressed,
            now: now);
        await commit(store, [effect('b')], [ref(2, 'b')]);
        final b = (await store.pendingNoticeReferences(owner, now: now)).single;
        await store.freezeNoticeDecision(owner, [b.id], now: now);
        expect(
            await store.pendingNoticeReferences(owner,
                now: now + localNoticeFreshnessMs + 1),
            isEmpty);
        expect(
            await store.pendingNoticeDecision(owner,
                now: now + localNoticeFreshnessMs + 1),
            isNull);
        await expectLater(
            store.pendingNoticeReferences(const LocalNoticeOwner(
                origin: 'https://other.test',
                accountId: 'alice',
                deviceId: 'phone')),
            throwsStateError);
        await store.saveSession(const Session(
            baseUrl: 'https://example.test',
            token: 'other',
            accountId: 'other',
            deviceId: 'other-phone'));
        const nextOwner = LocalNoticeOwner(
            origin: 'https://example.test',
            accountId: 'other',
            deviceId: 'other-phone');
        expect(await store.pendingNoticeReferences(nextOwner), isEmpty);
        expect(await store.pendingNoticeDecision(nextOwner), isNull);
      });

      test(
          'backups and K2 exclude device notice state; every restore and logout clears it',
          () async {
        await commit(store, [effect('a')], [ref(1, 'a')]);
        final item =
            (await store.pendingNoticeReferences(owner, now: now)).single;
        final decision =
            (await store.freezeNoticeDecision(owner, [item.id], now: now))!;
        final backup = await store.exportBackup();
        expect(utf8.decode(backup), isNot(contains(decision.id)));
        expect(utf8.decode(await store.exportHistorySnapshot()),
            isNot(contains(decision.id)));
        await store.restoreBackup(backup);
        // A restore leaves no device or MLS state (D71, D73): enroll again,
        // at the cursor the next reference below expects.
        await store.saveSession(session);
        await store.saveCryptoState(
            StoredCryptoState(
                counter: 1, stateKey: List.filled(32, 7), sealedState: [8]),
            1);
        expect(await store.pendingNoticeReferences(owner, now: now), isEmpty);
        expect(await store.pendingNoticeDecision(owner, now: now), isNull);
        await commit(store, [effect('b')], [ref(2, 'b')]);
        await store.clearCachedState(preserveOutbox: true, keepDrafts: true);
        expect(await store.pendingNoticeReferences(owner, now: now), isEmpty);
      });

      test(
          'foreground watermark suppresses an older frozen batch but preserves newer refs',
          () async {
        await commit(store, [effect('a')], [ref(1, 'a')]);
        final a = (await store.pendingNoticeReferences(owner, now: now)).single;
        final decision =
            (await store.freezeNoticeDecision(owner, [a.id], now: now))!;
        await commit(store, [effect('b')], [ref(2, 'b')]);
        await store.suppressNoticesThrough(owner, 1, now: now);
        expect(await store.pendingNoticeDecision(owner, now: now), isNull);
        expect(
            (await store.pendingNoticeReferences(owner, now: now))
                .single
                .messageKey,
            'sender:b');
        await store.finishNoticeDecision(
            owner, decision.id, LocalNoticeOutcome.suppressed,
            now: now);
        await expectLater(
            store.suppressNoticesThrough(owner, 3, now: now), throwsStateError);
        expect(
            (await store.pendingNoticeReferences(owner, now: now))
                .single
                .messageKey,
            'sender:b');
      });

      test(
          'foreground watermark cannot consume newer members of an immutable frozen batch',
          () async {
        await commit(store, [effect('a')], [ref(1, 'a')]);
        await commit(store, [effect('b')], [ref(2, 'b')]);
        final refs = await store.pendingNoticeReferences(owner, now: now);
        final decision = (await store
            .freezeNoticeDecision(owner, refs.map((r) => r.id), now: now))!;
        await store.suppressNoticesThrough(owner, 1, now: now);
        final pending = (await store.pendingNoticeDecision(owner, now: now))!;
        expect(pending.id, decision.id);
        expect(pending.referenceIds, decision.referenceIds);
        expect(pending.references.map((r) => r.messageKey), ['sender:b']);
        await store.suppressNoticesThrough(owner, 2, now: now);
        expect(await store.pendingNoticeDecision(owner, now: now), isNull);
      });

      if (sql)
        test('metadata cap failure rolls back the entire inbound commit',
            () async {
          await database!.customStatement(
              'UPDATE local_notice_usage SET size_bytes=? WHERE singleton=1',
              [localNoticeMetadataLimit]);
          await expectLater(commit(store, [effect('a')], [ref(1, 'a')]),
              throwsA(isA<LocalNoticeCapacityException>()));
          expect(await store.loadSyncCursor(), 0);
          expect((await store.loadCryptoState())!.counter, 1);
          expect(await store.loadMessages('conv'), isEmpty);
          await database!.customStatement(
              'UPDATE local_notice_usage SET size_bytes=0 WHERE singleton=1');
          await commit(store, [effect('a')], [ref(1, 'a')]);
          expect(await store.pendingNoticeReferences(owner, now: now),
              hasLength(1));
        });
    });
  }

  test('memory count cap and batch bounds fail explicitly', () {
    final state = LocalNoticeState(references: {
      for (var i = 0; i <= localNoticeReferenceLimit; i++) '$i': ref(1, 'a')
    });
    expect(() => state.checkCapacity(),
        throwsA(isA<LocalNoticeCapacityException>()));
    expect(() => localNoticeIds(List.filled(201, 'x')), throwsArgumentError);
  });

  for (final fail in [false, true]) {
    test(
        'actual schema14 to15 ${fail ? 'rolls back and retries' : 'preserves history'}',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('notice-migration-');
      final file = File('${directory.path}/db.sqlite');
      var db = EncryptedLocalDatabase(NativeDatabase(file));
      try {
        await db.writeHistoryNamespace(HistoryNamespace(counter: 7));
        await db.applyMessageEffects([effect('old')]);
        await stripNoticeSchema(db);
        await db.customStatement('PRAGMA user_version=14');
        if (fail)
          await db.customStatement(
              'CREATE INDEX local_notice_decisions ON local_messages(key)');
        await db.close();
        db = EncryptedLocalDatabase(NativeDatabase(file));
        if (fail) {
          await expectLater(db.readMessages('conv'), throwsA(anything));
          await db.close();
          final raw = sqlite3.open(file.path);
          try {
            expect(
                raw.select('PRAGMA user_version').single['user_version'], 14);
            expect(
                raw.select(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name='local_notice_references'"),
                isEmpty);
            raw.execute('DROP INDEX local_notice_decisions');
          } finally {
            raw.close();
          }
          db = EncryptedLocalDatabase(NativeDatabase(file));
        }
        expect((await db.readMessages('conv')).single.body,
            contains('message text'));
        expect((await db.readHistoryNamespace()).counter, 7);
        expect(
            (await db.customSelect('PRAGMA user_version').getSingle())
                .read<int>('user_version'),
            EncryptedLocalDatabase.currentSchemaVersion);
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    });
  }
}
