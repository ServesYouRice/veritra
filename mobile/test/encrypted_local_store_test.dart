import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late FlutterSecureStorage secureStorage;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-local-store-');
    secureStorage = const FlutterSecureStorage();
    databases = <EncryptedLocalDatabase>[];
  });

  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  SecureLocalStore createStore({MlsCommitFailureInjector? failureInjector}) =>
      SecureLocalStore(
        storage: secureStorage,
        directoryProvider: () async => directory,
        mlsCommitFailureInjector: failureInjector,
        databaseFactory: (file, keyHex) {
          final database = openEncryptedLocalDatabase(file, keyHex);
          databases.add(database);
          return database;
        },
      );

  test('migrates and verifies the legacy secure-storage record once', () async {
    final legacy = <String, Object?>{
      'version': 3,
      'cursor': 17,
      'session': <String, Object?>{
        'base_url': 'https://example.test',
        'token': 'session-token',
        'account_id': 'acct_1',
        'device_id': 'dev_1',
      },
      'snapshot': <String, Object?>{
        'conversations': <Object?>[
          Conversation(id: 'conv_1', kind: 'dm').toJson(),
        ],
        'messages': <String, Object?>{
          'conv_1': <Object?>[_receivedEnvelope().toJson()],
        },
      },
      'outbox': <Object?>[_outboxEnvelope('queued_1').toJson()],
      'crypto_state': <String, Object?>{
        'counter': 4,
        'state_key': base64Encode(List<int>.filled(32, 7)),
        'sealed_state': base64Encode(<int>[8, 9]),
      },
    };
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'veritra.account_state.v2': jsonEncode(legacy),
    });

    final store = createStore();
    expect((await store.loadSession())?.deviceId, 'dev_1');
    expect(await store.loadSyncCursor(), 17);
    expect((await store.loadSnapshot())?.messagesByConversation['conv_1'],
        hasLength(1));
    expect(await store.pendingEnvelopes(), hasLength(1));
    expect((await store.loadCryptoState())?.counter, 4);
    expect(await secureStorage.read(key: 'veritra.account_state.v2'), isNull);
    expect(
      await secureStorage.read(key: 'veritra.database_key.v1'),
      matches(RegExp(r'^[0-9a-f]{64}$')),
    );
  });

  test('encrypted state survives a database restart', () async {
    final first = createStore();
    await first.saveSession(const Session(
      baseUrl: 'https://example.test',
      token: 'token',
      accountId: 'acct_1',
      deviceId: 'dev_1',
    ));
    await first.saveSnapshot(
      <Conversation>[Conversation(id: 'conv_1', kind: 'group')],
      <String, List<ReceivedMessageEnvelope>>{
        'conv_1': <ReceivedMessageEnvelope>[_receivedEnvelope()],
      },
      12,
    );
    await databases.last.close();
    databases.removeLast();

    final restarted = createStore();
    expect((await restarted.loadSession())?.accountId, 'acct_1');
    expect((await restarted.loadSnapshot())?.cursor, 12);
  });

  test('wrong database key fails closed', () async {
    final first = createStore();
    await first.saveSyncCursor(3);
    await databases.last.close();
    databases.removeLast();
    await secureStorage.write(
      key: 'veritra.database_key.v1',
      value: List<String>.filled(32, 'ff').join(),
    );

    expect(createStore().loadSyncCursor(), throwsA(isA<Object>()));
  });

  test('corrupt legacy state fails closed', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'veritra.account_state.v2': '{not-json',
    });
    expect(createStore().loadSession(), throwsStateError);
  });

  test('concurrent stores do not lose outbox writes', () async {
    final first = createStore();
    final second = createStore();
    await Future.wait(<Future<void>>[
      for (var index = 0; index < 50; index++)
        first.enqueueEnvelope(_outboxEnvelope('first_$index')),
      for (var index = 0; index < 50; index++)
        second.enqueueEnvelope(_outboxEnvelope('second_$index')),
    ]);

    final pending = await first.pendingEnvelopes();
    expect(pending, hasLength(100));
    expect(pending.map((item) => item.idempotencyKey).toSet(), hasLength(100));
  });

  test('outbox capacity refuses the 101st item without eviction', () async {
    final store = createStore();
    for (var index = 0; index < maxPendingEnvelopes; index++) {
      await store.enqueueEnvelope(_outboxEnvelope('queued_$index'));
    }

    await expectLater(
      store.enqueueEnvelope(_outboxEnvelope('queued_101')),
      throwsA(isA<OutboxFullException>()),
    );
    final pending = await store.pendingEnvelopes();
    expect(pending, hasLength(maxPendingEnvelopes));
    expect(
      pending.map((item) => item.idempotencyKey),
      contains('queued_0'),
    );
  });

  test('queued draft survives a database restart', () async {
    final first = createStore();
    await first.enqueueEnvelope(
      _outboxEnvelope('draft_1'),
      draftText: 'local recovery draft',
    );
    await databases.last.close();
    databases.removeLast();

    final restarted = createStore();
    final record = (await restarted.pendingEnvelopeRecords()).single;
    expect(record.draftText, 'local recovery draft');
  });

  test('crypto state and cursor roll back together', () async {
    final store = createStore();
    await store.saveCryptoState(
      StoredCryptoState(
        counter: 2,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[2],
      ),
      8,
    );

    await expectLater(
      store.saveCryptoState(
        StoredCryptoState(
          counter: 1,
          stateKey: List<int>.filled(32, 3),
          sealedState: <int>[4],
        ),
        99,
      ),
      throwsStateError,
    );
    expect(await store.loadSyncCursor(), 8);
    expect((await store.loadCryptoState())?.counter, 2);
  });

  test('MLS transition rolls back at every injected boundary', () async {
    final seed = createStore();
    await seed.saveSnapshot(
      <Conversation>[Conversation(id: 'conv_1', kind: 'group')],
      <String, List<ReceivedMessageEnvelope>>{
        'conv_1': <ReceivedMessageEnvelope>[_receivedEnvelope()],
      },
      1,
    );
    await seed.saveCryptoState(
      StoredCryptoState(
        counter: 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[1],
      ),
      1,
    );
    await databases.last.close();
    databases.removeLast();

    for (final stage in MlsCommitStage.values) {
      final failing = createStore(
        failureInjector: (current) async {
          if (current == stage) throw StateError('injected failure');
        },
      );
      await expectLater(
        failing.commitMlsTransition(_nextTransition()),
        throwsStateError,
      );
      await databases.last.close();
      databases.removeLast();

      final restarted = createStore();
      expect(await restarted.loadSyncCursor(), 1, reason: stage.name);
      expect((await restarted.loadCryptoState())?.counter, 1,
          reason: stage.name);
      expect(
        (await restarted.loadSnapshot())
            ?.messagesByConversation['conv_1']
            ?.map((item) => item.id),
        isNot(contains('msg_2')),
        reason: stage.name,
      );
      await databases.last.close();
      databases.removeLast();
    }

    final successful = createStore();
    await successful.commitMlsTransition(_nextTransition());
    expect(await successful.loadSyncCursor(), 2);
    expect((await successful.loadCryptoState())?.counter, 2);
    expect(
      (await successful.loadSnapshot())
          ?.messagesByConversation['conv_1']
          ?.map((item) => item.id),
      contains('msg_2'),
    );
  });

  test('sync event persists its ciphertext before the cursor and fences leases',
      () async {
    final first = createStore();
    await first.saveSnapshot(
      <Conversation>[Conversation(id: 'conv_1', kind: 'group')],
      const <String, List<ReceivedMessageEnvelope>>{},
      0,
    );
    final lease1 = const LocalSyncLease(
      origin: 'https://example.test',
      accountId: 'acct_1',
      deviceId: 'dev_1',
      generation: 1,
    );
    final lease2 = const LocalSyncLease(
      origin: 'https://example.test',
      accountId: 'acct_1',
      deviceId: 'dev_1',
      generation: 2,
    );
    await first.acquireSyncLease(lease1);
    final second = createStore();
    await second.acquireSyncLease(lease2);
    await expectLater(
      first.commitSyncEvent(SyncEventCommit(
        eventKey: 'sync:1',
        conversationId: 'conv_1',
        expectedCursor: 0,
        cursor: 1,
        envelope: _receivedEnvelope(),
      )),
      throwsStateError,
    );
    await second.commitSyncEvent(SyncEventCommit(
      eventKey: 'sync:1',
      conversationId: 'conv_1',
      expectedCursor: 0,
      cursor: 1,
      envelope: _receivedEnvelope(),
    ));
    expect(await second.loadSyncCursor(), 1);
    expect((await second.loadSnapshot())?.messagesByConversation['conv_1'],
        hasLength(1));
  });
}

