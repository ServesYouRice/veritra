import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import 'schema_fixtures.dart';

/// L1 schema 40: the "sent from a device <name> removed" mark is recorded on
/// the message row at entry, survives the upgrade, both stores' apply paths
/// and history snapshots (K1 backups, K2 transfers).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  InsertMessageEffect row(String key,
          {bool removed = false, String body = 'words'}) =>
      InsertMessageEffect(
          key: 'dev:$key',
          conversationId: 'conv',
          senderAccountId: 'bob',
          senderDeviceId: 'dev',
          kind: LocalMessageKind.text,
          body: body,
          createdAt: 1,
          state: LocalMessageState.received,
          senderRemoved: removed);

  Future<Directory> tempDir() async {
    final dir = await Directory.systemTemp.createTemp('veritra-l1-mark-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return dir;
  }

  for (final from in [36, 12]) {
    test('schema $from upgrades to 40 with the mark column, rows kept',
        () async {
      final file = File('${(await tempDir()).path}/local.db');
      var database = EncryptedLocalDatabase(NativeDatabase(file));
      await database.applyMessageEffects([row('old')]);
      if (from == 12) {
        // A schema 12 fixture also lacks W8's columns and tables.
        await stripW8Schema(database);
      } else {
        await database.customStatement(
            'ALTER TABLE local_messages DROP COLUMN sender_removed');
      }
      await database.customStatement('PRAGMA user_version = $from');
      await database.close();

      database = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(database.close);
      final kept = (await database.readMessages('conv')).single;
      expect(kept.body, 'words');
      expect(kept.senderRemoved, isNull);
      expect(
          (await database.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          EncryptedLocalDatabase.currentSchemaVersion);
      await database.applyMessageEffects([row('new', removed: true)]);
      final marked = (await database.readMessages('conv'))
          .firstWhere((m) => m.key == 'dev:new');
      expect(marked.senderRemoved, isTrue);
    });
  }

  test('a fresh database has the column and only 0/1 in it', () async {
    final file = File('${(await tempDir()).path}/local.db');
    final database = EncryptedLocalDatabase(NativeDatabase(file));
    await database.applyMessageEffects([row('a', removed: true)]);
    await database.close();
    final raw = sqlite3.open(file.path);
    try {
      expect(
          raw.select('SELECT sender_removed FROM local_messages').single[0], 1);
      expect(() => raw.execute('UPDATE local_messages SET sender_removed = 2'),
          throwsA(anything));
    } finally {
      raw.close();
    }
  });

  for (final memory in [true, false]) {
    test(
        '${memory ? 'memory' : 'SQLite'}: an edit from a removed leaf marks '
        'its target; an approved edit never clears a mark', () async {
      final dir = memory ? null : await tempDir();
      final LocalStore store;
      EncryptedLocalDatabase? database;
      if (memory) {
        store = MemoryLocalStore();
      } else {
        database =
            EncryptedLocalDatabase(NativeDatabase(File('${dir!.path}/l.db')));
        addTearDown(database.close);
        store = _DatabaseEffects(database);
      }
      if (memory) {
        await store.saveCryptoState(
            StoredCryptoState(
                counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
            0);
      }
      Future<void> apply(List<MessageEffect> effects) async {
        if (!memory) return database!.applyMessageEffects(effects);
        final current = (await store.loadCryptoState())!;
        final cursor = await store.loadSyncCursor();
        await store.commitMlsTransition(MlsStateTransition(
            messageId: 'event-${cursor + 1}',
            conversationId: 'conv',
            expectedCounter: current.counter,
            expectedCursor: cursor,
            state: StoredCryptoState(
                counter: current.counter + 1,
                stateKey: current.stateKey,
                sealedState: [current.counter + 1]),
            cursor: cursor + 1,
            messageEffects: effects));
      }

      Future<LocalMessage> read(String key) async =>
          (await store.loadMessages('conv')).firstWhere((m) => m.key == key);

      await apply([row('a'), row('b', removed: true)]);
      expect((await read('dev:a')).senderRemoved, isNot(isTrue));
      expect((await read('dev:b')).senderRemoved, isTrue);
      const edit = EditMessageEffect(
          targetKey: 'dev:a',
          editorAccountId: 'bob',
          body: 'rewritten',
          at: 2,
          conversationId: 'conv');
      await apply([edit.markedSenderRemoved()]);
      expect((await read('dev:a')).body, 'rewritten');
      expect((await read('dev:a')).senderRemoved, isTrue);
      await apply([
        const EditMessageEffect(
            targetKey: 'dev:a',
            editorAccountId: 'bob',
            body: 'again',
            at: 3,
            conversationId: 'conv')
      ]);
      expect((await read('dev:a')).body, 'again');
      expect((await read('dev:a')).senderRemoved, isTrue);
    });
  }

  test('snapshots carry the mark only when set, and read it back', () {
    LocalMessage message(String key, {bool? removed}) => LocalMessage(
        key: 'dev:$key',
        conversationId: 'conv',
        senderAccountId: 'bob',
        senderDeviceId: 'dev',
        kind: 'text',
        body: key,
        createdAt: 1,
        state: 'received',
        senderHidden: false,
        senderRemoved: removed);
    final snapshot = HistorySnapshot(
        accountId: 'alice',
        sourceDeviceId: 'source',
        counter: 1,
        createdAt: 2,
        conversations: const [HistoryConversation('conv', 'dm')],
        messages: [message('plain'), message('marked', removed: true)],
        reactions: const [],
        pins: const [],
        starred: const {},
        preferences: const []);
    final bytes = snapshot.encode();
    final root = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final rows = (root['messages'] as List).cast<Map<String, dynamic>>();
    final plain = rows.firstWhere((r) => r['key'] == 'dev:plain');
    final marked = rows.firstWhere((r) => r['key'] == 'dev:marked');
    // An unmarked row stays readable by an importer from before schema 40.
    expect(plain.containsKey('senderRemoved'), isFalse);
    expect(marked['senderRemoved'], isTrue);
    final read = HistorySnapshot.decode(bytes).messages;
    expect(read.firstWhere((m) => m.key == 'dev:marked').senderRemoved, isTrue);
    expect(read.firstWhere((m) => m.key == 'dev:plain').senderRemoved,
        isNot(isTrue));
    // Only `true` is a valid value.
    marked['senderRemoved'] = false;
    expect(() => HistorySnapshot.decode(utf8.encode(jsonEncode(root))),
        throwsFormatException);
    marked['senderRemoved'] = 'yes';
    expect(() => HistorySnapshot.decode(utf8.encode(jsonEncode(root))),
        throwsFormatException);
  });
}

/// Reads messages through the production SQLite reader.
class _DatabaseEffects extends MemoryLocalStore {
  _DatabaseEffects(this.database);
  final EncryptedLocalDatabase database;

  @override
  Future<List<LocalMessage>> loadMessages(String conversationId) =>
      database.readMessages(conversationId);
}
