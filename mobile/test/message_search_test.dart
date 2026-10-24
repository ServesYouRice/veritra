import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/search/search_screen.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/storage/message_search.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// W10: search finds the message text this device holds, through an index in
/// the encrypted local database, and nothing about it reaches the server.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('words and snippets', () {
    test('a query becomes plain words, however odd the input', () {
      expect(searchTerms('Hello, WORLD!'), <String>['hello', 'world']);
      expect(searchTerms('  "quoted" NEAR( OR * - ^ :col '),
          <String>['quoted', 'near', 'or', 'col']);
      expect(searchTerms('ćevapi Ђорђе 42'), <String>['ćevapi', 'ђорђе', '42']);
      expect(searchTerms('!!!'), isEmpty);
      expect(searchTerms(List<String>.generate(20, (i) => 'w$i').join(' ')),
          hasLength(maxSearchTerms));
      expect(ftsQueryFor(<String>['a', 'b"c']), '"a" "b""c"*');
    });

    test('a snippet marks the matches and keeps the text', () {
      final snippet =
          snippetFor('Meet me at the Station at noon', <String>['station']);
      expect(snippet, 'Meet me at the \u0001Station\u0002 at noon');
      final long = '${'word ' * 40}needle${' word' * 40}';
      final cut = snippetFor(long, <String>['needle']);
      expect(cut, contains('\u0001needle\u0002'));
      expect(cut.startsWith('…'), isTrue);
      expect(cut.endsWith('…'), isTrue);
      expect(cut.length, lessThan(130));
    });
  });

  group('encrypted database', () {
    late Directory directory;
    late List<EncryptedLocalDatabase> databases;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      directory = await Directory.systemTemp.createTemp('veritra-search-');
      databases = <EncryptedLocalDatabase>[];
    });

    tearDown(() async {
      for (final database in databases) {
        await database.close();
      }
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    SecureLocalStore createStore() => SecureLocalStore(
          storage: const FlutterSecureStorage(),
          directoryProvider: () async => directory,
          databaseFactory: (file, keyHex) {
            final database = openEncryptedLocalDatabase(file, keyHex);
            databases.add(database);
            return database;
          },
        );

    Future<EncryptedLocalDatabase> open(SecureLocalStore store) async {
      await store.saveSyncCursor(0);
      return databases.last;
    }

    InsertMessageEffect message(
      String id,
      String body, {
      int at = 1,
      String conversation = 'conv_1',
      String kind = LocalMessageKind.text,
      int? expiresAt,
    }) =>
        InsertMessageEffect(
          key: 'dev_peer:$id',
          serverMessageId: id,
          conversationId: conversation,
          senderAccountId: 'acct_peer',
          senderDeviceId: 'dev_peer',
          kind: kind,
          body: body,
          createdAt: at,
          state: LocalMessageState.received,
          expiresAt: expiresAt,
        );

    Future<List<String>> found(SecureLocalStore store, String query) async => [
          for (final hit in await store.searchMessages(query)) hit.key,
        ];

    /// Every term the index still holds, as the index itself reports them.
    Future<Set<String>> indexedTerms(EncryptedLocalDatabase database) async {
      await database.customStatement(
          'CREATE VIRTUAL TABLE IF NOT EXISTS temp.search_terms USING '
          "fts5vocab(main, 'local_message_search', 'row')");
      final rows = await database
          .customSelect('SELECT term FROM temp.search_terms')
          .get();
      return {for (final row in rows) row.read<String>('term')};
    }

    test('FTS5 is available in this build', () async {
      final database = await open(createStore());
      final row = await database
          .customSelect("SELECT sqlite_compileoption_used('ENABLE_FTS5') AS ok")
          .getSingle();
      expect(row.read<int>('ok'), 1);
      final table = await database
          .customSelect("SELECT sql FROM sqlite_master "
              "WHERE name = 'local_message_search'")
          .getSingle();
      expect(table.read<String>('sql'), contains('fts5'));
    });

    test('finds words without regard to case, accents or word end', () async {
      final store = createStore();
      final database = await open(store);
      await database.applyMessageEffects(<MessageEffect>[
        message('a', 'Meet me at the station at noon', at: 10),
        message('b', 'Ćevapi for dinner, anyone?', at: 20),
        message('c', 'Station closed, take the bus', at: 30),
        message('d', 'Привет, где станция?', at: 40),
      ]);
      // Newest first.
      expect(
          await found(store, 'station'), <String>['dev_peer:c', 'dev_peer:a']);
      expect(await found(store, 'STATION noon'), <String>['dev_peer:a']);
      expect(await found(store, 'stat'), <String>['dev_peer:c', 'dev_peer:a'],
          reason: 'the last word may be unfinished');
      expect(await found(store, 'cevapi'), <String>['dev_peer:b']);
      expect(await found(store, 'ЧЕВАПИ'), isEmpty);
      expect(await found(store, 'станция'), <String>['dev_peer:d']);
      expect(await found(store, 'dinner bus'), isEmpty,
          reason: 'every word has to match');
      expect(await found(store, ''), isEmpty);
      expect(await found(store, '   '), isEmpty);
      final hit = (await store.searchMessages('noon')).single;
      expect(hit.conversationId, 'conv_1');
      expect(hit.snippet, contains('\u0001noon\u0002'));
      expect(hit.createdAt, 10);
    });

    test('odd input is just words, never search syntax', () async {
      final store = createStore();
      final database = await open(store);
      await database.applyMessageEffects(<MessageEffect>[
        message('a', 'plain text with a "quote" and OR and AND'),
      ]);
      for (final input in <String>[
        '"',
        '""',
        'a OR',
        'NEAR(a b)',
        '*',
        'body:plain',
        '-plain',
        '^plain',
        'plain AND',
        '(',
        "'; DROP TABLE local_messages; --",
      ]) {
        await store.searchMessages(input); // must not throw
      }
      // A column filter is just two words here, and the text has no "body".
      expect(await found(store, 'body:plain'), isEmpty);
      expect(await found(store, 'plain:'), <String>['dev_peer:a']);
      expect(await found(store, '"quote"'), <String>['dev_peer:a']);
      expect(
          (await database.select(database.localMessages).get()), hasLength(1));
    });

    test('only message text is indexed', () async {
      final store = createStore();
      final database = await open(store);
      await database.applyMessageEffects(<MessageEffect>[
        message('a', 'visible words'),
        message('b', '[{"key":"secretattachmentkey"}]',
            kind: LocalMessageKind.attachment),
        message('c', 'unverifiable words', kind: LocalMessageKind.unverifiable),
        message('d', 'action words', kind: LocalMessageKind.action),
      ]);
      expect(await found(store, 'words'), <String>['dev_peer:a']);
      expect(await found(store, 'secretattachmentkey'), isEmpty);
      expect(await indexedTerms(database), <String>{'visible', 'words'});
    });

    test('an edit replaces the indexed text, a delete removes it', () async {
      final store = createStore();
      final database = await open(store);
      await database.applyMessageEffects(<MessageEffect>[
        message('a', 'first draft wording'),
      ]);
      await database.applyMessageEffects(<MessageEffect>[
        const EditMessageEffect(
          targetKey: 'dev_peer:a',
          editorAccountId: 'acct_peer',
          body: 'second version',
          at: 5,
        ),
      ]);
      expect(await found(store, 'wording'), isEmpty);
      expect(await found(store, 'second'), <String>['dev_peer:a']);
      expect(await indexedTerms(database), <String>{'second', 'version'});

      await database.applyMessageEffects(<MessageEffect>[
        const DeleteMessageEffect(
          targetKey: 'dev_peer:a',
          deleterAccountId: 'acct_peer',
          at: 6,
        ),
      ]);
      expect(await found(store, 'second'), isEmpty);
      expect(await indexedTerms(database), isEmpty,
          reason: 'deleted text leaves the index, not just the results');
    });

    test('expired messages leave the index with the purge', () async {
      final store = createStore();
      final database = await open(store);
      final soon = DateTime.now().toUtc().add(const Duration(seconds: 2));
      await database.applyMessageEffects(<MessageEffect>[
        message('gone', 'ephemeralsecret words',
            expiresAt: soon.millisecondsSinceEpoch),
        message('kept', 'permanent words'),
      ]);
      expect(await found(store, 'ephemeralsecret'), <String>['dev_peer:gone']);
      await store.purgeExpiredMessages(
          now: soon.add(const Duration(seconds: 1)));
      expect(await found(store, 'ephemeralsecret'), isEmpty);
      expect(await found(store, 'words'), <String>['dev_peer:kept']);
      expect(await indexedTerms(database), <String>{'permanent', 'words'});
    });

    test('signing out and resetting empty the index', () async {
      final store = createStore();
      final database = await open(store);
      await database.applyMessageEffects(<MessageEffect>[
        message('a', 'remember this phrase'),
      ]);
      expect(await found(store, 'phrase'), isNotEmpty);
      await store.clear();
      expect(await found(store, 'phrase'), isEmpty);
      expect(await indexedTerms(database), isEmpty);
      final left = await database
          .customSelect('SELECT count(*) AS n FROM local_message_search')
          .getSingle();
      expect(left.read<int>('n'), 0);
    });

    test('the index follows a restored backup, whatever its numbers were',
        () async {
      final store = createStore();
      final database = await open(store);
      await database.applyMessageEffects(<MessageEffect>[
        message('a', 'alpha one', at: 1),
        message('b', 'beta two', at: 2),
        message('c', 'gamma three', at: 3),
      ]);
      final history = await database.readAllMessages();
      expect(history.every((item) => item.searchId != null), isTrue);
      await database.restoreBackupState(
        sessionJson: '{}',
        conversations: const [],
        envelopes: const [],
        outbox: const [],
        mlsOutbox: const [],
        cryptoState: (
          counter: 1,
          stateKey: List<int>.filled(32, 1),
          sealedState: <int>[1]
        ),
        cursor: 0,
        // Reversed, so the old index numbers arrive out of order.
        history: history.reversed.toList(),
      );
      expect(await found(store, 'alpha'), <String>['dev_peer:a']);
      expect(await found(store, 'beta'), <String>['dev_peer:b']);
      expect(await found(store, 'gamma'), <String>['dev_peer:c']);
      await database.applyMessageEffects(<MessageEffect>[
        message('d', 'delta four', at: 4),
      ]);
      expect(await found(store, 'delta'), <String>['dev_peer:d']);
    });

    test('an upgrade from schema 11 indexes the text already stored', () async {
      final store = createStore();
      final database = await open(store);
      await database.applyMessageEffects(<MessageEffect>[
        message('a', 'written before the index', at: 1),
        message('b', 'attachment', kind: LocalMessageKind.attachment),
      ]);
      for (final trigger in <String>[
        'local_messages_search_ai',
        'local_messages_search_au',
        'local_messages_search_ad',
      ]) {
        await database.customStatement('DROP TRIGGER $trigger');
      }
      await database.customStatement('DROP TABLE local_message_search');
      await database.customStatement('DROP INDEX local_messages_search_id');
      await database
          .customStatement('ALTER TABLE local_messages DROP COLUMN search_id');
      await database.customStatement('PRAGMA user_version = 11');
      await database.close();
      databases.removeLast();

      final upgraded = createStore();
      expect(await found(upgraded, 'index'), <String>['dev_peer:a']);
      final reopened = databases.last;
      final version =
          await reopened.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 12);
      // And it stays in step afterwards.
      await reopened.applyMessageEffects(<MessageEffect>[
        message('c', 'written after the index', at: 3),
      ]);
      expect(
          await found(upgraded, 'index'), <String>['dev_peer:c', 'dev_peer:a']);
    });

    test('without FTS5 the same search scans the stored text', () async {
      final store = createStore();
      final database = await open(store);
      await database.applyMessageEffects(<MessageEffect>[
        message('a', 'Station at noon', at: 1),
        message('b', 'no match here', at: 2),
      ]);
      for (final trigger in <String>[
        'local_messages_search_ai',
        'local_messages_search_au',
        'local_messages_search_ad',
      ]) {
        await database.customStatement('DROP TRIGGER $trigger');
      }
      await database.customStatement('DROP TABLE local_message_search');
      final hits = await store.searchMessages('station');
      expect(hits.map((hit) => hit.key), <String>['dev_peer:a']);
      expect(hits.single.snippet, '\u0001Station\u0002 at noon');
    });
  });

  test('the memory store searches the same way', () async {
    final store = MemoryLocalStore();
    await store.saveCryptoState(
      StoredCryptoState(
        counter: 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[1],
      ),
      0,
    );
    await store.commitMlsTransition(MlsStateTransition(
      messageId: 'm1',
      conversationId: 'conv_1',
      expectedCounter: 1,
      expectedCursor: 0,
      state: StoredCryptoState(
        counter: 2,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[2],
      ),
      cursor: 1,
      messageEffects: <MessageEffect>[
        const InsertMessageEffect(
          key: 'dev_peer:a',
          conversationId: 'conv_1',
          senderAccountId: 'acct_peer',
          senderDeviceId: 'dev_peer',
          kind: LocalMessageKind.text,
          body: 'Meet at the Station',
          createdAt: 1,
          state: LocalMessageState.received,
        ),
      ],
    ));
    final hits = await store.searchMessages('station meet');
    expect(hits.single.key, 'dev_peer:a');
    expect(await store.searchMessages('absent'), isEmpty);
  });

  testWidgets('opening a result scrolls to that message and marks it',
      (tester) async {
    final store = MemoryLocalStore();
    await store.saveCryptoState(
      StoredCryptoState(
        counter: 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[1],
      ),
      0,
    );
    await store.commitMlsTransition(MlsStateTransition(
      messageId: 'm1',
      conversationId: 'conv_1',
      expectedCounter: 1,
      expectedCursor: 0,
      state: StoredCryptoState(
        counter: 2,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[2],
      ),
      cursor: 1,
      messageEffects: <MessageEffect>[
        for (var i = 1; i <= 150; i++)
          InsertMessageEffect(
            key: 'dev_peer:m$i',
            conversationId: 'conv_1',
            senderAccountId: 'acct_peer',
            senderDeviceId: 'dev_peer',
            kind: LocalMessageKind.text,
            body: 'message number $i',
            createdAt:
                DateTime.utc(2026, 10, 24, 8, 0, i).millisecondsSinceEpoch,
            state: LocalMessageState.received,
          ),
      ],
    ));
    final state = AppState(
      apiClientFactory: (_) => _SearchApi(),
      cryptoService: _MlsStub(),
      localStore: store,
      syncServiceFactory: (_, __) => _IdleSync(),
    )
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'token',
        accountId: 'acct_own',
        deviceId: 'dev_own',
      )
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group', title: 'Team'),
      ];
    await state.refreshHistory('conv_1');
    expect(state.timelineFor('conv_1'), hasLength(150));

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        state: state,
        conversationId: 'conv_1',
        initialMessageKey: 'dev_peer:m12',
      ),
    ));
    await tester.pumpAndSettle();
    // Message 12 is far back: it is on screen, and the newest is not.
    expect(find.text('message number 12'), findsOneWidget);
    expect(find.text('message number 150'), findsNothing);
    expect(find.byTooltip('Jump to latest'), findsOneWidget);
    // The mark goes by itself.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('message number 12'), findsOneWidget);

    // A message this device no longer holds leaves the chat where it was.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        state: state,
        conversationId: 'conv_1',
        initialMessageKey: 'dev_peer:gone',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('message number 150'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('search screen', () {
    late MemoryLocalStore store;
    late _SearchApi api;
    late AppState state;

    Future<void> start() async {
      store = MemoryLocalStore();
      await store.saveSession(const Session(
        baseUrl: 'https://localhost:8080',
        token: 'token',
        accountId: 'acct_own',
        deviceId: 'dev_own',
      ));
      await store.saveCryptoState(
        StoredCryptoState(
          counter: 1,
          stateKey: List<int>.filled(32, 1),
          sealedState: <int>[1],
        ),
        0,
      );
      await store.commitMlsTransition(MlsStateTransition(
        messageId: 'm1',
        conversationId: 'conv_1',
        expectedCounter: 1,
        expectedCursor: 0,
        state: StoredCryptoState(
          counter: 2,
          stateKey: List<int>.filled(32, 1),
          sealedState: <int>[2],
        ),
        cursor: 1,
        messageEffects: <MessageEffect>[
          const InsertMessageEffect(
            key: 'dev_peer:a',
            conversationId: 'conv_1',
            senderAccountId: 'acct_peer',
            senderDeviceId: 'dev_peer',
            kind: LocalMessageKind.text,
            body: 'The launch code is swordfish',
            createdAt: 1,
            state: LocalMessageState.received,
          ),
        ],
      ));
      api = _SearchApi();
      state = AppState(
        apiClientFactory: (_) => api,
        cryptoService: TestOnlyCryptoService(),
        localStore: store,
        syncServiceFactory: (_, __) => _IdleSync(),
      );
      await state.tryRestoreSession();
    }

    Widget app(Widget child) => MaterialApp(home: child);

    testWidgets(
        'a message search shows the chat name and never calls the '
        'server', (tester) async {
      await start();
      await tester.pumpWidget(app(SearchScreen(state: state)));
      await tester.pumpAndSettle();
      expect(find.text('Search this device'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'swordfish');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Team'), findsOneWidget, reason: 'the chat name');
      expect(find.textContaining('launch code', findRichText: true),
          findsOneWidget);
      expect(api.metadataQueries, isEmpty,
          reason: 'message text must stay on this device');

      // Only the other mode asks the server, and only after it is chosen.
      await tester.tap(find.text('People and communities'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(api.metadataQueries, <String>['swordfish']);
      state.dispose();
    });

    testWidgets('tapping a result opens that chat at the message',
        (tester) async {
      await start();
      await tester.pumpWidget(app(SearchScreen(state: state)));
      await tester.enterText(find.byType(TextField), 'swordfish');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Team'));
      await tester.pumpAndSettle();
      final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
      expect(chat.conversationId, 'conv_1');
      expect(chat.initialMessageKey, 'dev_peer:a');
      state.dispose();
    });
  });
}

class _MlsStub implements MlsConversationCryptoService {
  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _SearchApi extends ApiClient {
  _SearchApi() : super(baseUrl: 'https://localhost:8080');

  final List<String> metadataQueries = <String>[];

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[Conversation(id: 'conv_1', kind: 'group', title: 'Team')];

  @override
  Future<List<Device>> devices(String token) async => <Device>[];

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);

  @override
  Future<ConversationMute> conversationMute(
          String token, String conversationId) async =>
      const ConversationMute(muted: false);

  @override
  Future<List<ConversationMember>> conversationMembers(
    String token,
    String conversationId,
  ) async =>
      <ConversationMember>[];

  @override
  Future<List<MetadataSearchResult>> searchMetadata(
    String token,
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    metadataQueries.add(query);
    return <MetadataSearchResult>[];
  }
}

class _IdleSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}
