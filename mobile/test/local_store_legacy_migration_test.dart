import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// A legacy secure-storage record that cannot be migrated fails the open
/// with a classified [LocalStoreUnavailableException] and closes the opened
/// handle; once migrated, an unreadable keystore no longer blocks opening
/// (TASK-082).

const _legacyKey = 'veritra.account_state.v2';

class _ScriptedStorage extends FlutterSecureStorage {
  _ScriptedStorage();

  bool Function(String key) failRead = (_) => false;

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
    if (failRead(key)) throw StateError('keystore locked');
    return super.read(key: key);
  }
}

/// Records whether it was closed, and can misreport the imported session so
/// the migration's verification fails.
class _WatchedDatabase extends EncryptedLocalDatabase {
  _WatchedDatabase(QueryExecutor executor, {this.misreportSession = false})
      : super(executor);

  final bool misreportSession;
  bool closed = false;

  @override
  Future<String?> readSessionJson() async {
    final stored = await super.readSessionJson();
    return misreportSession && stored != null ? '{}' : stored;
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

String _legacyRecord() => jsonEncode(<String, Object?>{
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
        'messages': <String, Object?>{},
      },
      'outbox': <Object?>[],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<_WatchedDatabase> databases;
  const plain = FlutterSecureStorage();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-legacy-');
    databases = <_WatchedDatabase>[];
  });

  tearDown(() async {
    for (final database in databases) {
      if (!database.closed) await database.close();
    }
    await SecureLocalStore.releaseInstanceLocks();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  SecureLocalStore storeWith(FlutterSecureStorage storage,
          {bool misreportSession = false}) =>
      SecureLocalStore(
        storage: storage,
        directoryProvider: () async => directory,
        databaseFactory: (file, keyHex) {
          final database = _WatchedDatabase(
              openEncryptedLocalDatabase(file, keyHex).executor,
              misreportSession: misreportSession);
          databases.add(database);
          return database;
        },
      );

  Matcher failure(LocalStoreFailureKind kind) =>
      isA<LocalStoreUnavailableException>()
          .having((error) => error.kind, 'kind', kind);

  test('a corrupt legacy record fails classified and closes the database',
      () async {
    FlutterSecureStorage.setMockInitialValues(
        <String, String>{_legacyKey: '{not-json'});
    final store = storeWith(plain);
    await expectLater(store.loadSession(),
        throwsA(failure(LocalStoreFailureKind.upgradeFailed)));
    expect(databases.single.closed, isTrue);
    // Nothing is deleted, and a retry runs the migration again.
    expect(await plain.read(key: _legacyKey), '{not-json');
    await expectLater(store.loadSession(),
        throwsA(failure(LocalStoreFailureKind.upgradeFailed)));
    expect(databases, hasLength(2));
    expect(databases.every((database) => database.closed), isTrue);
  });

  test('a failed migration check fails classified and keeps the record',
      () async {
    FlutterSecureStorage.setMockInitialValues(
        <String, String>{_legacyKey: _legacyRecord()});
    await expectLater(storeWith(plain, misreportSession: true).loadSession(),
        throwsA(failure(LocalStoreFailureKind.upgradeFailed)));
    expect(databases.single.closed, isTrue);
    expect(await plain.read(key: _legacyKey), isNotNull);

    // A later open whose check passes finishes the migration.
    final store = storeWith(plain);
    expect((await store.loadSession())?.deviceId, 'dev_1');
    expect(await plain.read(key: _legacyKey), isNull);
  });

  test('an unreadable legacy record is a keystore failure, and retryable',
      () async {
    FlutterSecureStorage.setMockInitialValues(
        <String, String>{_legacyKey: _legacyRecord()});
    final storage = _ScriptedStorage()..failRead = (key) => key == _legacyKey;
    final store = storeWith(storage);
    await expectLater(store.loadSession(),
        throwsA(failure(LocalStoreFailureKind.keyUnavailable)));
    expect(databases.single.closed, isTrue);

    storage.failRead = (_) => false;
    expect((await store.loadSession())?.deviceId, 'dev_1');
    expect(await plain.read(key: _legacyKey), isNull);
  });

  test('after the migration, an unreadable legacy entry does not block opening',
      () async {
    FlutterSecureStorage.setMockInitialValues(
        <String, String>{_legacyKey: _legacyRecord()});
    expect(await storeWith(plain).loadSyncCursor(), 17);
    for (final database in databases) {
      await database.close();
    }

    final storage = _ScriptedStorage()..failRead = (key) => key == _legacyKey;
    final store = storeWith(storage);
    expect(await store.loadSyncCursor(), 17);
    expect(databases.last.closed, isFalse);
  });
}
