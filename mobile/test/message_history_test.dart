import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/message_history.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// Decrypted history rules (D22, D23), checked against both stores so the
/// in-memory twin cannot drift from the database.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-history-');
    databases = <EncryptedLocalDatabase>[];
  });

  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  final stores = <String, LocalStore Function()>{
    'memory': MemoryLocalStore.new,
    'encrypted database': () => SecureLocalStore(
          storage: const FlutterSecureStorage(),
          directoryProvider: () async => directory,
          databaseFactory: (file, keyHex) {
            final database = openEncryptedLocalDatabase(file, keyHex);
            databases.add(database);
            return database;
          },
        ),
  };

  for (final entry in stores.entries) {
    group(entry.key, () {
      test('applies text, reply, edit, reaction and delete', () async {
        final store = entry.value();
        await _begin(store);
        await _commit(store, <MessageEffect>[
          _insert('dev_a:1', 'acct_a', 'dev_a', 'hello', at: 1),
        ]);
        await _commit(store, <MessageEffect>[
          _insert('dev_b:1', 'acct_b', 'dev_b', 'hi back',
              at: 2, replyTo: 'dev_a:1'),
          const ReactionEffect(
              targetKey: 'dev_a:1',
              reactorAccountId: 'acct_b',
              reaction: '👍',
              at: 2),
        ]);
        await _commit(store, <MessageEffect>[
          _action('dev_a:2', 'acct_a', 'dev_a', at: 3),
          const EditMessageEffect(
              targetKey: 'dev_a:1',
              editorAccountId: 'acct_a',
              body: 'hello!',
              at: 3),
        ]);

        var messages = await store.loadMessages('conv_1');
        expect(messages.map((item) => item.key),
            <String>['dev_a:1', 'dev_b:1', 'dev_a:2']);
        expect(messages.first.body, 'hello!');
        expect(messages.first.editedAt, 3);
        expect(messages[1].replyTo, 'dev_a:1');
        expect(await store.loadReactions('conv_1'), hasLength(1));

        await _commit(store, <MessageEffect>[
          const DeleteMessageEffect(
              targetKey: 'dev_a:1', deleterAccountId: 'acct_a', at: 4),
        ]);
        messages = await store.loadMessages('conv_1');
        expect(messages.first.body, isNull);
        expect(messages.first.deletedAt, 4);
        expect(await store.loadReactions('conv_1'), isEmpty);
      });

      test('ignores edits and deletes from anyone but the sender', () async {
        final store = entry.value();
        await _begin(store);
        await _commit(store, <MessageEffect>[
          _insert('dev_a:1', 'acct_a', 'dev_a', 'original', at: 1),
        ]);
        await _commit(store, <MessageEffect>[
          const EditMessageEffect(
              targetKey: 'dev_a:1',
              editorAccountId: 'acct_b',
              body: 'forged',
              at: 2),
          const DeleteMessageEffect(
              targetKey: 'dev_a:1', deleterAccountId: 'acct_b', at: 2),
        ]);
        final message = (await store.loadMessages('conv_1')).single;
        expect(message.body, 'original');
        expect(message.editedAt, isNull);
        expect(message.deletedAt, isNull);
      });

      test('a replayed insert never overwrites history', () async {
        final store = entry.value();
        await _begin(store);
        await _commit(store, <MessageEffect>[
          _insert('dev_a:1', 'acct_a', 'dev_a', 'first', at: 1),
        ]);
        await _commit(store, <MessageEffect>[
          _insert('dev_a:1', 'acct_a', 'dev_a', 'second', at: 2),
        ]);
        expect((await store.loadMessages('conv_1')).single.body, 'first');
      });

      test('own messages are linked to their server echo', () async {
        final store = entry.value();
        await _begin(store);
        await _commit(store, <MessageEffect>[
          _insert('dev_a:1', 'acct_a', 'dev_a', 'mine',
              at: 1, state: LocalMessageState.pending, serverId: null),
        ]);
        final cursor = await store.loadSyncCursor();
        await store.commitSyncEvent(SyncEventCommit(
          eventKey: 'echo',
          conversationId: 'conv_1',
          expectedCursor: cursor,
          cursor: cursor + 1,
          envelope: _envelope('srv_9', 'dev_a', '1'),
          ownMessageKey: 'dev_a:1',
        ));
        final message = (await store.loadMessages('conv_1')).single;
        expect(message.serverMessageId, 'srv_9');
        expect(message.state, LocalMessageState.sent);
      });

      test('history survives a cache refresh but not a full clear', () async {
        final store = entry.value();
        await _begin(store);
        await _commit(store, <MessageEffect>[
          _insert('dev_a:1', 'acct_a', 'dev_a', 'kept', at: 1),
        ]);
        await store.clearCachedState();
        expect(await store.loadMessages('conv_1'), hasLength(1));
        await store.clear();
        expect(await store.loadMessages('conv_1'), isEmpty);
      });
    });
  }

  test('ConversationHistory matches envelopes and hides actions', () {
    final history = ConversationHistory(
      conversationId: 'conv_1',
      messages: <LocalMessage>[
        const LocalMessage(
          key: 'dev_a:1',
          conversationId: 'conv_1',
          senderAccountId: 'acct_a',
          senderDeviceId: 'dev_a',
          kind: LocalMessageKind.text,
          body: 'hello',
          createdAt: 1,
          state: LocalMessageState.received,
        ),
        const LocalMessage(
          key: 'dev_b:2',
          conversationId: 'conv_1',
          senderAccountId: 'acct_b',
          senderDeviceId: 'dev_b',
          kind: LocalMessageKind.action,
          createdAt: 2,
          state: LocalMessageState.received,
        ),
      ],
      reactions: const <LocalMessageReaction>[
        LocalMessageReaction(
            targetKey: 'dev_a:1',
            reactorAccountId: 'acct_b',
            reaction: '👍',
            updatedAt: 1),
        LocalMessageReaction(
            targetKey: 'dev_a:1',
            reactorAccountId: 'acct_c',
            reaction: '👍',
            updatedAt: 2),
      ],
    );
    expect(
        history.forEnvelope(_envelope('srv_1', 'dev_a', '1'))?.body, 'hello');
    expect(history.hides(_envelope('srv_2', 'dev_b', '2')), isTrue);
    expect(history.hides(_envelope('srv_1', 'dev_a', '1')), isFalse);
    // A different sender device cannot borrow another device's text.
    expect(history.forEnvelope(_envelope('srv_3', 'dev_b', '1')), isNull);
    final reactions = history.reactionsFor('dev_a:1', ownAccountId: 'acct_c');
    expect(reactions.single.count, 2);
    expect(reactions.single.mine, isTrue);
  });
}

