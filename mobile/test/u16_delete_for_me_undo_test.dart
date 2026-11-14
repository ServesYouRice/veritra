import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/message_history.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// U16 (D133): "Delete for me" hides a message at once and deletes it for
/// good only when the Undo window closes, or on the next start when the app
/// was stopped during the window. While hidden it shows nowhere: not in the
/// chat, the chat-list preview (U12), search (W10) or a notice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-u16-');
    databases = <EncryptedLocalDatabase>[];
  });

  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    await SecureLocalStore.releaseInstanceLocks();
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

  Future<void> closeAll() async {
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
  }

  Future<void> seed(LocalStore store) async {
    await store.saveCryptoState(
      StoredCryptoState(
        counter: 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[1],
      ),
      0,
    );
    await store.saveProjection(
      <Conversation>[Conversation(id: 'conv_1', kind: 'group')],
      const <String, List<ReceivedMessageEnvelope>>{},
    );
  }

  /// Commits [effects] (and [reveals]) like the native service does.
  Future<void> commit(LocalStore store, List<MessageEffect> effects,
      {List<FrankReveal> reveals = const <FrankReveal>[]}) async {
    final counter = (await store.loadCryptoState())!.counter;
    final cursor = await store.loadSyncCursor();
    await store.commitMlsTransition(MlsStateTransition(
      messageId: 'application:${cursor + 1}',
      conversationId: 'conv_1',
      expectedCounter: counter,
      expectedCursor: cursor,
      state: StoredCryptoState(
        counter: counter + 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[counter + 1],
      ),
      cursor: cursor + 1,
      messageEffects: effects,
      frankReveals: reveals,
    ));
  }

  Future<void> receive(LocalStore store, String id, String body,
          {int createdAt = 1000, int? expiresAt}) =>
      commit(store, <MessageEffect>[
        InsertMessageEffect(
          key: 'dev_peer:$id',
          serverMessageId: 'msg_$id',
          conversationId: 'conv_1',
          senderAccountId: 'acct_peer',
          senderDeviceId: 'dev_peer',
          kind: LocalMessageKind.text,
          body: body,
          createdAt: createdAt,
          state: LocalMessageState.received,
          expiresAt: expiresAt,
        ),
      ], reveals: <FrankReveal>[
        FrankReveal(
          messageKey: 'dev_peer:$id',
          conversationId: 'conv_1',
          envelopeId: 'msg_$id',
          frankKey: List<int>.filled(32, 7),
          payload: '{"v":2,"type":"text","body":{"text":"$body"}}'.codeUnits,
        ),
      ]);

  Future<LocalMessage> row(LocalStore store, String id) async =>
      (await store.loadMessages('conv_1'))
          .firstWhere((m) => m.key == 'dev_peer:$id');

  /// What the chat list would quote (U12).
  Future<String?> preview(LocalStore store) async => ConversationHistory(
        conversationId: 'conv_1',
        messages: await store.loadMessages('conv_1'),
        reactions: const <LocalMessageReaction>[],
      ).latestForPreview(nowMs: DateTime.now().millisecondsSinceEpoch)?.body;

  Future<List<String>> found(LocalStore store, String query) async => [
        for (final hit in await store.searchMessages(query)) hit.key,
      ];

  /// A message with a reaction, a star and a pin, below an older one.
  Future<void> withExtras(LocalStore store) async {
    await seed(store);
    await receive(store, 'old', 'older words', createdAt: 500);
    await receive(store, 'b', 'secret words');
    final now = DateTime.now().millisecondsSinceEpoch;
    await commit(store, <MessageEffect>[
      ReactionEffect(
          targetKey: 'dev_peer:b',
          reactorAccountId: 'acct_own',
          reaction: '👍',
          at: now,
          conversationId: 'conv_1'),
      PinMessageEffect(
          conversationId: 'conv_1',
          targetKey: 'dev_peer:b',
          accountId: 'acct_own',
          at: now,
          pinned: true,
          durationSeconds: 86400),
    ]);
    await store.setStarred('dev_peer:b', true);
  }

  final stores = <String, LocalStore Function()>{
    'memory': MemoryLocalStore.new,
    'encrypted': createStore,
  };

  for (final MapEntry(key: name, value: make) in stores.entries) {
    group('$name store', () {
      test('while hidden it shows nowhere; Undo brings it back whole',
          () async {
        final store = make();
        await withExtras(store);
        expect(await preview(store), 'secret words');
        expect(await found(store, 'secret'), <String>['dev_peer:b']);

        expect(await store.hideMessage('conv_1', 'dev_peer:b'), isTrue);
        final hidden = await row(store, 'b');
        expect(hidden.hiddenAt, isNotNull);
        expect(hidden.body, isNull);
        // Not in the chat, the chat-list preview, search, reactions, pins,
        // stars, or the reveal a report would read.
        final history = ConversationHistory(
          conversationId: 'conv_1',
          messages: await store.loadMessages('conv_1'),
          reactions: await store.loadReactions('conv_1'),
        );
        expect(
            history.hides(ReceivedMessageEnvelope(
              id: 'msg_b',
              conversationId: 'conv_1',
              senderAccountId: 'acct_peer',
              senderDeviceId: 'dev_peer',
              idempotencyKey: 'b',
              ciphertext: const <int>[1],
              cryptoProtocol: 'mls10-openmls-v1',
              createdAt: DateTime.utc(2026, 11, 14),
            )),
            isTrue);
        expect(await preview(store), 'older words');
        expect(await found(store, 'secret'), isEmpty);
        expect(await store.loadReactions('conv_1'), isEmpty);
        expect(await store.loadPins('conv_1'), isEmpty);
        expect(await store.loadStarred(), isEmpty);
        expect(await store.loadFrankReveal('dev_peer:b'), isNull);
        // A second hide changes nothing and keeps the first copy.
        expect(await store.hideMessage('conv_1', 'dev_peer:b'), isFalse);

        expect(await store.unhideMessage('dev_peer:b'), isTrue);
        final back = await row(store, 'b');
        expect(back.hiddenAt, isNull);
        expect(back.body, 'secret words');
        expect(await preview(store), 'secret words');
        expect(await found(store, 'secret'), <String>['dev_peer:b']);
        expect(await store.loadReactions('conv_1'), hasLength(1));
        expect(await store.loadPins('conv_1'), hasLength(1));
        expect(await store.loadStarred(), <String>{'dev_peer:b'});
        expect(await store.loadFrankReveal('dev_peer:b'), isNotNull);
        expect(await store.unhideMessage('dev_peer:b'), isFalse);
      });

      test('once finished, Undo finds nothing to bring back', () async {
        final store = make();
        await withExtras(store);
        await store.hideMessage('conv_1', 'dev_peer:b');
        await store.finishHiddenMessages(only: <String>{'dev_peer:b'});
        expect(await store.unhideMessage('dev_peer:b'), isFalse);
        final gone = await row(store, 'b');
        expect(gone.hiddenAt, isNotNull);
        expect(gone.body, isNull);
        expect(await found(store, 'secret'), isEmpty);
        expect(await preview(store), 'older words');
        expect(await store.loadFrankReveal('dev_peer:b'), isNull);
      });

      test('finishing all leaves an open window that is excepted', () async {
        final store = make();
        await withExtras(store);
        await store.hideMessage('conv_1', 'dev_peer:b');
        await store.hideMessage('conv_1', 'dev_peer:old');
        await store.finishHiddenMessages(except: <String>{'dev_peer:b'});
        expect(await store.unhideMessage('dev_peer:old'), isFalse);
        expect(await store.unhideMessage('dev_peer:b'), isTrue);
      });

      test('a message deleted for everyone comes back as its tombstone',
          () async {
        final store = make();
        await withExtras(store);
        await commit(store, <MessageEffect>[
          DeleteMessageEffect(
              targetKey: 'dev_peer:b',
              deleterAccountId: 'acct_peer',
              at: DateTime.now().millisecondsSinceEpoch,
              conversationId: 'conv_1'),
        ]);
        expect(await store.hideMessage('conv_1', 'dev_peer:b'), isTrue);
        expect(await store.unhideMessage('dev_peer:b'), isTrue);
        final back = await row(store, 'b');
        expect(back.hiddenAt, isNull);
        expect(back.deletedAt, isNotNull);
        expect(back.body, isNull);
        expect(await found(store, 'secret'), isEmpty);
      });

      test('a delete for everyone during the window wins over Undo', () async {
        final store = make();
        await withExtras(store);
        await store.hideMessage('conv_1', 'dev_peer:b');
        await commit(store, <MessageEffect>[
          DeleteMessageEffect(
              targetKey: 'dev_peer:b',
              deleterAccountId: 'acct_peer',
              at: DateTime.now().millisecondsSinceEpoch,
              conversationId: 'conv_1'),
        ]);
        expect(await store.unhideMessage('dev_peer:b'), isFalse);
        final kept = await row(store, 'b');
        expect(kept.hiddenAt, isNotNull);
        expect(kept.body, isNull);
        expect(await found(store, 'secret'), isEmpty);
      });

      test('an edit during the window makes the delete final', () async {
        final store = make();
        await withExtras(store);
        await store.hideMessage('conv_1', 'dev_peer:b');
        await commit(store, <MessageEffect>[
          EditMessageEffect(
              targetKey: 'dev_peer:b',
              editorAccountId: 'acct_peer',
              body: 'edited secret',
              at: DateTime.now().millisecondsSinceEpoch,
              conversationId: 'conv_1'),
        ]);
        expect(await store.unhideMessage('dev_peer:b'), isFalse);
        expect((await row(store, 'b')).body, isNull);
        expect(await found(store, 'secret'), isEmpty);
      });

      test('a message that expires during the window goes with what it kept',
          () async {
        final store = make();
        await seed(store);
        final soon = DateTime.now().toUtc().add(const Duration(minutes: 5));
        await receive(store, 'b', 'secret words',
            expiresAt: soon.millisecondsSinceEpoch);
        await store.hideMessage('conv_1', 'dev_peer:b');
        final touched = await store.purgeExpiredMessages(
            now: soon.add(const Duration(seconds: 1)));
        expect(touched, contains('conv_1'));
        expect(await store.loadMessages('conv_1'), isEmpty);
        expect(await store.unhideMessage('dev_peer:b'), isFalse);
      });
    });
  }

  group('encrypted database', () {
    Future<int> count(String sql) async =>
        (await databases.last.customSelect(sql).getSingle()).read<int>('n');
    Future<int> kept() => count('SELECT COUNT(*) AS n FROM local_hide_undo');
    Future<int> indexed(String word) =>
        count('SELECT COUNT(*) AS n FROM local_message_search '
            "WHERE local_message_search MATCH '$word'");
    Future<int> reveals(String key) =>
        count('SELECT COUNT(*) AS n FROM local_frank_reveals '
            "WHERE message_key = '$key'");
    Future<int> bodies(String text) =>
        count("SELECT COUNT(*) AS n FROM local_messages WHERE body = '$text'");

    test('the text leaves the message row and the index at once', () async {
      final store = createStore();
      await withExtras(store);
      expect(await indexed('secret'), 1);
      await store.hideMessage('conv_1', 'dev_peer:b');
      expect(await bodies('secret words'), 0);
      expect(await indexed('secret'), 0);
      // Kept aside for Undo, with the reveal, until the window closes.
      expect(await kept(), 1);
      expect(await reveals('dev_peer:b'), 1);

      await store.unhideMessage('dev_peer:b');
      expect(await kept(), 0);
      expect(await indexed('secret'), 1);

      await store.hideMessage('conv_1', 'dev_peer:b');
      await store.finishHiddenMessages(only: <String>{'dev_peer:b'});
      expect(await kept(), 0);
      expect(await indexed('secret'), 0);
      expect(await bodies('secret words'), 0);
      expect(await reveals('dev_peer:b'), 0);
      // The other message keeps its reveal.
      expect(await reveals('dev_peer:old'), 1);
    });

    test('an expiry purge takes what the hide kept (W2)', () async {
      final store = createStore();
      await seed(store);
      final soon = DateTime.now().toUtc().add(const Duration(minutes: 5));
      await receive(store, 'b', 'secret words',
          expiresAt: soon.millisecondsSinceEpoch);
      await store.hideMessage('conv_1', 'dev_peer:b');
      expect(await kept(), 1);
      await store.purgeExpiredMessages(
          now: soon.add(const Duration(seconds: 1)));
      expect(await kept(), 0);
      expect(await reveals('dev_peer:b'), 0);
    });

    test('a backup taken during the window carries no text of it', () async {
      final store = createStore();
      await withExtras(store);
      await store.saveSession(const Session(
        baseUrl: 'https://localhost:8080',
        token: 'token',
        accountId: 'acct_own',
        deviceId: 'dev_own',
      ));
      await store.hideMessage('conv_1', 'dev_peer:b');
      final bytes = await store.exportHistorySnapshot();
      expect(String.fromCharCodes(bytes), isNot(contains('secret words')));
    });
  });

  group('app state', () {
    AppState appState(LocalStore store) => AppState(
          apiClientFactory: (_) => _OfflineApiClient(),
          cryptoService: TestOnlyCryptoService(),
          localStore: store,
          syncServiceFactory: (_, __) => _IdleSyncService(),
        );

    test('Undo restores the chat and its chat-list preview', () async {
      final store = MemoryLocalStore();
      await withExtras(store);
      final state = appState(store);
      addTearDown(state.dispose);
      await state.refreshHistory('conv_1');
      final message = state.historyFor('conv_1').forKey('dev_peer:b')!;
      expect(state.chatPreviewFor('conv_1')?.body, 'secret words');

      expect(await state.deleteMessageForMe(message), isTrue);
      expect(
          state.historyFor('conv_1').forKey('dev_peer:b')!.hiddenAt, isNotNull);
      expect(state.chatPreviewFor('conv_1')?.body, 'older words');

      expect(await state.undoDeleteForMe(message), isTrue);
      expect(state.historyFor('conv_1').forKey('dev_peer:b')!.body,
          'secret words');
      expect(state.chatPreviewFor('conv_1')?.body, 'secret words');
      expect(state.starredMessages, <String>{'dev_peer:b'});
    });

    test('when the window closes the delete is final', () async {
      final store = MemoryLocalStore();
      await withExtras(store);
      final state = appState(store)
        ..deleteForMeUndoWindow = const Duration(milliseconds: 50);
      addTearDown(state.dispose);
      await state.refreshHistory('conv_1');
      final message = state.historyFor('conv_1').forKey('dev_peer:b')!;
      await state.deleteMessageForMe(message);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // The window has closed: Undo has nothing left to bring back.
      expect(await store.unhideMessage('dev_peer:b'), isFalse);
      expect(await state.undoDeleteForMe(message), isFalse);
      expect(state.historyFor('conv_1').forKey('dev_peer:b')!.body, isNull);
      expect(state.chatPreviewFor('conv_1')?.body, 'older words');
    });

    test('the snackbar closing early makes the delete final', () async {
      final store = MemoryLocalStore();
      await withExtras(store);
      final state = appState(store);
      addTearDown(state.dispose);
      await state.refreshHistory('conv_1');
      final message = state.historyFor('conv_1').forKey('dev_peer:b')!;
      await state.deleteMessageForMe(message);
      await state.finishDeleteForMe(message.key);
      expect(await state.undoDeleteForMe(message), isFalse);
      expect(await store.unhideMessage('dev_peer:b'), isFalse);
    });

    test('killed during the window: the next start deletes it for good',
        () async {
      var store = createStore();
      await withExtras(store);
      final first = appState(store)
        // The window never closes in this run: the app is killed first.
        ..deleteForMeUndoWindow = const Duration(hours: 1);
      await first.refreshHistory('conv_1');
      final message = first.historyFor('conv_1').forKey('dev_peer:b')!;
      expect(await first.deleteMessageForMe(message), isTrue);
      // Killed: no dispose, no timer, nothing finishes. Only the files stay.
      await closeAll();

      store = createStore();
      Future<int> count(String sql) async =>
          (await databases.last.customSelect(sql).getSingle()).read<int>('n');
      // Hidden from the first instant, also before the next start finishes.
      expect((await row(store, 'b')).body, isNull);
      expect(await found(store, 'secret'), isEmpty);
      expect(await preview(store), 'older words');
      expect(await count('SELECT COUNT(*) AS n FROM local_hide_undo'), 1);

      final second = appState(store);
      addTearDown(second.dispose);
      await second.tryRestoreSession();
      expect(await count('SELECT COUNT(*) AS n FROM local_hide_undo'), 0);
      expect(
          await count('SELECT COUNT(*) AS n FROM local_frank_reveals '
              "WHERE message_key = 'dev_peer:b'"),
          0);
      expect(
          await count('SELECT COUNT(*) AS n FROM local_message_search '
              "WHERE local_message_search MATCH 'secret'"),
          0);
      expect(
          await count('SELECT COUNT(*) AS n FROM local_messages '
              "WHERE body = 'secret words'"),
          0);
      expect(await store.unhideMessage('dev_peer:b'), isFalse);
      final stays = await row(store, 'b');
      expect(stays.hiddenAt, isNotNull);
      expect(stays.body, isNull);
      // The first run's timer belongs to a closed database; stop it.
      first.dispose();
    });
  });
}

class _OfflineApiClient extends ApiClient {
  _OfflineApiClient() : super(baseUrl: 'https://localhost:8080');

  @override
  Future<List<Conversation>> conversations(String token) =>
      Future<List<Conversation>>.error(const SocketException('offline'));

  @override
  Future<List<Device>> devices(String token) =>
      Future<List<Device>>.error(const SocketException('offline'));
}

class _IdleSyncService implements SyncService {
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
