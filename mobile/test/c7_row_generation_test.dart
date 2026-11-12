import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'schema_fixtures.dart';

/// C7 schema 41 (docs/designs/C7-channel-history.md, decision 7): each row
/// records the generation its body was sealed under. The column survives
/// the upgrade, both stores keep it, and a history snapshot never carries
/// it (a restored device holds no generation keys of its own).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final gen = 'ab' * 32;

  InsertMessageEffect row(String key, {String? c7Gen}) => InsertMessageEffect(
      key: 'dev:$key',
      conversationId: 'conv',
      senderAccountId: 'bob',
      senderDeviceId: 'dev',
      kind: LocalMessageKind.text,
      body: 'words',
      createdAt: 1,
      state: LocalMessageState.received,
      c7Gen: c7Gen);

  Future<Directory> tempDir() async {
    final dir = await Directory.systemTemp.createTemp('veritra-c7-gen-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return dir;
  }

  for (final from in [40, 36, 12]) {
    test('schema $from upgrades to 41 with the generation column, rows kept',
        () async {
      final file = File('${(await tempDir()).path}/local.db');
      var database = EncryptedLocalDatabase(NativeDatabase(file));
      await database.applyMessageEffects([row('old')]);
      if (from == 12) {
        await stripW8Schema(database);
      } else {
        await database
            .customStatement('ALTER TABLE local_messages DROP COLUMN c7_gen');
        if (from < 40) {
          await database.customStatement(
              'ALTER TABLE local_messages DROP COLUMN sender_removed');
        }
      }
      await database.customStatement('PRAGMA user_version = $from');
      await database.close();

      database = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(database.close);
      final kept = (await database.readMessages('conv')).single;
      expect(kept.body, 'words');
      expect(kept.c7Gen, isNull);
      expect(
          (await database.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          EncryptedLocalDatabase.currentSchemaVersion);
      expect(EncryptedLocalDatabase.currentSchemaVersion,
          greaterThanOrEqualTo(41));
      await database.applyMessageEffects([row('new', c7Gen: gen)]);
      expect((await database.readMessage('dev:new'))!.c7Gen, gen);
      expect((await database.readMessage('dev:old'))!.c7Gen, isNull);
      expect(await database.readMessage('dev:none'), isNull);
    });
  }

  test('the memory store keeps the generation and loads one row', () async {
    final store = MemoryLocalStore();
    await store.saveCryptoState(
        StoredCryptoState(
            counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
        0);
    final current = (await store.loadCryptoState())!;
    await store.commitMlsTransition(MlsStateTransition(
        messageId: 'event-1',
        conversationId: 'conv',
        expectedCounter: current.counter,
        expectedCursor: 0,
        state: StoredCryptoState(
            counter: current.counter + 1,
            stateKey: current.stateKey,
            sealedState: [2]),
        cursor: 1,
        messageEffects: [row('a', c7Gen: gen), row('b')]));
    expect((await store.loadMessage('dev:a'))!.c7Gen, gen);
    expect((await store.loadMessage('dev:b'))!.c7Gen, isNull);
    expect(await store.loadMessage('dev:none'), isNull);
    expect(row('a', c7Gen: gen).markedSenderRemoved().c7Gen, gen);
  });

  test('a history snapshot never names the generation', () {
    final snapshot = HistorySnapshot(
        accountId: 'alice',
        sourceDeviceId: 'source',
        counter: 1,
        createdAt: 2,
        conversations: const [HistoryConversation('conv', 'dm')],
        messages: [historyMessageFromInsert(row('a', c7Gen: gen))],
        reactions: const [],
        pins: const [],
        starred: const {},
        preferences: const []);
    final bytes = snapshot.encode();
    expect(utf8.decode(bytes), isNot(contains(gen)));
    expect(utf8.decode(bytes), isNot(contains('c7Gen')));
    expect(HistorySnapshot.decode(bytes).messages.single.c7Gen, isNull);
  });
}
