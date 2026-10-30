import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import 'schema_fixtures.dart';

const origin = 'https://example.test';
const source = 'source';
final now = DateTime.now().millisecondsSinceEpoch;
final conversation = Conversation(id: 'conv', kind: 'dm', title: 'historical');

HistoryImportContext context(
        {String transfer = 'transfer',
        String? digest,
        String server = origin}) =>
    HistoryImportContext(
        origin: server,
        accountId: 'alice',
        sourceDeviceId: source,
        recipientDeviceId: 'receiver',
        transferId: transfer,
        snapshotCounter: 1,
        snapshotCreatedAt: now,
        digest: digest ?? 'a' * 64);

LocalMessage message(String action,
        {String? body,
        String? serverId,
        int? expires,
        int? hidden,
        int? deleted,
        String state = 'received'}) =>
    LocalMessage(
        key: 'source:$action',
        serverMessageId: serverId,
        conversationId: 'conv',
        senderAccountId: 'bob',
        senderDeviceId: source,
        kind: 'text',
        body: body ?? action,
        createdAt: now - 1000,
        state: state,
        expiresAt: expires,
        hiddenAt: hidden,
        deletedAt: deleted,
        senderHidden: false);

HistorySnapshot snapshot(List<LocalMessage> messages,
        {List<LocalMessageReaction> reactions = const [],
        List<LocalPin> pins = const [],
        Map<String, int> starred = const {},
        List<LocalConversationPref> preferences = const []}) =>
    HistorySnapshot(
        accountId: 'alice',
        sourceDeviceId: source,
        counter: 1,
        createdAt: now,
        conversations: [
          const HistoryConversation('conv', 'dm', title: 'historical')
        ],
        messages: messages,
        reactions: reactions,
        pins: pins,
        starred: starred,
        preferences: preferences);

Future<void> insert(LocalStore store, String action,
    {String body = 'live', String? serverId}) async {
  final state = (await store.loadCryptoState())!;
  final cursor = await store.loadSyncCursor();
  await store.commitMlsTransition(MlsStateTransition(
      messageId: 'event:$cursor',
      conversationId: 'conv',
      expectedCounter: state.counter,
      expectedCursor: cursor,
      state: StoredCryptoState(
          counter: state.counter + 1,
          stateKey: state.stateKey,
          sealedState: [2]),
      cursor: cursor + 1,
      messageEffects: [
        InsertMessageEffect(
            key: 'source:$action',
            serverMessageId: serverId,
            conversationId: 'conv',
            senderAccountId: 'bob',
            senderDeviceId: source,
            kind: 'text',
            body: body,
            createdAt: now,
            state: 'received')
      ]));
}

