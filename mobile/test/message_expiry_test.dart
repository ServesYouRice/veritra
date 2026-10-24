import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// W2: an expired message leaves this device's database, chat and chat list,
/// also when the app was closed past the expiry and starts offline.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-expiry-');
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

  Future<void> closeAll() async {
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
  }

  Future<void> seedState(LocalStore store) => store.saveCryptoState(
        StoredCryptoState(
          counter: 1,
          stateKey: List<int>.filled(32, 1),
          sealedState: <int>[1],
        ),
        0,
      );

  /// Commits one received application message like the native service does.
  Future<void> receive(
    LocalStore store, {
    required String id,
    DateTime? expiresAt,
    String body = 'secret words',
    bool withEffect = true,
  }) async {
    final counter = (await store.loadCryptoState())!.counter;
    final cursor = await store.loadSyncCursor();
    final envelope = _envelope(id, expiresAt: expiresAt);
    await store.commitMlsTransition(MlsStateTransition(
      messageId: 'application:${cursor + 1}:$id',
      conversationId: 'conv_1',
      expectedCounter: counter,
      expectedCursor: cursor,
      state: StoredCryptoState(
        counter: counter + 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[counter + 1],
      ),
      cursor: cursor + 1,
      upsertedEnvelopes: <ReceivedMessageEnvelope>[envelope],
      messageEffects: <MessageEffect>[
        if (withEffect)
          InsertMessageEffect(
            key: 'dev_peer:$id',
            serverMessageId: id,
            conversationId: 'conv_1',
            senderAccountId: 'acct_peer',
            senderDeviceId: 'dev_peer',
            kind: LocalMessageKind.text,
            body: body,
            createdAt: DateTime.utc(2026, 10, 24).millisecondsSinceEpoch,
            state: LocalMessageState.received,
            expiresAt: expiresAt?.toUtc().millisecondsSinceEpoch,
          ),
      ],
    ));
  }

  Future<List<String>> bodies(LocalStore store) async => [
        for (final item in await store.loadMessages('conv_1'))
          if (item.body != null) item.body!,
      ];

  Future<List<String>> envelopeIds(LocalStore store) async {
    final snapshot = await store.loadSnapshot();
    return [
      for (final item in snapshot?.messagesByConversation['conv_1'] ??
          const <ReceivedMessageEnvelope>[])
        item.id,
    ];
  }

  Future<void> saveList(LocalStore store) => store.saveProjection(
        <Conversation>[Conversation(id: 'conv_1', kind: 'group')],
        const <String, List<ReceivedMessageEnvelope>>{},
      );

  test('purge deletes expired text, reactions and envelopes, and only those',
      () async {
    final store = createStore();
    await seedState(store);
    await saveList(store);
    final soon = DateTime.now().toUtc().add(const Duration(seconds: 2));
    final later = DateTime.now().toUtc().add(const Duration(days: 1));
    await receive(store, id: 'gone', expiresAt: soon, body: 'gone text');
    await receive(store, id: 'kept', expiresAt: later, body: 'kept text');
    await receive(store, id: 'forever', body: 'forever text');
    final database = databases.last;
    await database.applyMessageEffects(<MessageEffect>[
      ReactionEffect(
        targetKey: 'dev_peer:gone',
        reactorAccountId: 'acct_1',
        reaction: '\u{1F44D}',
        at: 1,
      ),
      ReactionEffect(
        targetKey: 'dev_peer:kept',
        reactorAccountId: 'acct_1',
        reaction: '\u{1F44D}',
        at: 1,
      ),
    ]);
    expect(await bodies(store), hasLength(3));
    expect(await store.purgeExpiredMessages(), isEmpty);

    final touched = await store.purgeExpiredMessages(
        now: soon.add(const Duration(seconds: 1)));
    expect(touched, <String>{'conv_1'});
    expect(await bodies(store), unorderedEquals(['kept text', 'forever text']));
    expect(await envelopeIds(store), unorderedEquals(['kept', 'forever']));
    expect((await store.loadReactions('conv_1')).map((r) => r.targetKey),
        <String>['dev_peer:kept']);
    final next = await store.nextMessageExpiry();
    expect(next?.millisecondsSinceEpoch, later.millisecondsSinceEpoch);

    // Nothing of the expired text is left in the database file's rows.
    final raw = await database
        .customSelect("SELECT count(*) AS n FROM local_messages "
            "WHERE body = 'gone text' OR key = 'dev_peer:gone'")
        .getSingle();
    expect(raw.read<int>('n'), 0);
  });

  test('a message that arrives already expired is consumed but not stored',
      () async {
    final store = createStore();
    await seedState(store);
    await saveList(store);
    final past = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await receive(store, id: 'late', expiresAt: past);
    // The MLS state and cursor still advanced: the message was consumed.
    expect((await store.loadCryptoState())!.counter, 2);
    expect(await store.loadSyncCursor(), 1);
    expect(await bodies(store), isEmpty);
    expect(await envelopeIds(store), isEmpty);
    expect(await store.nextMessageExpiry(), isNull);
  });

  test('a sender learns its own message expiry from the echo', () async {
    final store = createStore();
    await seedState(store);
    await saveList(store);
    final soon = DateTime.now().toUtc().add(const Duration(seconds: 2));
    // The local copy is written when the message is encrypted, before the
    // server has stamped any expiry.
    await databases.last.applyMessageEffects(<MessageEffect>[
      InsertMessageEffect(
        key: 'dev_own:mine',
        conversationId: 'conv_1',
        senderAccountId: 'acct_own',
        senderDeviceId: 'dev_own',
        kind: LocalMessageKind.text,
        body: 'my words',
        createdAt: 1,
        state: LocalMessageState.pending,
      ),
    ]);
    await store.commitSyncEvent(SyncEventCommit(
      eventKey: 'sync:1',
      conversationId: 'conv_1',
      expectedCursor: 0,
      cursor: 1,
      envelope: ReceivedMessageEnvelope(
        id: 'srv_mine',
        conversationId: 'conv_1',
        senderAccountId: 'acct_own',
        senderDeviceId: 'dev_own',
        idempotencyKey: 'mine',
        ciphertext: const <int>[1],
        cryptoProtocol: 'mls10-openmls-v1',
        createdAt: DateTime.utc(2026, 10, 24),
        expiresAt: soon,
      ),
      ownMessageKey: 'dev_own:mine',
    ));
    expect(await bodies(store), <String>['my words']);
    await store.purgeExpiredMessages(now: soon.add(const Duration(seconds: 1)));
    expect(await bodies(store), isEmpty);
    expect(await envelopeIds(store), isEmpty);
  });

  test('offline restart: expired rows are gone after reopening the database',
      () async {
    final store = createStore();
    await seedState(store);
    await saveList(store);
    final soon = DateTime.now().toUtc().add(const Duration(seconds: 1));
    await receive(store, id: 'gone', expiresAt: soon, body: 'gone text');
    await receive(store, id: 'kept', body: 'kept text');
    await closeAll();
    await Future<void>.delayed(const Duration(milliseconds: 1300));

    // A new process: the stored rows are expired by now, nothing has purged.
    final reopened = createStore();
    expect(await bodies(reopened), contains('gone text'));
    final touched = await reopened.purgeExpiredMessages();
    expect(touched, <String>{'conv_1'});
    expect(await bodies(reopened), <String>['kept text']);
    expect(await envelopeIds(reopened), <String>['kept']);
  });

  test('the upgrade from schema 9 backfills expiry and deletes expired rows',
      () async {
    final store = createStore();
    await seedState(store);
    await saveList(store);
    await receive(store, id: 'plain', body: 'plain text');
    final database = databases.last;
    // Rebuild a schema 9 database: no expiry columns, rows as version 9 wrote
    // them (expiry only inside the envelope JSON).
    for (final trigger in <String>[
      'local_messages_search_ai',
      'local_messages_search_au',
      'local_messages_search_ad',
    ]) {
      await database.customStatement('DROP TRIGGER IF EXISTS $trigger');
    }
    await database.customStatement('DROP TABLE IF EXISTS local_message_search');
    await database
        .customStatement('DROP INDEX IF EXISTS local_messages_search_id');
    await database
        .customStatement('ALTER TABLE local_messages DROP COLUMN search_id');
    await database
        .customStatement('DROP INDEX IF EXISTS local_messages_expires_at');
    await database.customStatement(
        'DROP INDEX IF EXISTS local_ciphertext_envelopes_expires_at');
    await database
        .customStatement('ALTER TABLE local_messages DROP COLUMN expires_at');
    await database.customStatement(
        'ALTER TABLE local_ciphertext_envelopes DROP COLUMN expires_at');
    final past = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    final future = DateTime.now().toUtc().add(const Duration(hours: 1));
    var position = 10;
    for (final entry in <(String, DateTime)>[
      ('old', past),
      ('fresh', future),
    ]) {
      await database.customStatement(
        'INSERT INTO local_ciphertext_envelopes '
        '(id, conversation_id, position, payload_json) VALUES (?, ?, ?, ?)',
        <Object?>[
          entry.$1,
          'conv_1',
          position++,
          jsonEncode(_envelope(entry.$1, expiresAt: entry.$2).toJson()),
        ],
      );
      await database.customStatement(
        'INSERT INTO local_messages (key, server_message_id, conversation_id, '
        'sender_account_id, sender_device_id, kind, body, created_at, state) '
        "VALUES (?, ?, 'conv_1', 'acct_peer', 'dev_peer', 'text', ?, 1, "
        "'received')",
        <Object?>['dev_peer:${entry.$1}', entry.$1, '${entry.$1} text'],
      );
    }
    await database.customStatement('DROP TABLE local_drafts');
    await database.customStatement('DROP TABLE local_conversation_mutes');
    await database.customStatement('PRAGMA user_version = 9');
    await database.close();
    databases.removeLast();

    final upgraded = createStore();
    expect(
        await bodies(upgraded), unorderedEquals(['plain text', 'fresh text']));
    expect(await envelopeIds(upgraded), unorderedEquals(['plain', 'fresh']));
    final reopened = databases.last;
    final version =
        await reopened.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 12);
    // The surviving row got its expiry from its envelope.
    final next = await upgraded.nextMessageExpiry();
    expect(next?.millisecondsSinceEpoch, future.millisecondsSinceEpoch);
    final gone = await reopened
        .customSelect("SELECT count(*) AS n FROM local_messages "
            "WHERE body = 'old text'")
        .getSingle();
    expect(gone.read<int>('n'), 0);
  });

  test('the memory store purges the same way', () async {
    final store = MemoryLocalStore();
    await seedState(store);
    await saveList(store);
    final soon = DateTime.now().toUtc().add(const Duration(seconds: 2));
    await receive(store, id: 'gone', expiresAt: soon);
    await receive(store, id: 'kept');
    expect(await bodies(store), hasLength(2));
    final touched = await store.purgeExpiredMessages(
        now: soon.add(const Duration(seconds: 1)));
    expect(touched, <String>{'conv_1'});
    expect(await envelopeIds(store), <String>['kept']);
    expect(await bodies(store), hasLength(1));
    final late = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await receive(store, id: 'late', expiresAt: late);
    expect(await envelopeIds(store), <String>['kept']);
    expect(await bodies(store), hasLength(1));
  });

  group('app state', () {
    late MemoryLocalStore store;
    late AppState state;

    Future<void> start(List<ReceivedMessageEnvelope> cached) async {
      store = MemoryLocalStore();
      await store.saveSession(const Session(
        baseUrl: 'https://localhost:8080',
        token: 'token',
        accountId: 'acct_own',
        deviceId: 'dev_own',
      ));
      await store.saveProjection(
        <Conversation>[Conversation(id: 'conv_1', kind: 'group')],
        <String, List<ReceivedMessageEnvelope>>{'conv_1': cached},
      );
      state = AppState(
        apiClientFactory: (_) => _OfflineApiClient(),
        cryptoService: TestOnlyCryptoService(),
        localStore: store,
        syncServiceFactory: (_, __) => _IdleSyncService(),
      );
    }

    tearDown(() => state.dispose());

    test('offline start shows no expired message in the chat', () async {
      final past = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      await start(<ReceivedMessageEnvelope>[
        _envelope('old', expiresAt: past),
        _envelope('live'),
      ]);
      // The server is down, so only the local database can answer.
      await state.tryRestoreSession();
      expect(state.messagesFor('conv_1').map((e) => e.id), <String>['live']);
    });

    test('a running app drops a message when its time comes', () async {
      final soon = DateTime.now().toUtc().add(const Duration(seconds: 1));
      await start(<ReceivedMessageEnvelope>[
        _envelope('soon', expiresAt: soon),
        _envelope('live'),
      ]);
      await state.tryRestoreSession();
      expect(state.messagesFor('conv_1').map((e) => e.id),
          unorderedEquals(<String>['soon', 'live']));
      var notified = 0;
      state.addListener(() => notified++);
      for (var i = 0; i < 40 && state.messagesFor('conv_1').length != 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(state.messagesFor('conv_1').map((e) => e.id), <String>['live']);
      expect(notified, greaterThan(0));
      expect(await store.nextMessageExpiry(), isNull);
    });
  });
}

ReceivedMessageEnvelope _envelope(String id, {DateTime? expiresAt}) =>
    ReceivedMessageEnvelope(
      id: id,
      conversationId: 'conv_1',
      senderAccountId: 'acct_peer',
      senderDeviceId: 'dev_peer',
      idempotencyKey: id,
      ciphertext: const <int>[1, 2, 3],
      cryptoProtocol: 'mls10-openmls-v1',
      createdAt: DateTime.utc(2026, 10, 24),
      expiresAt: expiresAt,
    );

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