MessageEnvelope _outboxEnvelope(String key) => MessageEnvelope(
      conversationId: 'conv_1',
      idempotencyKey: key,
      ciphertext: <int>[1, 2, 3],
      cryptoProtocol: 'mls10-openmls-v1',
    );

ReceivedMessageEnvelope _receivedEnvelope() => ReceivedMessageEnvelope(
      id: 'msg_1',
      conversationId: 'conv_1',
      senderAccountId: 'acct_1',
      senderDeviceId: 'dev_1',
      idempotencyKey: 'received_1',
      ciphertext: <int>[4, 5, 6],
      cryptoProtocol: 'mls10-openmls-v1',
      createdAt: DateTime.utc(2026, 7, 29),
    );

MlsStateTransition _nextTransition() => MlsStateTransition(
      messageId: 'mls_message_2',
      conversationId: 'conv_1',
      expectedCounter: 1,
      expectedCursor: 1,
      state: StoredCryptoState(
        counter: 2,
        stateKey: List<int>.filled(32, 2),
        sealedState: <int>[2],
      ),
      cursor: 2,
      upsertedEnvelopes: <ReceivedMessageEnvelope>[
        ReceivedMessageEnvelope(
          id: 'msg_2',
          conversationId: 'conv_1',
          senderAccountId: 'acct_2',
          senderDeviceId: 'dev_2',
          idempotencyKey: 'received_2',
          ciphertext: <int>[7, 8, 9],
          cryptoProtocol: 'mls10-openmls-v1',
          createdAt: DateTime.utc(2026, 7, 29, 0, 1),
        ),
      ],
    );
