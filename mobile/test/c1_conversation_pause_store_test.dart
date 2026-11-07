import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/conversation_pause.dart';
import 'package:private_messenger/sync/sync_recovery.dart';

/// C1 prerequisite 1 (docs/designs/C1-sync-isolation.md): the durable pause
/// of one conversation. The cursor moves past a paused conversation's events
/// only together with its pause row; an event behind the cursor applies only
/// as a replay of that conversation, above what was replayed, and leaves the
/// global cursor alone; nothing outgoing is written for a paused
/// conversation.

final _key = List<int>.filled(32, 7);

Future<EncryptedLocalDatabase> _db() async {
  final dir = await Directory.systemTemp.createTemp('c1-pause-');
  addTearDown(() => dir.delete(recursive: true));
  final db = EncryptedLocalDatabase(NativeDatabase(File('${dir.path}/l.db')));
  addTearDown(db.close);
  return db;
}

Future<void> _seed(EncryptedLocalDatabase db, {int cursor = 10}) =>
    db.writeCryptoState(
        counter: 1, stateKey: _key, sealedState: [1], cursor: cursor);

Future<ConversationPause> _pause(
  EncryptedLocalDatabase db,
  String conversationId,
  int eventId,
) =>
    db.writeConversationPause(
        conversationId: conversationId,
        failedEventId: eventId,
        kind: SyncFailureKind.mlsState);

/// One incoming MLS transition for [eventId] of [conversationId] on top of
/// counter [counter] and the global cursor [cursor].
Future<void> _apply(
  EncryptedLocalDatabase db,
  String conversationId,
  int eventId, {
  required int counter,
  int cursor = 10,
}) =>
    db.commitMlsTransition(
        messageId: 'mls:$eventId:m$eventId',
        conversationId: conversationId,
        expectedCounter: counter,
        expectedCursor: cursor,
        counter: counter + 1,
        stateKey: _key,
        sealedState: [counter + 1],
        cursor: eventId,
        upsertedEnvelopes: const [],
        deletedEnvelopeIds: const []);