final List<int> _stateKey = List<int>.filled(32, 7);

Future<void> _begin(LocalStore store) => store.saveCryptoState(
    StoredCryptoState(counter: 1, stateKey: _stateKey, sealedState: <int>[1]),
    0);

Future<void> _commit(LocalStore store, List<MessageEffect> effects) async {
  final current = (await store.loadCryptoState())!;
  final cursor = await store.loadSyncCursor();
  await store.commitMlsTransition(MlsStateTransition(
    messageId: 'event:${cursor + 1}',
    conversationId: 'conv_1',
    expectedCounter: current.counter,
    expectedCursor: cursor,
    state: StoredCryptoState(
        counter: current.counter + 1,
        stateKey: _stateKey,
        sealedState: <int>[current.counter + 1]),
    cursor: cursor + 1,
    messageEffects: effects,
  ));
}

InsertMessageEffect _insert(
  String key,
  String account,
  String device,
  String body, {
  required int at,
  String? replyTo,
  String state = LocalMessageState.received,
  String? serverId = '',
}) =>
    InsertMessageEffect(
      key: key,
      serverMessageId: serverId == '' ? 'srv_$key' : serverId,
      conversationId: 'conv_1',
      senderAccountId: account,
      senderDeviceId: device,
      kind: LocalMessageKind.text,
      body: body,
      replyTo: replyTo,
      createdAt: at,
      state: state,
    );

InsertMessageEffect _action(String key, String account, String device,
        {required int at}) =>
    InsertMessageEffect(
      key: key,
      serverMessageId: 'srv_$key',
      conversationId: 'conv_1',
      senderAccountId: account,
      senderDeviceId: device,
      kind: LocalMessageKind.action,
      createdAt: at,
      state: LocalMessageState.received,
    );

ReceivedMessageEnvelope _envelope(String id, String device, String action) =>
    ReceivedMessageEnvelope(
      id: id,
      conversationId: 'conv_1',
      senderAccountId: 'acct_x',
      senderDeviceId: device,
      idempotencyKey: action,
      ciphertext: const <int>[1, 2, 3],
      cryptoProtocol: 'mls10-openmls-v1',
      createdAt: DateTime.utc(2026),
    );
