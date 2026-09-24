import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_recovery.dart';

Matcher _storeFailure(LocalStoreFailureKind kind) =>
    isA<LocalStoreUnavailableException>()
        .having((error) => error.kind, 'kind', kind);

class _FlakyStorage extends FlutterSecureStorage {
  _FlakyStorage();

  bool failing = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (failing) throw StateError('keystore locked');
    return super.read(key: key);
  }
}

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

  test('the sync recovery record persists and leaves with the identity',
      () async {
    final store = createStore();
    const session = Session(
      baseUrl: 'https://chat.example.org',
      token: 'token',
      accountId: 'acct_1',
      deviceId: 'dev_1',
    );
    await store.saveSession(session);
    expect(await store.loadSyncRecovery(), isNull);
    await store.saveSyncRecovery(SyncRecovery(
      kind: SyncFailureKind.mlsControlMissing,
      recordedAt: DateTime.utc(2026, 9, 24),
      eventId: 12,
    ));
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
    final reopened = createStore();
    final loaded = await reopened.loadSyncRecovery();
    expect(loaded?.kind, SyncFailureKind.mlsControlMissing);
    expect(loaded?.eventId, 12);

    // Signing out keeps it: the MLS state it protects is still there.
    await reopened.clearCachedState(preserveOutbox: true);
    expect(await reopened.loadSyncRecovery(), isNotNull);
    await reopened.saveSyncRecovery(null);
    expect(await reopened.loadSyncRecovery(), isNull);

    await reopened.saveSyncRecovery(SyncRecovery(
      kind: SyncFailureKind.mlsState,
      recordedAt: DateTime.utc(2026, 9, 24),
    ));
    await reopened.saveSession(const Session(
      baseUrl: 'https://chat.example.org',
      token: 'token',
      accountId: 'acct_2',
      deviceId: 'dev_2',
    ));
    expect(await reopened.loadSyncRecovery(), isNull);
  });

  test('a namespaced store keeps its own database and key', () async {
    final release = createStore();
    await release.saveSyncCursor(5);
    final demo = SecureLocalStore(
      storage: secureStorage,
      directoryProvider: () async => directory,
      namespace: 'demo',
      databaseFactory: (file, keyHex) {
        final database = openEncryptedLocalDatabase(file, keyHex);
        databases.add(database);
        return database;
      },
    );
    expect(await demo.loadSyncCursor(), 0);
    await demo.saveSyncCursor(9);
    expect(await release.loadSyncCursor(), 5);
    expect(
      File('${directory.path}/profiles/demo/veritra-local.db').existsSync(),
      isTrue,
    );
    final keys = await secureStorage.readAll();
    expect(
        keys.keys,
        containsAll(<String>[
          'veritra.database_key.v1',
          'veritra.demo.database_key.v1'
        ]));
    expect(keys['veritra.database_key.v1'],
        isNot(keys['veritra.demo.database_key.v1']));
  });

  test('a database whose key is gone fails closed instead of starting over',
      () async {
    final first = createStore();
    await first.saveSyncCursor(4);
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
    await secureStorage.delete(key: 'veritra.database_key.v1');

    final second = createStore();
    await expectLater(second.loadSyncCursor(),
        throwsA(_storeFailure(LocalStoreFailureKind.keyMissing)));
    expect(await secureStorage.read(key: 'veritra.database_key.v1'), isNull);
  });

  Future<List<int>> seedAndClose() async {
    final seed = createStore();
    await seed.saveSyncCursor(4);
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
    return File('${directory.path}/veritra-local.db').readAsBytes();
  }

  Future<void> expectDatabaseUnchanged(List<int> original) async {
    final file = File('${directory.path}/veritra-local.db');
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), original);
  }

  test('a wrong key is rejected and the database is left untouched', () async {
    final original = await seedAndClose();
    await secureStorage.write(key: 'veritra.database_key.v1', value: 'ab' * 32);
    final store = createStore();
    await expectLater(store.loadSyncCursor(),
        throwsA(_storeFailure(LocalStoreFailureKind.keyRejected)));
    await expectDatabaseUnchanged(original);
    expect(await secureStorage.read(key: 'veritra.database_key.v1'), 'ab' * 32);
  });

  test('a malformed key is reported without touching the database', () async {
    final original = await seedAndClose();
    await secureStorage.write(
        key: 'veritra.database_key.v1', value: 'not-a-key');
    final store = createStore();
    await expectLater(store.loadSyncCursor(),
        throwsA(_storeFailure(LocalStoreFailureKind.keyMalformed)));
    await expectDatabaseUnchanged(original);
  });

  test('unreadable secure storage is retryable and a retry reopens', () async {
    await seedAndClose();
    final flaky = _FlakyStorage();
    final store = SecureLocalStore(
      storage: flaky,
      directoryProvider: () async => directory,
      databaseFactory: (file, keyHex) {
        final database = openEncryptedLocalDatabase(file, keyHex);
        databases.add(database);
        return database;
      },
    );
    flaky.failing = true;
    await expectLater(store.loadSyncCursor(),
        throwsA(_storeFailure(LocalStoreFailureKind.keyUnavailable)));
    flaky.failing = false;
    expect(await store.loadSyncCursor(), 4);
  });

  test('a reset needs confirmation and moves the database aside with its key',
      () async {
    final original = await seedAndClose();
    final key = await secureStorage.read(key: 'veritra.database_key.v1');
    await secureStorage.delete(key: 'veritra.database_key.v1');
    final store = createStore();
    await expectLater(store.loadSyncCursor(),
        throwsA(_storeFailure(LocalStoreFailureKind.keyMissing)));

    await expectLater(store.quarantineUnreadableDatabase(confirmed: false),
        throwsArgumentError);
    await expectDatabaseUnchanged(original);

    // The key comes back just before the reset: it is kept with the copy.
    await secureStorage.write(key: 'veritra.database_key.v1', value: key!);
    await store.quarantineUnreadableDatabase(confirmed: true);
    expect(File('${directory.path}/veritra-local.db').existsSync(), isFalse);
    final quarantined = directory
        .listSync()
        .whereType<Directory>()
        .where((item) => item.path.contains('unreadable-'))
        .single;
    final stamp = quarantined.path.split('unreadable-').last;
    expect(File('${quarantined.path}/veritra-local.db').readAsBytesSync(),
        original);
    expect(
        await secureStorage.read(
            key: 'veritra.database_key.v1.quarantined.$stamp'),
        key);
    expect(await secureStorage.read(key: 'veritra.database_key.v1'), isNull);

    // The store now starts empty with a new key.
    expect(await store.loadSyncCursor(), 0);
    final newKey = await secureStorage.read(key: 'veritra.database_key.v1');
    expect(newKey, isNot(key));

    // The moved copy is still readable with its kept key.
    final copy = openEncryptedLocalDatabase(
        File('${quarantined.path}/veritra-local.db'), key);
    databases.add(copy);
    expect(await copy.readCursor(), 4);
  });

  test('an interrupted reset is finished on the next open', () async {
    final original = await seedAndClose();
    final key = await secureStorage.read(key: 'veritra.database_key.v1');
    // A crash after the intent was written and the WAL companion moved.
    const stamp = '1700000000000000';
    File('${directory.path}/veritra-local.reset-intent')
        .writeAsStringSync(stamp);
    final quarantine = Directory('${directory.path}/unreadable-$stamp')
      ..createSync();
    final wal = File('${directory.path}/veritra-local.db-wal');
    if (wal.existsSync())
      wal.renameSync('${quarantine.path}/veritra-local.db-wal');

    final store = createStore();
    expect(await store.loadSyncCursor(), 0);
    expect(File('${directory.path}/veritra-local.reset-intent').existsSync(),
        isFalse);
    expect(File('${quarantine.path}/veritra-local.db').readAsBytesSync(),
        original);
    expect(
        await secureStorage.read(
            key: 'veritra.database_key.v1.quarantined.$stamp'),
        key);
  });

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

  Future<void> queueMls(SecureLocalStore store, List<String> keys) async {
    final counter = (await store.loadCryptoState())?.counter ?? 0;
    await store.commitOutgoingMlsTransition(OutgoingMlsStateTransition(
      expectedCounter: counter,
      expectedCursor: await store.loadSyncCursor(),
      state: StoredCryptoState(
        counter: counter + 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[counter + 1],
      ),
      messages: <PendingMlsMessage>[
        for (final key in keys)
          PendingMlsMessage(
            idempotencyKey: key,
            conversationId: 'conv_1',
            kind: 'commit',
            payload: const <int>[1],
          ),
      ],
    ));
  }

  test('MLS outbox keeps transition order and durable failures', () async {
    final store = createStore();
    await store.saveCryptoState(
      StoredCryptoState(
        counter: 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[1],
      ),
      0,
    );
    // Keys sort opposite to their queue order on purpose.
    await queueMls(store, <String>['zz_first', 'mm_second', 'aa_third']);
    await queueMls(store, <String>['00_fourth']);
    expect(
      (await store.pendingMlsMessages()).map((item) => item.idempotencyKey),
      <String>['zz_first', 'mm_second', 'aa_third', '00_fourth'],
    );

    final due = DateTime.utc(2030, 1, 1, 12);
    await store.recordMlsOutboxFailure('zz_first',
        failureClass: 'retryable:503', terminal: false, nextAttemptAt: due);
    await store.recordMlsOutboxFailure('mm_second',
        failureClass: 'terminal:403:forbidden', terminal: true);
    await databases.last.close();
    databases.removeLast();

    final restarted = createStore();
    final items = await restarted.pendingMlsMessages();
    expect(items[0].attemptCount, 1);
    expect(items[0].terminal, isFalse);
    expect(items[0].nextAttemptAt, due);
    expect(items[0].failureClass, 'retryable:503');
    expect(items[1].terminal, isTrue);
    expect(items[1].nextAttemptAt, isNull);
    expect(items[2].attemptCount, 0);
  });

  test('an applied MLS control message is found by its server ID', () async {
    final store = createStore();
    await store.saveCryptoState(
      StoredCryptoState(
        counter: 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[1],
      ),
      0,
    );
    await store.commitMlsTransition(MlsStateTransition(
      messageId: 'mls:4:mls_commit_1',
      conversationId: 'conv_1',
      expectedCounter: 1,
      expectedCursor: 0,
      state: StoredCryptoState(
        counter: 2,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[2],
      ),
      cursor: 4,
    ));
    expect(await store.hasAppliedMlsControlMessage('mls_commit_1'), isTrue);
    expect(await store.hasAppliedMlsControlMessage('commit_1'), isFalse);
    expect(await store.hasAppliedMlsControlMessage('mls_commit_2'), isFalse);
  });

  test('a version 7 database gains MLS delivery state on upgrade', () async {
    final store = createStore();
    await store.saveCryptoState(
      StoredCryptoState(
        counter: 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[1],
      ),
      0,
    );
    await queueMls(store, <String>['old_item']);
    final database = databases.last;
    for (final column in <String>[
      'attempt_count',
      'next_attempt_at',
      'failure_class',
      'terminal',
    ]) {
      await database.customStatement(
          'ALTER TABLE local_mls_outbox_entries DROP COLUMN $column');
    }
    await database.customStatement('PRAGMA user_version = 7');
    await database.close();
    databases.removeLast();

    final upgraded = createStore();
    final item = (await upgraded.pendingMlsMessages()).single;
    expect(item.idempotencyKey, 'old_item');
    expect(item.attemptCount, 0);
    expect(item.terminal, isFalse);
    await upgraded.recordMlsOutboxFailure('old_item',
        failureClass: 'retryable:network', terminal: false);
    expect((await upgraded.pendingMlsMessages()).single.attemptCount, 1);
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
