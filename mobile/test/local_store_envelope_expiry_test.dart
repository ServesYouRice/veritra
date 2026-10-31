import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// Envelopes moved over from the legacy secure-storage record keep their
/// expiry (W2), and a database that already moved them without it is
/// repaired once on open, without a server refresh (TASK-081).

const _repairMarker = 'envelope_expiry_backfill.v1';

ReceivedMessageEnvelope _envelope(String id, DateTime? expiresAt) =>
    ReceivedMessageEnvelope(
      id: id,
      conversationId: 'conv_1',
      senderAccountId: 'acct_2',
      senderDeviceId: 'dev_2',
      idempotencyKey: 'idem_$id',
      ciphertext: const <int>[4, 5, 6],
      cryptoProtocol: 'mls10-openmls-v1',
      createdAt: DateTime.utc(2026, 7, 29),
      expiresAt: expiresAt,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;
  const storage = FlutterSecureStorage();
  final past = DateTime.utc(2020, 1, 1);
  final future = DateTime.now().toUtc().add(const Duration(days: 30));
  final later = future.add(const Duration(days: 30));

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-expiry-');
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
        storage: storage,
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

  Future<Map<String, int?>> expiries(EncryptedLocalDatabase database) async {
    final rows = await database
        .customSelect('SELECT id, expires_at FROM local_ciphertext_envelopes')
        .get();
    return <String, int?>{
      for (final row in rows)
        row.read<String>('id'): row.read<int?>('expires_at'),
    };
  }

  test('a legacy import stores each envelope expiry from its JSON', () async {
    final database = openEncryptedLocalDatabase(
        File('${directory.path}/import.db'), 'cd' * 32);
    databases.add(database);
    final rows = <String, String>{
      'env_past': jsonEncode(_envelope('env_past', past).toJson()),
      'env_future': jsonEncode(_envelope('env_future', future).toJson()),
      'env_none': jsonEncode(_envelope('env_none', null).toJson()),
    };
    var position = 0;
    await database.importLegacy(
      sessionJson: null,
      conversations: const <({String id, String payloadJson})>[],
      envelopes: <({
        String id,
        String conversationId,
        int position,
        String payloadJson
      })>[
        for (final entry in rows.entries)
          (
            id: entry.key,
            conversationId: 'conv_1',
            position: position++,
            payloadJson: entry.value,
          ),
      ],
      outbox: const <({
        String idempotencyKey,
        String conversationId,
        int queuedAt,
        String payloadJson,
      })>[],
      cryptoState: null,
      cursor: 3,
    );
    expect(await expiries(database), <String, int?>{
      'env_past': past.millisecondsSinceEpoch,
      'env_future': future.millisecondsSinceEpoch,
      'env_none': null,
    });
    // Nothing is purged during the import itself.
    expect(await database.nextExpiry(), past.millisecondsSinceEpoch);
  });

  test('a migrated legacy record expires its envelopes like any other',
      () async {
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
          'conv_1': <Object?>[
            _envelope('env_past', past).toJson(),
            _envelope('env_future', future).toJson(),
          ],
        },
      },
      'outbox': <Object?>[],
    };
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'veritra.account_state.v2': jsonEncode(legacy),
    });

    final store = createStore();
    // The migration verified and finished: the record is gone.
    expect(await store.loadSyncCursor(), 17);
    expect(await storage.read(key: 'veritra.account_state.v2'), isNull);
    expect(await expiries(databases.single), <String, int?>{
      'env_past': past.millisecondsSinceEpoch,
      'env_future': future.millisecondsSinceEpoch,
    });
    expect((await store.nextMessageExpiry())?.millisecondsSinceEpoch,
        past.millisecondsSinceEpoch);
    expect(await store.purgeExpiredMessages(), <String>{'conv_1'});
    expect(await expiries(databases.single), <String, int?>{
      'env_future': future.millisecondsSinceEpoch,
    });
    expect((await store.nextMessageExpiry())?.millisecondsSinceEpoch,
        future.millisecondsSinceEpoch);
  });

  /// A database left by an older build: migration marker '1', no repair
  /// marker, and envelopes imported with no expiry. None of them is listed
  /// by any server refresh in these tests.
  Future<void> seedAlreadyMigrated() async {
    final store = createStore();
    expect(await store.loadSyncCursor(), 0);
    final database = databases.single;
    expect(await database.readMetadata('legacy_secure_record_migrated'), '1');
    await database.deleteMetadata(_repairMarker);
    final rows = <(String, String, int?)>[
      ('env_past', jsonEncode(_envelope('env_past', past).toJson()), null),
      ('env_future', jsonEncode(_envelope('env_future', future).toJson()), null),
      ('env_none', jsonEncode(_envelope('env_none', null).toJson()), null),
      // Already carries an expiry that differs from its JSON: kept.
      (
        'env_kept',
        jsonEncode(_envelope('env_kept', past).toJson()),
        later.millisecondsSinceEpoch
      ),
    ];
    var position = 0;
    for (final (id, json, expiresAt) in rows) {
      await database.customStatement(
          'INSERT INTO local_ciphertext_envelopes '
          '(id, conversation_id, position, payload_json, expires_at) '
          'VALUES (?, ?, ?, ?, ?)',
          <Object?>[id, 'conv_1', position++, json, expiresAt]);
    }
    await closeAll();
  }

  test('an already migrated database gets its envelope expiry on reopen',
      () async {
    await seedAlreadyMigrated();

    final store = createStore();
    // No server refresh: only opening the store.
    expect((await store.nextMessageExpiry())?.millisecondsSinceEpoch,
        past.millisecondsSinceEpoch);
    final database = databases.single;
    expect(await expiries(database), <String, int?>{
      'env_past': past.millisecondsSinceEpoch,
      'env_future': future.millisecondsSinceEpoch,
      'env_none': null,
      'env_kept': later.millisecondsSinceEpoch,
    });
    expect(await database.readMetadata(_repairMarker), isNotNull);
    expect(await store.purgeExpiredMessages(), <String>{'conv_1'});
    expect((await expiries(database)).keys,
        unorderedEquals(<String>['env_future', 'env_none', 'env_kept']));
    expect((await store.nextMessageExpiry())?.millisecondsSinceEpoch,
        future.millisecondsSinceEpoch);

    // A second open rewrites nothing: a value changed by hand survives.
    await database.customStatement(
        'UPDATE local_ciphertext_envelopes SET expires_at = NULL '
        "WHERE id = 'env_future'");
    await closeAll();
    final reopened = createStore();
    await reopened.loadSyncCursor();
    expect((await expiries(databases.single))['env_future'], isNull);
  });

  test('an interrupted repair runs again on the next open', () async {
    await seedAlreadyMigrated();
    // A repair cut short before its marker: one row done, no marker.
    final first = openEncryptedLocalDatabase(
        File('${directory.path}/veritra-local.db'),
        (await storage.read(key: 'veritra.database_key.v1'))!);
    await first.customStatement(
        'UPDATE local_ciphertext_envelopes SET expires_at = ? '
        "WHERE id = 'env_past'",
        <Object?>[past.millisecondsSinceEpoch]);
    expect(await first.readMetadata(_repairMarker), isNull);
    await first.close();

    final store = createStore();
    await store.loadSyncCursor();
    expect(await expiries(databases.single), <String, int?>{
      'env_past': past.millisecondsSinceEpoch,
      'env_future': future.millisecondsSinceEpoch,
      'env_none': null,
      'env_kept': later.millisecondsSinceEpoch,
    });
    expect(await databases.single.readMetadata(_repairMarker), isNotNull);
  });

  test('a refresh repairs a cached envelope whose stored expiry is missing',
      () async {
    await seedAlreadyMigrated();
    final store = createStore();
    await store.loadSyncCursor();
    final database = databases.single;
    // As if the repair had not reached it.
    await database.customStatement(
        'UPDATE local_ciphertext_envelopes SET expires_at = NULL '
        "WHERE id = 'env_future'");

    await database.replaceSnapshot(
      conversations: const <({String id, String payloadJson})>[],
      envelopes: <({
        String id,
        String conversationId,
        int position,
        String payloadJson
      })>[
        (
          id: 'env_future',
          conversationId: 'conv_1',
          position: 1,
          payloadJson: jsonEncode(_envelope('env_future', future).toJson()),
        ),
      ],
      cursor: null,
    );
    expect((await expiries(database))['env_future'],
        future.millisecondsSinceEpoch);
  });
}