Future<int> _counter(EncryptedLocalDatabase db) async =>
    (await db.readCryptoState())!.counter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encrypted database', () {
    test('a later failure keeps where the replay stands', () async {
      final db = await _db();
      final first = await db.writeConversationPause(
          conversationId: 'conv_a',
          failedEventId: 4,
          kind: SyncFailureKind.mlsState,
          failedEventType: 'mls.message.created',
          failedRef: 'mls_1');
      expect(first.resumeAfter, 3);
      expect(first.failedEventId, 4);
      expect(first.failedRef, 'mls_1');
      expect(first.generation, 1);

      final again = await _pause(db, 'conv_a', 6);
      expect(again.resumeAfter, 3);
      expect(again.failedEventId, 6);
      expect(again.failedRef, isNull);
      expect(again.generation, 2);

      // A failure below what was already replayed is refused.
      await expectLater(_pause(db, 'conv_a', 3), throwsStateError);
      final all = await db.readConversationPauses();
      expect(all.map((pause) => pause.conversationId), ['conv_a']);
    });

    test('skipping needs the pause and moves only the cursor', () async {
      final db = await _db();
      await _seed(db);
      await expectLater(
          db.skipPausedConversationEvent(
              conversationId: 'conv_a', eventId: 11, expectedCursor: 10),
          throwsStateError);
      expect(await db.readCursor(), 10);

      await _pause(db, 'conv_a', 4);
      // A stale expected cursor, or an event not above the cursor, fails.
      await expectLater(
          db.skipPausedConversationEvent(
              conversationId: 'conv_a', eventId: 11, expectedCursor: 9),
          throwsStateError);
      await expectLater(
          db.skipPausedConversationEvent(
              conversationId: 'conv_a', eventId: 10, expectedCursor: 10),
          throwsStateError);
      expect(await db.readCursor(), 10);

      await db.skipPausedConversationEvent(
          conversationId: 'conv_a', eventId: 11, expectedCursor: 10);
      expect(await db.readCursor(), 11);
      expect(await _counter(db), 1);
      // No processed marker: the event was not applied.
      expect(await db.hasProcessedMlsMessage('mls:11:m11'), isFalse);
    });

    test('a paused conversation replays behind the cursor without moving it',
        () async {
      final db = await _db();
      await _seed(db);
      await _pause(db, 'conv_a', 4);

      await _apply(db, 'conv_a', 4, counter: 1);
      expect(await db.readCursor(), 10);
      expect(await _counter(db), 2);
      expect((await db.readConversationPause('conv_a'))!.resumeAfter, 4);
      expect(await db.hasProcessedMlsMessage('mls:4:m4'), isTrue);

      await _apply(db, 'conv_a', 6, counter: 2);
      expect((await db.readConversationPause('conv_a'))!.resumeAfter, 6);

      // Not above what was replayed.
      await expectLater(_apply(db, 'conv_a', 5, counter: 3), throwsStateError);
      expect(await _counter(db), 3);
      expect(await db.readCursor(), 10);
    });

    test('behind the cursor is refused without a pause of that conversation',
        () async {
      final db = await _db();
      await _seed(db);
      await expectLater(_apply(db, 'conv_b', 4, counter: 1), throwsStateError);
      await _pause(db, 'conv_a', 4);
      await expectLater(_apply(db, 'conv_b', 5, counter: 1), throwsStateError);
      expect(await _counter(db), 1);
      expect(await db.readCursor(), 10);
    });

    test('a paused group never takes a cursor-advancing transition', () async {
      final db = await _db();
      await _seed(db);
      await _pause(db, 'conv_a', 4);
      await expectLater(_apply(db, 'conv_a', 11, counter: 1),
          throwsA(isA<ConversationSyncPausedException>()));
      expect(await _counter(db), 1);
      expect(await db.readCursor(), 10);
      // Another conversation goes on.
      await _apply(db, 'conv_b', 11, counter: 1);
      expect(await db.readCursor(), 11);
    });

    test('nothing outgoing is written for a paused conversation', () async {
      final db = await _db();
      await _seed(db);
      await _pause(db, 'conv_a', 4);

      Future<void> send(String conversationId) =>
          db.commitOutgoingApplicationTransition(
              expectedCounter: 1,
              expectedCursor: 10,
              counter: 2,
              stateKey: _key,
              sealedState: [2],
              idempotencyKey: 'idem_$conversationId',
              conversationId: conversationId,
              payloadJson: '{}',
              draftText: null,
              maxEntries: 10);
      Future<void> stage(String conversationId) =>
          db.commitOutgoingMlsTransition(
              expectedCounter: 1,
              expectedCursor: 10,
              counter: 2,
              stateKey: _key,
              sealedState: [
                2
              ],
              messages: [
                (
                  idempotencyKey: 'mls_$conversationId',
                  conversationId: conversationId,
                  kind: 'commit_bundle',
                  recipientDeviceId: null,
                  revocationDeviceId: null,
                  payload: [1],
                )
              ]);

      await expectLater(
          send('conv_a'), throwsA(isA<ConversationSyncPausedException>()));
      await expectLater(
          stage('conv_a'), throwsA(isA<ConversationSyncPausedException>()));
      expect(await _counter(db), 1);
      await send('conv_b');
      expect(await _counter(db), 2);
    });

    test('a pause is cleared only for the failure it was recorded for',
        () async {
      final db = await _db();
      await _pause(db, 'conv_a', 4);
      final second = await _pause(db, 'conv_a', 5);
      expect(await db.clearConversationPause('conv_a', generation: 1), isFalse);
      expect(await db.readConversationPause('conv_a'), isNotNull);
      expect(
          await db.clearConversationPause('conv_a',
              generation: second.generation),
          isTrue);
      expect(await db.readConversationPause('conv_a'), isNull);
      expect(await db.clearConversationPause('conv_a'), isFalse);
    });

    test('at most $maxConversationPauses conversations are paused', () async {
      final db = await _db();
      for (var i = 0; i < maxConversationPauses; i++) {
        await _pause(db, 'conv_$i', 5);
      }
      await expectLater(_pause(db, 'conv_over', 5),
          throwsA(isA<ConversationPauseLimitReached>()));
      // A conversation already paused can still be updated.
      await _pause(db, 'conv_0', 6);
      expect((await db.readConversationPauses()).length, maxConversationPauses);
    });

    test('a new MLS state and cursor drop the pauses', () async {
      final db = await _db();
      await _seed(db);
      await _pause(db, 'conv_a', 4);
      await db.writeCryptoState(
          counter: 2, stateKey: _key, sealedState: [2], cursor: 0);
      expect(await db.readConversationPauses(), isEmpty);

      await _pause(db, 'conv_a', 4);
      await db.clearAll();
      expect(await db.readConversationPauses(), isEmpty);
    });

    test('a schema 18 database gains the table on upgrade', () async {
      final dir = await Directory.systemTemp.createTemp('c1-pause-upgrade-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/l.db');
      var db = EncryptedLocalDatabase(NativeDatabase(file));
      await db.readConversationPauses();
      await db.customStatement('DROP TABLE local_conversation_pauses');
      await db.customStatement('PRAGMA user_version = 18');
      await db.close();

      db = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(await db.readConversationPauses(), isEmpty);
      await _pause(db, 'conv_a', 4);
      expect((await db.readConversationPauses()).single.resumeAfter, 3);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'),
          EncryptedLocalDatabase.currentSchemaVersion);
    });
  });

  group('memory store', () {
    StoredCryptoState state(int counter) => StoredCryptoState(
        counter: counter, stateKey: _key, sealedState: [counter]);

    Future<MemoryLocalStore> seeded() async {
      final store = MemoryLocalStore();
      await store.saveCryptoState(state(1), 10);
      return store;
    }

    MlsStateTransition transition(String conversationId, int eventId,
            {required int counter, int cursor = 10}) =>
        MlsStateTransition(
            messageId: 'mls:$eventId:m$eventId',
            conversationId: conversationId,
            expectedCounter: counter,
            expectedCursor: cursor,
            state: state(counter + 1),
            cursor: eventId);

    test('skip, replay and refusals match the database', () async {
      final store = await seeded();
      await expectLater(
          store.skipPausedConversationEvent(
              conversationId: 'conv_a', eventId: 11, expectedCursor: 10),
          throwsStateError);
      final pause = await store.pauseConversation(
          conversationId: 'conv_a',
          failedEventId: 4,
          kind: SyncFailureKind.mlsState);
      expect(pause.resumeAfter, 3);

      // Behind the cursor: refused for another conversation, applied as a
      // replay for the paused one without moving the cursor.
      await expectLater(
          store.commitMlsTransition(transition('conv_b', 4, counter: 1)),
          throwsStateError);
      await store.commitMlsTransition(transition('conv_a', 4, counter: 1));
      expect(await store.loadSyncCursor(), 10);
      expect((await store.loadConversationPause('conv_a'))!.resumeAfter, 4);
      await expectLater(
          store.commitMlsTransition(transition('conv_a', 4, counter: 2)),
          throwsStateError);

      // A cursor-advancing transition for the paused group is refused.
      await expectLater(
          store.commitMlsTransition(transition('conv_a', 11, counter: 2)),
          throwsA(isA<ConversationSyncPausedException>()));
      await store.skipPausedConversationEvent(
          conversationId: 'conv_a', eventId: 11, expectedCursor: 10);
      expect(await store.loadSyncCursor(), 11);
      expect(await store.hasProcessedMlsMessage('mls:11:m11'), isFalse);
    });

    test('a replay commit of a sync event leaves the cursor alone', () async {
      final store = await seeded();
      await store.pauseConversation(
          conversationId: 'conv_a',
          failedEventId: 4,
          kind: SyncFailureKind.mlsState);
      await store.commitSyncEvent(const SyncEventCommit(
          eventKey: 'mls:4:m4',
          conversationId: 'conv_a',
          expectedCursor: 10,
          cursor: 4));
      expect(await store.loadSyncCursor(), 10);
      expect((await store.loadConversationPause('conv_a'))!.resumeAfter, 4);
      await expectLater(
          store.commitSyncEvent(const SyncEventCommit(
              eventKey: 'mls:3:m3',
              conversationId: 'conv_b',
              expectedCursor: 10,
              cursor: 3)),
          throwsStateError);
    });

    test('clearing and the limit', () async {
      final store = MemoryLocalStore();
      for (var i = 0; i < maxConversationPauses; i++) {
        await store.pauseConversation(
            conversationId: 'conv_$i',
            failedEventId: 5,
            kind: SyncFailureKind.mlsState);
      }
      await expectLater(
          store.pauseConversation(
              conversationId: 'conv_over',
              failedEventId: 5,
              kind: SyncFailureKind.mlsState),
          throwsA(isA<ConversationPauseLimitReached>()));
      expect(
          await store.clearConversationPause('conv_0', generation: 9), isFalse);
      expect(await store.clearConversationPause('conv_0'), isTrue);
      await store.saveCryptoState(state(1), 0);
      expect(await store.loadConversationPauses(), isEmpty);
    });
  });
}
