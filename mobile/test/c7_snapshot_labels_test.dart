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

/// C7 imported rows in K1 backups and K2 link bundles: the "From a former
/// member" mark (local schema 42, owner: keep labels in backups) and the
/// pre-join attachment placeholder (owner answer Q2) travel with the row,
/// in both stores, instead of being dropped or breaking the export.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const conversation = 'conv_shared';
  const channel = 'chan_1';
  final now = DateTime.now().millisecondsSinceEpoch;
  final shared = Conversation(
      id: conversation, kind: 'community_shared', communityId: 'comm_1');

  InsertMessageEffect post(String key, {String? body, int? former}) {
    final effect = InsertMessageEffect(
      key: 'dev_bob:$key',
      serverMessageId: 'hist_$key',
      conversationId: conversation,
      senderAccountId: 'acct_bob',
      senderDeviceId: 'dev_bob',
      kind: body == null ? LocalMessageKind.text : LocalMessageKind.attachment,
      body: body ?? key,
      createdAt: now - 1000,
      state: LocalMessageState.received,
      channelId: channel,
    );
    return former == null
        ? effect
        : effect.markedC7Former(named: former == C7FormerMark.named);
  }

  Future<Directory> tempDir() async {
    final dir = await Directory.systemTemp.createTemp('veritra-c7-labels-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return dir;
  }

  Future<LocalStore> openStore(bool sqlite, String device) async {
    final LocalStore store;
    if (sqlite) {
      final dir = await tempDir();
      EncryptedLocalDatabase? db;
      store = SecureLocalStore(
          directoryProvider: () async => dir,
          databaseFactory: (_, __) =>
              db ??= EncryptedLocalDatabase(NativeDatabase.memory()));
      addTearDown(() async {
        await db?.close();
        await SecureLocalStore.releaseInstanceLocks();
      });
    } else {
      store = MemoryLocalStore();
    }
    await store.saveSession(Session(
        baseUrl: 'https://example.test',
        token: 'token-$device',
        accountId: 'acct_dave',
        deviceId: device));
    await store.saveCryptoState(
        StoredCryptoState(
            counter: 1, stateKey: List.filled(32, 7), sealedState: [8]),
        0);
    await store.saveSnapshot(
        [shared], const <String, List<ReceivedMessageEnvelope>>{}, 0);
    return store;
  }

  HistoryImportContext context(HistorySnapshot snapshot) =>
      HistoryImportContext(
          origin: 'https://example.test',
          accountId: 'acct_dave',
          sourceDeviceId: 'dev_dave',
          recipientDeviceId: 'dev_new',
          transferId: 'transfer',
          snapshotCounter: snapshot.counter,
          snapshotCreatedAt: snapshot.createdAt,
          digest: 'a' * 64);

  for (final sqlite in [false, true]) {
    final label = sqlite ? 'SQLite' : 'memory';
    test(
        '$label: imported marks and placeholders survive the K1/K2 export and '
        'the restore on another device', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final source = await openStore(sqlite, 'dev_dave');
      await source.importC7History(<MessageEffect>[
        post('text'),
        post('former', former: C7FormerMark.unnamed),
        post('named', former: C7FormerMark.named),
        post('file', body: c7HiddenAttachmentBody),
      ]);
      // An edit never clears the mark.
      await source.importC7History(const <MessageEffect>[
        EditMessageEffect(
            targetKey: 'dev_bob:former',
            editorAccountId: 'acct_bob',
            body: 'edited',
            at: 5,
            conversationId: conversation,
            channelId: channel),
      ]);
      final bytes = await source.exportHistorySnapshot();
      // K1 backups take the same export with disappearing messages left out.
      HistorySnapshot.decode(
          await source.exportHistorySnapshot(omitDisappearing: true));
      final snapshot = HistorySnapshot.decode(bytes);
      final rows = (jsonDecode(utf8.decode(bytes))['messages'] as List)
          .cast<Map<String, dynamic>>();
      Map<String, dynamic> raw(String key) =>
          rows.firstWhere((r) => r['key'] == 'dev_bob:$key');
      expect(raw('former')['c7Former'], C7FormerMark.unnamed);
      expect(raw('named')['c7Former'], C7FormerMark.named);
      // An unmarked row stays readable by an importer from before 42.
      expect(raw('text').containsKey('c7Former'), isFalse);
      expect(raw('file')['body'], c7HiddenAttachmentBody);

      final target = await openStore(sqlite, 'dev_new');
      await target.importHistorySnapshot(bytes, context(snapshot));
      final restored = {
        for (final m in await target.loadMessages(conversation)) m.key: m,
      };
      expect(restored['dev_bob:former']!.c7Former, C7FormerMark.unnamed);
      expect(restored['dev_bob:named']!.c7Former, C7FormerMark.named);
      expect(restored['dev_bob:former']!.body, 'edited');
      expect(restored['dev_bob:text']!.c7Former, isNull);
      expect(restored['dev_bob:file']!.body, c7HiddenAttachmentBody);
      expect(restored['dev_bob:file']!.kind, LocalMessageKind.attachment);
    });
  }

  test('a snapshot mark is 1 (named), 2 (unnamed) or absent, nothing else', () {
    LocalMessage message(String key, {int? former}) => LocalMessage(
        key: 'dev:$key',
        conversationId: 'conv',
        senderAccountId: 'bob',
        senderDeviceId: 'dev',
        kind: 'text',
        body: key,
        createdAt: 1,
        state: 'received',
        senderHidden: false,
        c7Former: former);
    final bytes = HistorySnapshot(
        accountId: 'alice',
        sourceDeviceId: 'source',
        counter: 1,
        createdAt: 2,
        conversations: const [HistoryConversation('conv', 'dm')],
        messages: [message('marked', former: C7FormerMark.unnamed)],
        reactions: const [],
        pins: const [],
        starred: const {},
        preferences: const []).encode();
    final root = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final marked = (root['messages'] as List).single as Map<String, dynamic>;
    for (final bad in <Object>[false, true, 'yes', 0, 3, '2']) {
      marked['c7Former'] = bad;
      expect(() => HistorySnapshot.decode(utf8.encode(jsonEncode(root))),
          throwsFormatException);
    }
  });

  test('any other non-list attachment body is still refused', () async {
    final source = await openStore(false, 'dev_dave');
    await source.importC7History(<MessageEffect>[
      post('file', body: '{"c7":"something_else"}'),
    ]);
    await expectLater(source.exportHistorySnapshot(), throwsFormatException);
  });

  for (final from in [41, 36, 12]) {
    test('schema $from upgrades to 42 with the mark column, rows kept',
        () async {
      final file = File('${(await tempDir()).path}/local.db');
      var database = EncryptedLocalDatabase(NativeDatabase(file));
      await database.applyMessageEffects([post('old')]);
      if (from == 12) {
        await stripW8Schema(database);
      } else {
        await database.customStatement(
            'ALTER TABLE local_messages DROP COLUMN c7_former');
        // At 41 too: a store another package numbered past 41 without C7's
        // columns (the L2 merge) still gets c7_gen, since the step is gated
        // on the column check, not on the version.
        await database
            .customStatement('ALTER TABLE local_messages DROP COLUMN c7_gen');
        if (from == 36) {
          await database.customStatement(
              'ALTER TABLE local_messages DROP COLUMN sender_removed');
        }
      }
      await database.customStatement('PRAGMA user_version = $from');
      await database.close();

      database = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(database.close);
      final kept = (await database.readMessages(conversation)).single;
      expect(kept.body, 'old');
      expect(kept.c7Former, isNull);
      expect(
          (await database.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          EncryptedLocalDatabase.currentSchemaVersion);
      await database.applyMessageEffects(
          [post('new', former: C7FormerMark.unnamed).withC7Gen('ab' * 32)]);
      final marked = (await database.readMessages(conversation))
          .firstWhere((m) => m.key == 'dev_bob:new');
      expect(marked.c7Former, C7FormerMark.unnamed);
      expect(marked.c7Gen, 'ab' * 32);
    });
  }

  test('the upgrade step runs again harmlessly (renumbering-safe)', () async {
    final file = File('${(await tempDir()).path}/local.db');
    var database = EncryptedLocalDatabase(NativeDatabase(file));
    await database.applyMessageEffects([post('a', former: C7FormerMark.named)]);
    // The columns are there already; an older version number reruns it.
    await database.customStatement('PRAGMA user_version = 40');
    await database.close();
    database = EncryptedLocalDatabase(NativeDatabase(file));
    expect((await database.readMessages(conversation)).single.c7Former,
        C7FormerMark.named);
    await database.close();
    final raw = sqlite3.open(file.path);
    try {
      expect(raw.select('SELECT c7_former FROM local_messages').single[0], 1);
      expect(() => raw.execute('UPDATE local_messages SET c7_former = 3'),
          throwsA(anything));
    } finally {
      raw.close();
    }
  });
}