Future<void> applyEffects(LocalStore store, List<MessageEffect> effects) async {
  final state = (await store.loadCryptoState())!,
      cursor = await store.loadSyncCursor();
  await store.commitMlsTransition(MlsStateTransition(
      messageId: 'effect:$cursor',
      conversationId: 'conv',
      expectedCounter: state.counter,
      expectedCursor: cursor,
      state: StoredCryptoState(
          counter: state.counter + 1,
          stateKey: state.stateKey,
          sealedState: [3]),
      cursor: cursor + 1,
      messageEffects: effects));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'strict history codec rejects duplicate/unknown keys and protected fields',
      () {
    final bytes = snapshot([message('a')]).encode();
    final text = utf8.decode(bytes);
    expect(
        () => HistorySnapshot.decode(utf8.encode(
            text.replaceFirst('"version":1', '"version":1,"version":1'))),
        throwsFormatException);
    final j = jsonDecode(text) as Map<String, dynamic>;
    j['session'] = {'token': 'secret'};
    expect(() => HistorySnapshot.decode(utf8.encode(jsonEncode(j))),
        throwsFormatException);
    j.remove('session');
    (j['messages'] as List).first['state'] = 'pending';
    expect(() => HistorySnapshot.decode(utf8.encode(jsonEncode(j))),
        throwsFormatException);
    expect(() => HistorySnapshot.decode(utf8.encode('[' * 33 + ']' * 33)),
        throwsFormatException);
  });

  test(
      'export excludes pending rows and sanitizes hidden controls and inherited legacy rows',
      () {
    final capture = captureHistory(
        session: const Session(
            baseUrl: origin,
            token: 'secret-token',
            accountId: 'alice',
            deviceId: source),
        namespace: HistoryNamespace(),
        conversations: [conversation],
        messages: [
          message('pending', body: 'unsent secret', state: 'pending'),
          message('hidden', body: 'erased secret', hidden: now),
          message('copied', state: 'restored'),
          message('control').copyWith(
              kind: 'unsupported',
              body: const Value('{"hidden":true,"secret":"control secret"}'))
        ],
        reactions: [],
        pins: [],
        starred: {},
        preferences: [],
        now: now);
    final bytes = capture.encode(), text = utf8.decode(capture.encode());
    expect(text, isNot(contains('unsent secret')));
    expect(text, isNot(contains('erased secret')));
    expect(text, isNot(contains('control secret')));
    expect(text, isNot(contains('secret-token')));
    expect(HistorySnapshot.decode(bytes).messages, hasLength(3));
    expect(capture.origins.containsKey('source:copied'), true);
    expect(
        capture.messages
            .firstWhere((m) => m.key == 'source:control')
            .senderHidden,
        true);
  });

  test(
      'C0 shared rows require historical channel allowlist; isolated rows omit inner channel',
      () {
    final root = jsonDecode(utf8.decode(snapshot([message('a')]).encode()))
        as Map<String, dynamic>;
    root['conversations'] = [
      const HistoryConversation('conv', 'community_shared',
          communityId: 'community',
          historicalChannelIds: ['channel-a']).toJson()
    ];
    root['messages'][0]['channelId'] = 'channel-a';
    expect(
        HistorySnapshot.decode(utf8.encode(jsonEncode(root)))
            .messages
            .single
            .channelId,
        'channel-a');
    root['messages'][0]['channelId'] = 'channel-b';
    expect(() => HistorySnapshot.decode(utf8.encode(jsonEncode(root))),
        throwsFormatException);
    root['conversations'] = [
      const HistoryConversation('conv', 'community_channel',
              communityId: 'community', channelId: 'isolated')
          .toJson()
    ];
    root['messages'][0]['channelId'] = null;
    expect(
        HistorySnapshot.decode(utf8.encode(jsonEncode(root)))
            .messages
            .single
            .channelId,
        isNull);
  });

  test(
      'attachment keys remain manifest-only and context/framing failures reject the snapshot',
      () {
    final manifest = <String, Object?>{
      'id': 'blob',
      'file_name': 'file.txt',
      'media_type': 'text/plain',
      'version': 1,
      'algorithm': 'AES-256-GCM-chunked',
      'key': base64Encode(List.filled(32, 1)),
      'nonce_prefix': base64Encode(List.filled(8, 2)),
      'conversation_id': 'conv',
      'action_id': 'attachment',
      'chunk_size': 1048576,
      'chunk_count': 1,
      'plaintext_size': 32,
      'ciphertext_size': 52
    };
    LocalMessage attachment() => message('attachment')
        .copyWith(kind: 'attachment', body: Value(jsonEncode([manifest])));
    expect(
        HistorySnapshot.decode(snapshot([attachment()]).encode())
            .messages
            .single
            .kind,
        'attachment');
    manifest['conversation_id'] = 'other';
    expect(() => snapshot([attachment()]).encode(), throwsFormatException);
    manifest['conversation_id'] = 'conv';
    manifest['key'] = base64Encode([1]);
    expect(() => snapshot([attachment()]).encode(), throwsFormatException);
    expect(
        () => strictHistoryJson(utf8
            .encode('[${List.filled(historyRecordLimit + 1, 0).join(',')}]')),
        throwsFormatException);
  });

  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite' : 'memory', () {
      late LocalStore store;
      EncryptedLocalDatabase? db;
      late Directory dir;
      setUp(() async {
        FlutterSecureStorage.setMockInitialValues({});
        dir = await Directory.systemTemp.createTemp('veritra-k2-history-');
        db = null;
        store = sqlite
            ? SecureLocalStore(
                directoryProvider: () async => dir,
                databaseFactory: (_, __) =>
                    db ??= EncryptedLocalDatabase(NativeDatabase.memory()))
            : MemoryLocalStore();
        await store.saveSession(const Session(
            baseUrl: origin,
            token: 'receiver-token',
            accountId: 'alice',
            deviceId: 'receiver',
            deviceSecret: 'receiver-secret'));
        await store.saveCryptoState(
            StoredCryptoState(
                counter: 1, stateKey: List.filled(32, 7), sealedState: [8]),
            0);
      });
      tearDown(() async {
        await db?.close();
        await SecureLocalStore.releaseInstanceLocks();
        await dir.delete(recursive: true);
      });

      test(
          'atomic insert is searchable without envelopes and never changes protected state',
          () async {
        await store.saveDraft('conv', 'private draft');
        await store.saveSetting('requests.alice', 'receiver choice');
        await store.saveSyncCursor(73);
        await store.enqueueEnvelope(MessageEnvelope(
            conversationId: 'conv',
            idempotencyKey: 'pending-private',
            ciphertext: [1, 2, 3],
            cryptoProtocol: 'mls10-openmls-v1'));
        final before =
            jsonDecode(utf8.decode(await store.exportBackup())) as Map;
        final bytes = snapshot([
          message('old', body: 'old searchable words', serverId: 'server-old')
        ]).encode();
        await store.importHistorySnapshot(bytes, context());
        final row = (await store.loadMessages('conv')).single;
        expect(row.state, 'restored');
        expect(row.body, 'old searchable words');
        expect((await store.searchMessages('searchable')).single.key, row.key);
        expect((await store.loadSnapshot())?.conversations, isNull);
        expect(
            (await store.loadHistoryNamespace())
                .provenance[row.key]!['source_device_id'],
            source);
        final after =
            jsonDecode(utf8.decode(await store.exportBackup())) as Map;
        for (final name in [
          'session',
          'cursor',
          'outbox',
          'mls_outbox',
          'crypto_state',
          'conversations',
          'messages'
        ]) {
          expect(after[name], before[name], reason: name);
        }
        expect((await store.loadDrafts())['conv']!.text, 'private draft');
        expect(await store.loadSetting('requests.alice'), 'receiver choice');
        await store.importHistorySnapshot(bytes, context());
        expect(await store.loadMessages('conv'), hasLength(1));
        await expectLater(
            store.importHistorySnapshot(bytes, context(digest: 'b' * 64)),
            throwsFormatException);
        await expectLater(
            store.importHistorySnapshot(
                bytes, context(server: 'https://other.test')),
            throwsFormatException);
      });

      test(
          'existing live body and local absence win; identity conflicts reject entire import',
          () async {
        await store
            .saveSnapshot([conversation], {}, await store.loadSyncCursor());
        await insert(store, 'same', body: 'new live body');
        await store.importHistorySnapshot(
            snapshot([
              message('same', body: 'stale'),
              message('new')
            ], starred: {
              'source:same': now
            }, preferences: [
              LocalConversationPref(
                  conversationId: 'conv', archivedAt: now, pinnedAt: now)
            ], reactions: [
              LocalMessageReaction(
                  targetKey: 'source:same',
                  reactorAccountId: 'bob',
                  reaction: 'x',
                  updatedAt: now)
            ]).encode(),
            context());
        expect(
            (await store.loadMessages('conv'))
                .firstWhere((m) => m.key == 'source:same')
                .body,
            'new live body');
        expect(await store.loadStarred(), isEmpty);
        expect(await store.loadReactions('conv'), isEmpty);
        expect(await store.loadConversationPrefs(), isEmpty);
        final bad = message('same').copyWith(senderAccountId: 'mallory');
        await expectLater(
            store.importHistorySnapshot(
                snapshot([message('not-partial'), bad]).encode(),
                context(transfer: 'conflict')),
            throwsFormatException);
        expect(
            (await store.loadMessages('conv'))
                .any((m) => m.key == 'source:not-partial'),
            isFalse);
      });

      test(
          'body-free hidden/deleted tombstones survive copy and never enter FTS',
          () async {
        final rows = [
          message('hidden')
              .copyWith(body: const Value(null), hiddenAt: Value(now)),
          message('deleted')
              .copyWith(body: const Value(null), deletedAt: Value(now)),
          message('expired', expires: now - 1)
        ];
        await store.importHistorySnapshot(snapshot(rows).encode(), context());
        expect(await store.loadMessages('conv'), hasLength(2));
        expect(await store.searchMessages('hidden'), isEmpty);
        await store.importHistorySnapshot(
            snapshot([message('hidden', body: 'resurrection')]).encode(),
            context(transfer: 'later'));
        expect(
            (await store.loadMessages('conv'))
                .firstWhere((m) => m.key == 'source:hidden')
                .body,
            isNull);
        expect(() => snapshot([message('bad', hidden: now)]).encode(),
            throwsFormatException);
      });

      test('fresh preferences seed once; removals survive another transfer',
          () async {
        final bytes = snapshot([
          message('a')
        ], starred: {
          'source:a': now
        }, preferences: [
          LocalConversationPref(
              conversationId: 'conv', archivedAt: now, pinnedAt: now)
        ], pins: [
          LocalPin(
              conversationId: 'conv',
              targetKey: 'source:a',
              pinnedByAccountId: 'bob',
              pinnedAt: now,
              appliedOrder: 1,
              expiresAt: now + 86400000)
        ]).encode();
        await store.importHistorySnapshot(bytes, context());
        expect(await store.loadStarred(), {'source:a'});
        expect(await store.loadPins('conv'), hasLength(1));
        await store.setStarred('source:a', false);
        await store.saveConversationPref(
            const LocalConversationPref(conversationId: 'conv'));
        await store.hideMessage('conv', 'source:a');
        await store.importHistorySnapshot(bytes, context(transfer: 'another'));
        expect(await store.loadStarred(), isEmpty);
        expect(await store.loadPins('conv'), isEmpty);
        expect((await store.loadConversationPrefs()).single.archivedAt, isNull);
      });

      test(
          'backup5 preserves mixed provenance and ledger; legacy restore clears namespace',
          () async {
        final bytes = snapshot([message('imported')]).encode();
        await store.importHistorySnapshot(bytes, context());
        await insert(store, 'direct');
        final backup = await store.exportBackup();
        await store.restoreBackup(backup);
        var ns = await store.loadHistoryNamespace();
        expect(ns.provenance.keys, {'source:imported'});
        expect(ns.imports, hasLength(1));
        await store.importHistorySnapshot(bytes, context());
        final exported =
            HistorySnapshot.decode(await store.exportHistorySnapshot());
        expect(exported.origins.keys, {'source:imported'});
        expect(
            exported.origins['source:imported']!['source_device_id'], source);
        expect(exported.counter, 1);
        final again =
            HistorySnapshot.decode(await store.exportHistorySnapshot());
        expect(again.counter, 2);
        final legacy = jsonDecode(utf8.decode(await store.exportBackup()))
            as Map<String, dynamic>;
        legacy['version'] = 4;
        legacy.remove('history_namespace');
        await store.restoreBackup(utf8.encode(jsonEncode(legacy)));
        ns = await store.loadHistoryNamespace();
        expect(ns.imports, isEmpty);
        expect(ns.provenance, isEmpty);
        expect(ns.conversations, isEmpty);
        expect(ns.counter, 2);
      });

      test('server ID conflicts fail even when target already exists',
          () async {
        await store.importHistorySnapshot(
            snapshot([message('a', serverId: 'duplicate')]).encode(),
            context());
        await expectLater(
            store.importHistorySnapshot(
                snapshot([message('b', serverId: 'duplicate')]).encode(),
                context(transfer: 'collision')),
            throwsFormatException);
        expect(await store.loadMessages('conv'), hasLength(1));
      });

      test(
          'timeline unions history without envelopes and ignores relisted server time',
          () async {
        await store.importHistorySnapshot(
            snapshot([
              message('a', serverId: 'server-a'),
              message('b').copyWith(createdAt: now)
            ]).encode(),
            context());
        final state = AppState(
            apiClientFactory: (base) => ApiClient(baseUrl: base),
            cryptoService: _HistoryMls(),
            localStore: store,
            syncServiceFactory: (_, __) => _QuietSync());
        addTearDown(state.dispose);
        state.session = await store.loadSession();
        state.messagesByConversation['conv'] = [
          ReceivedMessageEnvelope(
              id: 'server-a',
              conversationId: 'conv',
              senderAccountId: 'bob',
              senderDeviceId: source,
              idempotencyKey: 'a',
              ciphertext: [1],
              cryptoProtocol: 'mls10-openmls-v1',
              createdAt: DateTime.fromMillisecondsSinceEpoch(now + 99999))
        ];
        await state.refreshHistory('conv');
        expect(
            state.timelineFor('conv').map((m) => m.idempotencyKey), ['b', 'a']);
        expect(state.conversations, isEmpty,
            reason: 'history does not create live membership');
      });

      test(
          'authenticated absent-target edits/deletes survive restart and dominate later imports/direct originals',
          () async {
        await applyEffects(store, [
          EditMessageEffect(
              targetKey: 'source:edit',
              editorAccountId: 'bob',
              body: 'new authenticated edit',
              at: now + 1,
              conversationId: 'conv'),
          DeleteMessageEffect(
              targetKey: 'source:gone',
              deleterAccountId: 'bob',
              at: now + 2,
              conversationId: 'conv'),
          EditMessageEffect(
              targetKey: 'source:other-actor',
              editorAccountId: 'mallory',
              body: 'forged edit',
              at: now + 3,
              conversationId: 'conv'),
          DeleteMessageEffect(
              targetKey: 'source:other-scope',
              deleterAccountId: 'bob',
              at: now + 4,
              conversationId: 'different-conversation'),
        ]);
        final backup = await store.exportBackup();
        await store.restoreBackup(backup);
        expect((await store.loadHistoryNamespace()).deferred, hasLength(4));
        expect(utf8.decode(await store.exportHistorySnapshot()),
            isNot(contains('new authenticated edit')));
        await store.importHistorySnapshot(
            snapshot([
              message('edit'),
              message('gone'),
              message('other-actor'),
              message('other-scope')
            ]).encode(),
            context());
        var rows = {for (final m in await store.loadMessages('conv')) m.key: m};
        expect(rows['source:edit']!.body, 'new authenticated edit');
        expect(rows['source:gone']!.body, isNull);
        expect(rows['source:gone']!.deletedAt, now + 2);
        expect(rows['source:other-actor']!.body, 'other-actor');
        expect(rows['source:other-scope']!.deletedAt, isNull);
        expect((await store.loadHistoryNamespace()).deferred, hasLength(3),
            reason: 'a copied identity cannot discard mismatched live intents');
        await insert(store, 'edit', body: 'direct original');
        await insert(store, 'gone', body: 'direct original');
        await insert(store, 'other-actor');
        await insert(store, 'other-scope');
        rows = {for (final m in await store.loadMessages('conv')) m.key: m};
        expect(rows['source:edit']!.body, 'new authenticated edit');
        expect(rows['source:gone']!.body, isNull);
        final ns = await store.loadHistoryNamespace();
        expect(ns.deferred.values.single.deleted, true);
        expect(ns.provenance['source:edit']!['direct_received'], true);
        expect(ns.provenance['source:edit']!['live_edit'], true);
      });

      test(
          'copied author substitution cannot erase a prior authenticated delete',
          () async {
        await applyEffects(store, [
          DeleteMessageEffect(
              targetKey: 'source:a',
              deleterAccountId: 'bob',
              at: now + 1,
              conversationId: 'conv'),
        ]);
        await store.importHistorySnapshot(
            snapshot([
              message('a', body: 'copied relabelled row')
                  .copyWith(senderAccountId: 'mallory')
            ]).encode(),
            context());
        expect((await store.loadHistoryNamespace()).deferred, hasLength(1));
        await insert(store, 'a', body: 'direct original');
        final row = (await store.loadMessages('conv')).single;
        expect(row.senderAccountId, 'bob');
        expect(row.body, isNull);
        expect(row.deletedAt, now + 1);
        expect((await store.loadHistoryNamespace()).quarantine, hasLength(1));
        expect(await store.searchMessages('original'), isEmpty);
      });

      test(
          'direct MLS replaces source-only edits; receiver hide and subsequent live edits survive',
          () async {
        await store.importHistorySnapshot(
            snapshot([
              message('a', body: 'source-only edit')
                  .copyWith(editedAt: Value(now + 9999)),
              message('b'),
              message('c')
            ]).encode(),
            context());
        await applyEffects(store, [
          EditMessageEffect(
              targetKey: 'source:b',
              editorAccountId: 'bob',
              body: 'live edit',
              at: now + 1,
              conversationId: 'conv')
        ]);
        await store.hideMessage('conv', 'source:c');
        await insert(store, 'a', body: 'direct body');
        await insert(store, 'b', body: 'original b');
        await insert(store, 'c', body: 'hidden original');
        final rows = {
          for (final m in await store.loadMessages('conv')) m.key: m
        };
        expect(rows['source:a']!.body, 'direct body');
        expect(rows['source:a']!.editedAt, isNull);
        expect(rows['source:b']!.body, 'live edit');
        expect(rows['source:c']!.hiddenAt, isNotNull);
        expect(rows['source:c']!.body, isNull);
      });

      test(
          'conflicting copied identity is quarantined while authenticated sync continues',
          () async {
        final wrong = message('a', body: 'copied conflicting body')
            .copyWith(senderAccountId: 'mallory');
        await store.importHistorySnapshot(
            snapshot([
              wrong
            ], starred: {
              wrong.key: now
            }, reactions: [
              LocalMessageReaction(
                  targetKey: wrong.key,
                  reactorAccountId: 'mallory',
                  reaction: 'x',
                  updatedAt: now)
            ]).encode(),
            context());
        await insert(store, 'a', body: 'authenticated direct body');
        final row = (await store.loadMessages('conv')).single;
        expect(row.senderAccountId, 'bob');
        expect(row.body, 'authenticated direct body');
        expect(await store.loadStarred(), isEmpty);
        expect(await store.loadReactions('conv'), isEmpty);
        var ns = await store.loadHistoryNamespace();
        expect(ns.quarantine, hasLength(1));
        expect(ns.provenance.containsKey(row.key), false);
        expect(await store.searchMessages('conflicting'), isEmpty);
        await store.restoreBackup(await store.exportBackup());
        ns = await store.loadHistoryNamespace();
        expect(ns.quarantine, hasLength(1));
        expect(utf8.decode(await store.exportHistorySnapshot()),
            isNot(contains('copied conflicting body')));
      });

      test('copied server-ID shadows are removed even on a direct duplicate',
          () async {
        await insert(store, 'direct',
            body: 'authenticated first', serverId: 'server-original');
        final copied = message('copied',
            body: 'shadow copied body', serverId: 'server-relisted');
        await store.importHistorySnapshot(
            snapshot([
              copied
            ], starred: {
              copied.key: now
            }, reactions: [
              LocalMessageReaction(
                  targetKey: copied.key,
                  reactorAccountId: 'bob',
                  reaction: 'x',
                  updatedAt: now),
            ]).encode(),
            context());
        await insert(store, 'direct',
            body: 'duplicate direct body', serverId: 'server-relisted');
        final rows = await store.loadMessages('conv');
        expect(rows, hasLength(1));
        expect(rows.single.key, 'source:direct');
        expect(rows.single.body, 'authenticated first',
            reason: 'direct-vs-direct duplicate behavior stays unchanged');
        expect(await store.loadStarred(), isEmpty);
        expect(await store.loadReactions('conv'), isEmpty);
        expect((await store.loadHistoryNamespace()).quarantine, hasLength(1));
        expect(await store.searchMessages('shadow'), isEmpty);
      });

      if (sqlite)
        test('ledger failure rolls back rows, namespace, preferences and FTS',
            () async {
          // Open the database before adding an adversarial failure point.
          await store.loadMessages('conv');
          await db!.customStatement(
              "CREATE TRIGGER fail_history_ledger BEFORE INSERT ON local_history_imports BEGIN SELECT RAISE(ABORT,'injected'); END");
          final bytes =
              snapshot([message('rollback', body: 'rollback searchable')])
                  .encode();
          await expectLater(
              store.importHistorySnapshot(bytes, context()), throwsA(anything));
          expect(await store.loadMessages('conv'), isEmpty);
          expect(await store.searchMessages('rollback'), isEmpty);
          expect((await store.loadHistoryNamespace()).conversations, isEmpty);
          await db!.customStatement('DROP TRIGGER fail_history_ledger');
          await store.importHistorySnapshot(bytes, context());
          expect((await store.searchMessages('rollback')), hasLength(1));
        });
    });
  }

  for (final version in [12, 13]) {
    for (final fail in [false, true]) {
      test(
          'schema$version to14 ${fail ? 'rolls back and retries' : 'preserves data'}',
          () async {
        final dir =
            await Directory.systemTemp.createTemp('veritra-k2-migration-');
        final file = File('${dir.path}/local.db');
        var db = EncryptedLocalDatabase(NativeDatabase(file));
        addTearDown(() async {
          await db.close();
          await dir.delete(recursive: true);
        });
        await db.applyMessageEffects([
          const InsertMessageEffect(
              key: 'source:a',
              conversationId: 'conv',
              senderAccountId: 'bob',
              senderDeviceId: source,
              kind: 'text',
              body: 'preserved',
              createdAt: 1,
              state: 'received')
        ]);
        await stripNoticeSchema(db);
        if (version == 12) {
          await stripW8Schema(db);
        } else {
          for (final table in EncryptedLocalDatabase.historyTables) {
            await db.customStatement('DROP TABLE $table');
          }
        }
        await db.customStatement('PRAGMA user_version = $version');
        if (fail)
          await db.customStatement(
              'CREATE INDEX local_history_imports ON local_messages(key)');
        await db.close();
        db = EncryptedLocalDatabase(NativeDatabase(file));
        if (fail) {
          await expectLater(db.readMessages('conv'), throwsA(anything));
          await db.close();
          final raw = sqlite3.open(file.path);
          try {
            expect(raw.select('PRAGMA user_version').single['user_version'],
                version);
            expect(
                raw.select(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name='local_history_conversations'"),
                isEmpty);
            expect(raw.select('SELECT body FROM local_messages').single['body'],
                'preserved');
            raw.execute('DROP INDEX local_history_imports');
          } finally {
            raw.close();
          }
          db = EncryptedLocalDatabase(NativeDatabase(file));
        }
        expect((await db.readMessages('conv')).single.body, 'preserved');
        expect((await db.readHistoryNamespace()).counter, 0);
        expect(
            (await db.customSelect('PRAGMA user_version').getSingle())
                .read<int>('user_version'),
            EncryptedLocalDatabase.currentSchemaVersion);
      });
    }
  }
}

class _HistoryMls implements MlsConversationCryptoService {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}
