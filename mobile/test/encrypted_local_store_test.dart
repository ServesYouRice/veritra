import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show
        CouldNotRollBackException,
        DriftWrappedException,
        OrderingTerm,
        Variable;
import 'package:drift/native.dart' show NativeDatabase, SqliteException;
import 'package:flutter/services.dart' show MethodCall;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'schema_fixtures.dart';
import 'package:private_messenger/core/models.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:private_messenger/storage/backup_exclusion.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_recovery.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

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
    await SecureLocalStore.releaseInstanceLocks();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  /// Takes a schema 12 database back to the shape of schema 9, so a test can
  /// run the real upgrade over it.
  Future<void> dropExpiryColumns(EncryptedLocalDatabase database) async {
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
    await database.customStatement('DROP TABLE local_drafts');
    await database.customStatement('DROP TABLE local_conversation_mutes');
  }

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

  test('each open keeps the profile and its database out of backups', () async {
    // What happened, in order: each exclusion with whether the database
    // file existed when the platform was asked, and each open.
    final events = <String>[];
    final excluded = <List<String>>[];
    SecureLocalStore openStore({
      String namespace = '',
      bool failing = false,
    }) =>
        SecureLocalStore(
          storage: secureStorage,
          directoryProvider: () async => directory,
          namespace: namespace,
          backupExclusion: (paths) async {
            excluded.add(paths);
            events.add(File(paths.last).existsSync()
                ? 'exclude existing'
                : 'exclude before the file');
            if (failing) throw StateError('platform refused');
          },
          databaseFactory: (file, keyHex) {
            events.add('open');
            final database = openEncryptedLocalDatabase(file, keyHex);
            databases.add(database);
            return database;
          },
        );

    await openStore().saveSyncCursor(3);
    final root = directory.path;
    final rootPaths = <String>[
      root,
      '$root/veritra-local.db-wal',
      '$root/veritra-local.db-shm',
      '$root/veritra-local.db',
    ];
    expect(excluded, <List<String>>[rootPaths, rootPaths]);
    // On first launch the directory is excluded before the new database is
    // created in it, and the files get the mark once they exist; the
    // directory covers WAL and SHM files created later.
    expect(events,
        <String>['exclude before the file', 'open', 'exclude existing']);
    expect(File('$root/veritra-local.db').existsSync(), isTrue);
    expect(File('$root/veritra-local.db-wal').existsSync(), isTrue);

    final demo = '$root/profiles/demo';
    await openStore(namespace: 'demo').saveSyncCursor(1);
    expect(excluded.last.first, demo);
    expect(excluded.last.last, '$demo/veritra-local.db');

    // Defence in depth only: a platform failure does not block the store.
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
    events.clear();
    expect(await openStore(failing: true).loadSyncCursor(), 3);
    expect(events, <String>['exclude existing', 'open', 'exclude existing']);
  });

  test('a database this build cannot open is still kept out of backups',
      () async {
    await createStore().saveSyncCursor(3);
    await databases.removeLast().close();
    // A database from an older build, say, that this key does not open.
    await secureStorage.write(key: 'veritra.database_key.v1', value: 'ab' * 32);
    final excluded = <List<String>>[];
    final store = SecureLocalStore(
      storage: secureStorage,
      directoryProvider: () async => directory,
      backupExclusion: (paths) async {
        expect(File(paths.last).existsSync(), isTrue);
        excluded.add(paths);
      },
      databaseFactory: (file, keyHex) {
        final database = openEncryptedLocalDatabase(file, keyHex);
        databases.add(database);
        return database;
      },
    );
    await expectLater(store.loadSyncCursor(),
        throwsA(_storeFailure(LocalStoreFailureKind.keyRejected)));
    expect(excluded, hasLength(1));
    expect(excluded.single.first, directory.path);
    expect(excluded.single, contains('${directory.path}/veritra-local.db'));

    // So is one whose key is gone: that open fails before any database.
    await secureStorage.delete(key: 'veritra.database_key.v1');
    await expectLater(store.loadSyncCursor(),
        throwsA(_storeFailure(LocalStoreFailureKind.keyMissing)));
    expect(excluded, hasLength(2));
  });

  test('iOS backup exclusion goes through the Runner storage channel',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformBackupExclusion.channel,
            (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformBackupExclusion.channel, null));

    await PlatformBackupExclusion.exclude(
        <String>['/a', '/a/veritra-local.db']);
    expect(PlatformBackupExclusion.channel.name,
        'org.veritra.private_messenger/storage');
    expect(calls.single.method, 'excludeFromBackup');
    expect(calls.single.arguments, <String, Object?>{
      'paths': <String>['/a', '/a/veritra-local.db'],
    });
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

  test('a snapshot rewrite is all or nothing and keeps the order', () async {
    final store = createStore();
    await store.saveSession(const Session(
      baseUrl: 'https://example.test',
      token: 'token',
      accountId: 'acct_1',
      deviceId: 'dev_1',
    ));
    ReceivedMessageEnvelope envelope(String id, String conversationId) =>
        ReceivedMessageEnvelope(
          id: id,
          conversationId: conversationId,
          senderAccountId: 'acct_1',
          senderDeviceId: 'dev_1',
          idempotencyKey: 'key_$id',
          ciphertext: <int>[1],
          cryptoProtocol: 'mls10-openmls-v1',
          createdAt: DateTime.utc(2026, 7, 29),
        );
    await store.saveProjection(
      <Conversation>[
        Conversation(id: 'conv_2', kind: 'group'),
        Conversation(id: 'conv_1', kind: 'group'),
      ],
      <String, List<ReceivedMessageEnvelope>>{
        'conv_1': <ReceivedMessageEnvelope>[
          envelope('msg_b', 'conv_1'),
          envelope('msg_a', 'conv_1'),
        ],
        'conv_2': <ReceivedMessageEnvelope>[envelope('msg_c', 'conv_2')],
      },
    );

    Future<void> expectFirstSnapshot() async {
      final snapshot = (await store.loadSnapshot())!;
      expect(snapshot.conversations.map((item) => item.id),
          <String>['conv_2', 'conv_1']);
      expect(snapshot.messagesByConversation['conv_1']!.map((item) => item.id),
          <String>['msg_b', 'msg_a']);
      expect(snapshot.messagesByConversation['conv_2']!.map((item) => item.id),
          <String>['msg_c']);
      expect(snapshot.messagesByConversation.keys,
          unorderedEquals(<String>['conv_1', 'conv_2']));
    }

    // The same envelope ID twice is refused before anything is written.
    await expectLater(
      store.saveProjection(
        <Conversation>[
          Conversation(id: 'conv_3', kind: 'group'),
          Conversation(id: 'conv_4', kind: 'group'),
        ],
        <String, List<ReceivedMessageEnvelope>>{
          'conv_3': <ReceivedMessageEnvelope>[envelope('msg_x', 'conv_3')],
          'conv_4': <ReceivedMessageEnvelope>[envelope('msg_x', 'conv_4')],
        },
      ),
      throwsStateError,
    );
    await expectFirstSnapshot();

    // A failure at the last write (the new envelope) rolls back the deletes
    // and reorders the same rewrite made before it.
    final database = databases.last;
    await database
        .customStatement('CREATE TEMP TRIGGER fail_msg_x BEFORE INSERT ON '
            "local_ciphertext_envelopes WHEN NEW.id = 'msg_x' "
            "BEGIN SELECT RAISE(ABORT, 'injected'); END");
    final next = <Conversation>[Conversation(id: 'conv_1', kind: 'group')];
    final nextMessages = <String, List<ReceivedMessageEnvelope>>{
      'conv_1': <ReceivedMessageEnvelope>[
        envelope('msg_x', 'conv_1'),
        envelope('msg_a', 'conv_1'),
        envelope('msg_b', 'conv_1'),
      ],
    };
    await expectLater(
        store.saveProjection(next, nextMessages), throwsA(anything));
    await expectFirstSnapshot();

    await database.customStatement('DROP TRIGGER fail_msg_x');
    await store.saveProjection(next, nextMessages);
    final snapshot = (await store.loadSnapshot())!;
    expect(snapshot.conversations.map((item) => item.id), <String>['conv_1']);
    expect(snapshot.messagesByConversation.keys, <String>['conv_1']);
    expect(snapshot.messagesByConversation['conv_1']!.map((item) => item.id),
        <String>['msg_x', 'msg_a', 'msg_b']);
  });

  test('a snapshot rewrite writes only the rows that changed', () async {
    final store = createStore();
    await store.saveSession(const Session(
      baseUrl: 'https://example.test',
      token: 'token',
      accountId: 'acct_1',
      deviceId: 'dev_1',
    ));
    ReceivedMessageEnvelope envelope(String id, String conversationId,
            {int ciphertext = 1}) =>
        ReceivedMessageEnvelope(
          id: id,
          conversationId: conversationId,
          senderAccountId: 'acct_1',
          senderDeviceId: 'dev_1',
          idempotencyKey: 'key_$id',
          ciphertext: <int>[ciphertext],
          cryptoProtocol: 'mls10-openmls-v1',
          createdAt: DateTime.utc(2026, 7, 29),
        );
    final database = databases.last;
    Future<int> rowChanges() async => (await database
            .customSelect('SELECT total_changes() AS changes')
            .getSingle())
        .read<int>('changes');
    Future<int> write(List<Conversation> conversations,
        Map<String, List<ReceivedMessageEnvelope>> messages,
        {int? cursor}) async {
      final before = await rowChanges();
      if (cursor == null) {
        await store.saveProjection(conversations, messages);
      } else {
        await store.saveSnapshot(conversations, messages, cursor);
      }
      return await rowChanges() - before;
    }

    Future<void> expectStored(List<Conversation> conversations,
        Map<String, List<ReceivedMessageEnvelope>> messages) async {
      final snapshot = (await store.loadSnapshot())!;
      expect(snapshot.conversations.map((item) => jsonEncode(item.toJson())),
          conversations.map((item) => jsonEncode(item.toJson())));
      expect(
          snapshot.messagesByConversation.keys, unorderedEquals(messages.keys));
      for (final entry in messages.entries) {
        expect(
            snapshot.messagesByConversation[entry.key]!
                .map((item) => jsonEncode(item.toJson())),
            entry.value.map((item) => jsonEncode(item.toJson())));
      }
    }

    var conversations = <Conversation>[
      Conversation(id: 'conv_1', kind: 'group'),
      Conversation(id: 'conv_2', kind: 'group'),
      Conversation(id: 'conv_3', kind: 'dm'),
    ];
    var messages = <String, List<ReceivedMessageEnvelope>>{
      'conv_1': <ReceivedMessageEnvelope>[
        envelope('msg_2', 'conv_1'),
        envelope('msg_1', 'conv_1'),
      ],
      'conv_2': <ReceivedMessageEnvelope>[envelope('msg_3', 'conv_2')],
      'conv_3': <ReceivedMessageEnvelope>[envelope('msg_4', 'conv_3')],
    };
    expect(await write(conversations, messages, cursor: 3), 3 + 4 + 1);
    await expectStored(conversations, messages);

    // Nothing changed: no row is written (the cursor row still is).
    expect(await write(conversations, messages, cursor: 3), 1);
    expect(await write(conversations, messages), 0);
    await expectStored(conversations, messages);

    // A new message at the head moves its conversation to the top and the
    // conversation's older rows down one position.
    conversations = <Conversation>[
      conversations[1],
      conversations[0],
      conversations[2],
    ];
    messages = <String, List<ReceivedMessageEnvelope>>{
      ...messages,
      'conv_2': <ReceivedMessageEnvelope>[
        envelope('msg_5', 'conv_2'),
        envelope('msg_3', 'conv_2'),
      ],
    };
    // conv_2 and conv_1 swap positions; msg_5 is new and msg_3 moves.
    expect(await write(conversations, messages), 2 + 2);
    await expectStored(conversations, messages);

    // A changed payload, an envelope that moved conversation, a renamed
    // conversation and a conversation that left with its envelopes.
    conversations = <Conversation>[
      conversations[0],
      Conversation(id: 'conv_1', kind: 'group', title: 'Renamed'),
    ];
    messages = <String, List<ReceivedMessageEnvelope>>{
      'conv_1': <ReceivedMessageEnvelope>[
        envelope('msg_2', 'conv_1', ciphertext: 2),
        envelope('msg_1', 'conv_1'),
        envelope('msg_4', 'conv_1'),
      ],
      'conv_2': messages['conv_2']!,
    };
    // conv_3 deleted, conv_1 updated; msg_2 updated, msg_4 moved.
    expect(await write(conversations, messages), 2 + 2);
    await expectStored(conversations, messages);

    // An empty projection empties both tables.
    expect(
        await write(const <Conversation>[],
            const <String, List<ReceivedMessageEnvelope>>{}),
        2 + 5);
    expect(await store.loadSnapshot(), isNull);
    expect(
        (await database
                .customSelect('SELECT COUNT(*) AS rows FROM '
                    'local_ciphertext_envelopes')
                .getSingle())
            .read<int>('rows'),
        0);
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
    expect(createStore().loadSession(),
        throwsA(_storeFailure(LocalStoreFailureKind.upgradeFailed)));
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
    await dropExpiryColumns(database);
    await stripW8Schema(database);
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

  const envelopeIndex = 'local_ciphertext_envelopes_conversation_position';

  Future<int> userVersion(EncryptedLocalDatabase database) async =>
      (await database.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version');

  Future<bool> hasEnvelopeIndex(EncryptedLocalDatabase database) async =>
      (await database.customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
        variables: <Variable<Object>>[Variable<String>(envelopeIndex)],
      ).get())
          .isNotEmpty;

  /// SQLite's plan for the tail lookup that every received message's commit
  /// makes, built exactly as `commitSyncEvent` and `commitMlsTransition`
  /// build it.
  Future<String> tailLookupPlan(EncryptedLocalDatabase database) async {
    final query = database.select(database.localCiphertextEnvelopes)
      ..where((table) => table.conversationId.equals('conv_1'))
      ..orderBy([(table) => OrderingTerm.desc(table.position)])
      ..limit(1);
    final rows = await database.customSelect(
      'EXPLAIN QUERY PLAN ${query.constructQuery().sql}',
      variables: <Variable<Object>>[Variable<String>('conv_1')],
    ).get();
    return rows.map((row) => row.read<String>('detail')).join('\n');
  }

  test('a new database has the envelope index on schema 12', () async {
    final store = createStore();
    await store.saveSyncCursor(1);
    final database = databases.last;
    expect(await userVersion(database),
        EncryptedLocalDatabase.currentSchemaVersion);
    expect(await hasEnvelopeIndex(database), isTrue);
    expect(
        await tailLookupPlan(database),
        'SEARCH local_ciphertext_envelopes USING INDEX $envelopeIndex '
        '(conversation_id=?)');
  });

  test('a version 8 database keeps its rows and gains the envelope index',
      () async {
    final store = createStore();
    await store.saveSnapshot(
      <Conversation>[
        Conversation(id: 'conv_1', kind: 'group'),
        Conversation(id: 'conv_2', kind: 'group'),
      ],
      <String, List<ReceivedMessageEnvelope>>{
        'conv_1': <ReceivedMessageEnvelope>[
          _receivedEnvelope(),
          _receivedEnvelope(id: 'msg_2'),
        ],
        'conv_2': <ReceivedMessageEnvelope>[
          _receivedEnvelope(id: 'msg_3', conversationId: 'conv_2'),
        ],
      },
      1,
    );
    final database = databases.last;
    await database.customStatement('DROP INDEX $envelopeIndex');
    await dropExpiryColumns(database);
    await stripW8Schema(database);
    await database.customStatement('PRAGMA user_version = 8');
    expect(await tailLookupPlan(database), isNot(contains(envelopeIndex)));
    await database.close();
    databases.removeLast();

    final upgraded = createStore();
    final snapshot = await upgraded.loadSnapshot();
    final reopened = databases.last;
    expect(await userVersion(reopened),
        EncryptedLocalDatabase.currentSchemaVersion);
    expect(await hasEnvelopeIndex(reopened), isTrue);
    expect(await tailLookupPlan(reopened), contains('INDEX $envelopeIndex'));
    expect(snapshot?.cursor, 1);
    expect(snapshot?.conversations.map((item) => item.id),
        <String>['conv_1', 'conv_2']);
    expect(snapshot?.messagesByConversation['conv_1']?.map((item) => item.id),
        <String>['msg_1', 'msg_2']);
    expect(snapshot?.messagesByConversation['conv_2']?.map((item) => item.id),
        <String>['msg_3']);

    // A received message still lands after its conversation's tail.
    await upgraded.commitSyncEvent(SyncEventCommit(
      eventKey: 'sync:2',
      conversationId: 'conv_1',
      expectedCursor: 1,
      cursor: 2,
      envelope: _receivedEnvelope(id: 'msg_4'),
    ));
    expect(
        (await upgraded.loadSnapshot())
            ?.messagesByConversation['conv_1']
            ?.map((item) => item.id),
        <String>['msg_1', 'msg_2', 'msg_4']);
  });

  test('a failed upgrade leaves the old schema and version in place', () async {
    late File databaseFile;
    late String databaseKey;
    SecureLocalStore openStore() => SecureLocalStore(
          storage: secureStorage,
          directoryProvider: () async => directory,
          databaseFactory: (file, keyHex) {
            databaseFile = file;
            databaseKey = keyHex;
            final database = openEncryptedLocalDatabase(file, keyHex);
            databases.add(database);
            return database;
          },
        );
    final store = openStore();
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
    // A version 7 database whose last step (the index) cannot be created
    // because a table already has its name.
    for (final column in <String>[
      'attempt_count',
      'next_attempt_at',
      'failure_class',
      'terminal',
    ]) {
      await database.customStatement(
          'ALTER TABLE local_mls_outbox_entries DROP COLUMN $column');
    }
    await database.customStatement('DROP INDEX $envelopeIndex');
    await database.customStatement('CREATE TABLE $envelopeIndex (blocker)');
    await dropExpiryColumns(database);
    await stripW8Schema(database);
    await database.customStatement('PRAGMA user_version = 7');
    await database.close();
    databases.removeLast();

    // The open fails as an upgrade failure, not as a wrong key, and the file
    // and its key are left alone. It is not a full device, so it is not
    // reported as one.
    await expectLater(openStore().pendingMlsMessages(),
        throwsA(_storeFailure(LocalStoreFailureKind.upgradeFailed)));
    await databases.removeLast().close();
    expect(
        await secureStorage.read(key: 'veritra.database_key.v1'), databaseKey);

    // Nothing of the earlier version 8 step stayed behind.
    final raw = sqlite3.open(databaseFile.path);
    try {
      raw
        ..execute("PRAGMA cipher = 'chacha20'")
        ..execute("PRAGMA hexkey = '$databaseKey'");
      expect(raw.select('PRAGMA user_version').single['user_version'], 7);
      expect(
          raw
              .select('PRAGMA table_info(local_mls_outbox_entries)')
              .map((row) => row['name']),
          isNot(contains('attempt_count')));
      raw.execute('DROP TABLE $envelopeIndex');
    } finally {
      raw.close();
    }

    // With the cause gone, the next open runs the whole upgrade.
    final upgraded = openStore();
    expect((await upgraded.pendingMlsMessages()).single.attemptCount, 0);
    expect(await userVersion(databases.last),
        EncryptedLocalDatabase.currentSchemaVersion);
    expect(await hasEnvelopeIndex(databases.last), isTrue);
  });

  /// A version 8 database with cached rows, compacted so that creating the
  /// envelope index needs new pages. Returns its page count.
  Future<int> seedVersion8() async {
    final store = createStore();
    await store.saveSnapshot(
      <Conversation>[Conversation(id: 'conv_1', kind: 'group')],
      <String, List<ReceivedMessageEnvelope>>{
        'conv_1': <ReceivedMessageEnvelope>[
          for (var index = 0; index < 200; index++)
            _receivedEnvelope(id: 'msg_$index'),
        ],
      },
      1,
    );
    final database = databases.last;
    await database.customStatement('DROP INDEX $envelopeIndex');
    await dropExpiryColumns(database);
    await stripW8Schema(database);
    await database.customStatement('PRAGMA user_version = 8');
    await database.customStatement('VACUUM');
    final pages = (await database.customSelect('PRAGMA page_count').getSingle())
        .read<int>('page_count');
    await database.close();
    databases.removeLast();
    return pages;
  }

  Future<void> dropSearchIndex(EncryptedLocalDatabase database) async {
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
  }

  Future<void> insertTextMessages(
      EncryptedLocalDatabase database, int count) async {
    await database.applyMessageEffects(<MessageEffect>[
      for (var index = 0; index < count; index++)
        InsertMessageEffect(
          key: 'dev_peer:m$index',
          conversationId: 'conv_1',
          senderAccountId: 'acct_peer',
          senderDeviceId: 'dev_peer',
          kind: LocalMessageKind.text,
          body: 'searchable words number $index',
          createdAt: index,
          state: LocalMessageState.received,
        ),
    ]);
  }

  test('an upgrade from schema 6 builds every later table once', () async {
    final store = createStore();
    await store.saveSyncCursor(1);
    final database = databases.last;
    await insertTextMessages(database, 3);
    await dropExpiryColumns(database);
    await database.customStatement('DROP TABLE local_messages');
    await database.customStatement('DROP TABLE local_message_reactions');
    for (final column in <String>[
      'attempt_count',
      'next_attempt_at',
      'failure_class',
      'terminal',
    ]) {
      await database.customStatement(
          'ALTER TABLE local_mls_outbox_entries DROP COLUMN $column');
    }
    await stripW8Schema(database);
    await database.customStatement('PRAGMA user_version = 6');
    await database.close();
    databases.removeLast();

    final upgraded = createStore();
    expect(await upgraded.loadSyncCursor(), 1);
    final reopened = databases.last;
    expect(await userVersion(reopened),
        EncryptedLocalDatabase.currentSchemaVersion);
    await reopened.applyMessageEffects(<MessageEffect>[
      const InsertMessageEffect(
        key: 'dev_peer:new',
        conversationId: 'conv_1',
        senderAccountId: 'acct_peer',
        senderDeviceId: 'dev_peer',
        kind: LocalMessageKind.text,
        body: 'after the upgrade',
        createdAt: 1,
        state: LocalMessageState.received,
      ),
    ]);
    expect(
        (await upgraded.searchMessages('upgrade')).single.key, 'dev_peer:new');
    expect(await upgraded.pendingMlsMessages(), isEmpty);
  });

  test('an upgrade from schema 2 builds every later table once', () async {
    final store = createStore();
    await store.saveSyncCursor(1);
    final database = databases.last;
    await dropExpiryColumns(database);
    await database.customStatement('DROP TABLE local_messages');
    await database.customStatement('DROP TABLE local_message_reactions');
    await database.customStatement('DROP TABLE local_peer_verifications');
    await database.customStatement('DROP TABLE local_mls_outbox_entries');
    for (final column in <String>[
      'attempt_count',
      'next_attempt_at',
      'failure_class',
      'terminal',
    ]) {
      await database.customStatement(
          'ALTER TABLE local_outbox_entries DROP COLUMN $column');
    }
    await stripW8Schema(database);
    await database.customStatement('PRAGMA user_version = 2');
    await database.close();
    databases.removeLast();

    final upgraded = createStore();
    expect(await upgraded.loadSyncCursor(), 1);
    expect(await userVersion(databases.last),
        EncryptedLocalDatabase.currentSchemaVersion);
  });

  test('an upgrade from schema 3 keeps its rows and builds every later table',
      () async {
    final store = createStore();
    await store.saveSyncCursor(1);
    final database = databases.last;
    await dropExpiryColumns(database);
    await database.customStatement('DROP TABLE local_messages');
    await database.customStatement('DROP TABLE local_message_reactions');
    await database.customStatement('DROP TABLE local_peer_verifications');
    for (final column in <String>[
      'revocation_device_id',
      'attempt_count',
      'next_attempt_at',
      'failure_class',
      'terminal',
    ]) {
      await database.customStatement(
          'ALTER TABLE local_mls_outbox_entries DROP COLUMN $column');
    }
    for (final column in <String>[
      'attempt_count',
      'next_attempt_at',
      'failure_class',
      'terminal',
    ]) {
      await database.customStatement(
          'ALTER TABLE local_outbox_entries DROP COLUMN $column');
    }
    // Rows exactly as a schema 3 build wrote them.
    await database.customStatement('INSERT INTO local_outbox_entries '
        '(idempotency_key, conversation_id, queued_at, payload_json) '
        "VALUES ('idem_1', 'conv_1', 1, '{}')");
    await database.customStatement(
        'INSERT INTO local_mls_outbox_entries (idempotency_key, '
        'conversation_id, kind, recipient_device_id, payload, state_counter, '
        "queued_at) VALUES ('mls_1', 'conv_1', 'welcome', 'dev_2', x'0102', 1, 1)");
    await stripW8Schema(database);
    await database.customStatement('PRAGMA user_version = 3');
    await database.close();
    databases.removeLast();

    final upgraded = createStore();
    expect(await upgraded.loadSyncCursor(), 1);
    final reopened = databases.last;
    expect(await userVersion(reopened),
        EncryptedLocalDatabase.currentSchemaVersion);
    // The old rows are there with the new columns at their defaults.
    final outbox = await reopened
        .customSelect(
            'SELECT attempt_count, terminal FROM local_outbox_entries')
        .getSingle();
    expect(outbox.read<int>('attempt_count'), 0);
    expect(outbox.read<int>('terminal'), 0);
    final pending = await upgraded.pendingMlsMessages();
    expect(pending.single.idempotencyKey, 'mls_1');
    expect(pending.single.revocationDeviceId, isNull);
    // The later tables, the expiry columns, drafts and search all exist.
    await upgraded.saveDraft('conv_1', 'after the upgrade');
    expect((await upgraded.loadDrafts())['conv_1']?.text, 'after the upgrade');
    await reopened.applyMessageEffects(<MessageEffect>[
      const InsertMessageEffect(
        key: 'dev_peer:new',
        conversationId: 'conv_1',
        senderAccountId: 'acct_peer',
        senderDeviceId: 'dev_peer',
        kind: LocalMessageKind.text,
        body: 'after the upgrade',
        createdAt: 1,
        state: LocalMessageState.received,
      ),
    ]);
    expect(
        (await upgraded.searchMessages('upgrade')).single.key, 'dev_peer:new');
    final verifications = await reopened
        .customSelect('SELECT count(*) AS n FROM local_peer_verifications')
        .getSingle();
    expect(verifications.read<int>('n'), 0);
    expect(await upgraded.nextMessageExpiry(), isNull);
  });

  group('SQLite features (W10)', () {
    test('FTS5 missing is its own failure, not a rejected key', () async {
      final original = await seedAndClose();
      final key = await secureStorage.read(key: 'veritra.database_key.v1');
      final store = SecureLocalStore(
        storage: secureStorage,
        directoryProvider: () async => directory,
        databaseFactory: (file, keyHex) {
          final opened = _openWithoutFts5(file, keyHex);
          databases.add(opened);
          return opened;
        },
      );
      await expectLater(
          store.loadSyncCursor(),
          throwsA(allOf(
              _storeFailure(LocalStoreFailureKind.sqliteFeatureMissing),
              isA<LocalStoreUnavailableException>()
                  .having((error) => error.retryable, 'retryable', isFalse))));
      // Nothing was moved, deleted or reset.
      await expectDatabaseUnchanged(original);
      expect(await secureStorage.read(key: 'veritra.database_key.v1'), key);
      expect(
          directory
              .listSync()
              .where((item) => item.path.contains('unreadable-')),
          isEmpty);
    });

    test('FTS5 missing on a new profile is the same failure', () async {
      final store = SecureLocalStore(
        storage: secureStorage,
        directoryProvider: () async => directory,
        databaseFactory: (file, keyHex) {
          final opened = _openWithoutFts5(file, keyHex);
          databases.add(opened);
          return opened;
        },
      );
      await expectLater(store.loadSyncCursor(),
          throwsA(_storeFailure(LocalStoreFailureKind.sqliteFeatureMissing)));
    });

    test('the check passes on this build and fails on an injected answer', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db.execute("PRAGMA cipher = 'chacha20'");
      requireSqliteFeatures(db);
      expect(
          () => requireSqliteFeatures(db,
              compileOptionUsed: (_, option) => option != 'ENABLE_FTS5'),
          throwsA(isA<SqliteFeatureUnavailable>()
              .having((error) => error.feature, 'feature', 'fts5')));
      expect(
          isSqliteFeatureUnavailable(DriftWrappedException(
              message: 'wrapped',
              cause: const SqliteFeatureUnavailable('fts5'))),
          isTrue);
      expect(isSqliteFeatureUnavailable(StateError('x')), isFalse);
    });
  });

  test(
      'the search index is required: a full disk fails the 11 to 12 upgrade '
      'and a retry completes it', () async {
    final store = createStore();
    await store.saveSyncCursor(1);
    final database = databases.last;
    await insertTextMessages(database, 400);
    await dropSearchIndex(database);
    await stripW8Schema(database);
    await database.customStatement('PRAGMA user_version = 11');
    await database.customStatement('VACUUM');
    final pages = (await database.customSelect('PRAGMA page_count').getSingle())
        .read<int>('page_count');
    await database.close();
    databases.removeLast();
    final original =
        File('${directory.path}/veritra-local.db').readAsBytesSync();

    var diskFull = true;
    final constrained = SecureLocalStore(
      storage: secureStorage,
      directoryProvider: () async => directory,
      databaseFactory: (file, keyHex) {
        final opened = diskFull
            ? _openWithoutRoom(file, keyHex, pages)
            : openEncryptedLocalDatabase(file, keyHex);
        databases.add(opened);
        return opened;
      },
    );
    await expectLater(constrained.searchMessages('words'),
        throwsA(_storeFailure(LocalStoreFailureKind.upgradeStorageFull)));
    await expectDatabaseUnchanged(original);

    diskFull = false;
    expect(await constrained.searchMessages('words'), hasLength(50));
    expect(await userVersion(databases.last),
        EncryptedLocalDatabase.currentSchemaVersion);
  });

  test('a full disk during the upgrade is reported as a full device', () async {
    final pages = await seedVersion8();
    final original =
        File('${directory.path}/veritra-local.db').readAsBytesSync();
    final key = await secureStorage.read(key: 'veritra.database_key.v1');
    // The file may not grow: what a full disk does to the index's pages.
    var diskFull = true;
    final store = SecureLocalStore(
      storage: secureStorage,
      directoryProvider: () async => directory,
      databaseFactory: (file, keyHex) {
        final database = diskFull
            ? _openWithoutRoom(file, keyHex, pages)
            : openEncryptedLocalDatabase(file, keyHex);
        databases.add(database);
        return database;
      },
    );

    await expectLater(
        store.loadSnapshot(),
        throwsA(allOf(
            _storeFailure(LocalStoreFailureKind.upgradeStorageFull),
            isA<LocalStoreUnavailableException>()
                .having((error) => error.retryable, 'retryable', isTrue))));
    // Nothing was changed, moved, deleted or reset.
    await expectDatabaseUnchanged(original);
    expect(await secureStorage.read(key: 'veritra.database_key.v1'), key);
    expect(
        directory.listSync().where((item) => item.path.contains('unreadable-')),
        isEmpty);

    // With room again, a retry on the same store completes the upgrade.
    diskFull = false;
    final snapshot = await store.loadSnapshot();
    expect(snapshot?.cursor, 1);
    expect(snapshot?.messagesByConversation['conv_1'], hasLength(200));
    expect(await userVersion(databases.last),
        EncryptedLocalDatabase.currentSchemaVersion);
    expect(await hasEnvelopeIndex(databases.last), isTrue);
  });

  test('only a full device or an I/O error counts as a full device', () {
    SqliteException sqlite(int code) =>
        SqliteException(extendedResultCode: code, message: 'test');
    // SQLITE_FULL, SQLITE_IOERR and an extended code (SQLITE_IOERR_WRITE).
    for (final code in <int>[13, 10, 778]) {
      expect(isStorageFullError(sqlite(code)), isTrue, reason: '$code');
      expect(
          isStorageFullError(
              DriftWrappedException(message: 'wrapped', cause: sqlite(code))),
          isTrue);
    }
    expect(
        isStorageFullError(CouldNotRollBackException(
            StateError('step'), StackTrace.empty, sqlite(10))),
        isTrue);
    // SQLITE_ERROR, SQLITE_CORRUPT, SQLITE_NOTADB and anything else.
    for (final code in <int>[1, 11, 26]) {
      expect(isStorageFullError(sqlite(code)), isFalse, reason: '$code');
    }
    expect(isStorageFullError(StateError('disk is full')), isFalse);
    expect(isStorageFullError(DriftWrappedException(message: 'no cause')),
        isFalse);
  });

  test('a wrong key on a database that needs an upgrade is a wrong key',
      () async {
    await seedVersion8();
    final original =
        File('${directory.path}/veritra-local.db').readAsBytesSync();
    await secureStorage.write(key: 'veritra.database_key.v1', value: 'ab' * 32);
    await expectLater(createStore().loadSnapshot(),
        throwsA(_storeFailure(LocalStoreFailureKind.keyRejected)));
    await expectDatabaseUnchanged(original);
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

ReceivedMessageEnvelope _receivedEnvelope({
  String id = 'msg_1',
  String conversationId = 'conv_1',
}) =>
    ReceivedMessageEnvelope(
      id: id,
      conversationId: conversationId,
      senderAccountId: 'acct_1',
      senderDeviceId: 'dev_1',
      idempotencyKey: 'received_1',
      ciphertext: <int>[4, 5, 6],
      cryptoProtocol: 'mls10-openmls-v1',
      createdAt: DateTime.utc(2026, 7, 29),
    );

/// Opens [file] exactly as [openEncryptedLocalDatabase] does, but caps it at
/// [maxPages] pages, so any write that needs a new page fails with
/// SQLITE_FULL, as on a full disk.
EncryptedLocalDatabase _openWithoutRoom(
        File file, String keyHex, int maxPages) =>
    EncryptedLocalDatabase(NativeDatabase.createInBackground(
      file,
      setup: (rawDatabase) {
        rawDatabase.execute("PRAGMA cipher = 'chacha20'");
        rawDatabase.execute("PRAGMA hexkey = '$keyHex'");
        rawDatabase.execute('PRAGMA busy_timeout = 5000');
        rawDatabase.select('SELECT count(*) FROM sqlite_master');
        rawDatabase.execute('PRAGMA journal_mode = WAL');
        rawDatabase.execute('PRAGMA max_page_count = $maxPages');
      },
    ));

/// Opens like [openEncryptedLocalDatabase] on a SQLite build without FTS5.
/// The answer is faked inside the background isolate, as a real build would
/// give it, so the error reaches the app the way a real one does.
EncryptedLocalDatabase _openWithoutFts5(File file, String keyHex) =>
    EncryptedLocalDatabase(NativeDatabase.createInBackground(
      file,
      setup: (rawDatabase) {
        rawDatabase.execute("PRAGMA cipher = 'chacha20'");
        rawDatabase.execute("PRAGMA hexkey = '$keyHex'");
        requireSqliteFeatures(rawDatabase, compileOptionUsed: _noFts5);
      },
    ));

bool _noFts5(CommonDatabase db, String option) => option != 'ENABLE_FTS5';

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
