import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// Resetting an unreadable local database (I39): the reset moves the files
/// aside and may drop the database key only once a copy of it was stored
/// and read back (TASK-079).

const _keyName = 'veritra.database_key.v1';
const _archivePrefix = '$_keyName.quarantined.';

/// Secure storage whose reads and writes can be made to fail, or to store
/// something other than what was written, per key.
class _ScriptedStorage extends FlutterSecureStorage {
  _ScriptedStorage();

  bool Function(String key) failRead = (_) => false;
  bool Function(String key) failWrite = (_) => false;
  String Function(String key, String value) stored = (_, value) => value;

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

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (failWrite(key)) throw StateError('keystore refused the write');
    return super.write(
        key: key, value: value == null ? null : stored(key, value));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;
  // Reads the stored entries directly, past any scripted failure.
  const plain = FlutterSecureStorage();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-reset-');
    databases = <EncryptedLocalDatabase>[];
  });

  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    await SecureLocalStore.releaseInstanceLocks();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  SecureLocalStore storeWith(FlutterSecureStorage storage) => SecureLocalStore(
        storage: storage,
        directoryProvider: () async => directory,
        databaseFactory: (file, keyHex) {
          final database = openEncryptedLocalDatabase(file, keyHex);
          databases.add(database);
          return database;
        },
      );

  /// A database holding cursor 4, closed, and its key.
  Future<({List<int> bytes, String key})> seed() async {
    await storeWith(plain).saveSyncCursor(4);
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
    return (
      bytes: await File('${directory.path}/veritra-local.db').readAsBytes(),
      key: (await plain.read(key: _keyName))!,
    );
  }

  Directory quarantined() => directory
      .listSync()
      .whereType<Directory>()
      .where((item) => item.path.contains('unreadable-'))
      .single;

  Future<int> cursorOf(File file, String key) async {
    final copy = openEncryptedLocalDatabase(file, key);
    databases.add(copy);
    return copy.readCursor();
  }

  test('a key that cannot be read is kept, and the moved copy opens with it',
      () async {
    final original = await seed();
    final storage = _ScriptedStorage()..failRead = (key) => key == _keyName;
    final store = storeWith(storage);

    await store.quarantineUnreadableDatabase(confirmed: true);

    // The read failed, so nothing says the key is gone: it stays.
    expect(await plain.read(key: _keyName), original.key);
    final moved = File('${quarantined().path}/veritra-local.db');
    expect(moved.readAsBytesSync(), original.bytes);
    expect(await cursorOf(moved, original.key), 4);
    expect(File('${directory.path}/veritra-local.reset-intent').existsSync(),
        isFalse);

    // Once the keystore reads again, the device opens with the kept key.
    storage.failRead = (_) => false;
    expect(await store.loadSyncCursor(), 0);
    expect(await plain.read(key: _keyName), original.key);
  });

  test('a key whose copy cannot be written is not deleted', () async {
    final original = await seed();
    final storage = _ScriptedStorage()
      ..failWrite = (key) => key.startsWith(_archivePrefix);
    await storeWith(storage).quarantineUnreadableDatabase(confirmed: true);

    expect(await plain.read(key: _keyName), original.key);
    final moved = File('${quarantined().path}/veritra-local.db');
    expect(await cursorOf(moved, original.key), 4);
  });

  test('a key whose copy reads back different is not deleted', () async {
    final original = await seed();
    final storage = _ScriptedStorage()
      ..stored = (key, value) =>
          key.startsWith(_archivePrefix) ? 'ab' * 32 : value;
    await storeWith(storage).quarantineUnreadableDatabase(confirmed: true);

    expect(await plain.read(key: _keyName), original.key);
    final moved = File('${quarantined().path}/veritra-local.db');
    expect(await cursorOf(moved, original.key), 4);
  });

  test('a key whose copy cannot be read back is not deleted', () async {
    final original = await seed();
    final storage = _ScriptedStorage()
      ..failRead = (key) => key.startsWith(_archivePrefix);
    await storeWith(storage).quarantineUnreadableDatabase(confirmed: true);

    expect(await plain.read(key: _keyName), original.key);
  });

  test('a verified copy lets the reset drop the key as before', () async {
    final original = await seed();
    await storeWith(_ScriptedStorage())
        .quarantineUnreadableDatabase(confirmed: true);

    final folder = quarantined();
    final stamp = folder.path.split('unreadable-').last;
    expect(await plain.read(key: '$_archivePrefix$stamp'), original.key);
    expect(await plain.read(key: _keyName), isNull);
    final moved = File('${folder.path}/veritra-local.db');
    expect(moved.readAsBytesSync(), original.bytes);
    expect(await cursorOf(moved, original.key), 4);
    expect(File('${directory.path}/veritra-local.db').existsSync(), isFalse);
  });

  test('an interrupted reset with an unreadable key keeps the key', () async {
    final original = await seed();
    const stamp = '1700000000000000';
    File('${directory.path}/veritra-local.reset-intent')
        .writeAsStringSync(stamp);
    final storage = _ScriptedStorage()..failRead = (key) => key == _keyName;

    // The open finishes the reset first, then cannot read the key.
    await expectLater(
        storeWith(storage).loadSyncCursor(),
        throwsA(isA<LocalStoreUnavailableException>().having(
            (error) => error.kind, 'kind', LocalStoreFailureKind.keyUnavailable)));
    expect(await plain.read(key: _keyName), original.key);
    final moved = File('${directory.path}/unreadable-$stamp/veritra-local.db');
    expect(await cursorOf(moved, original.key), 4);
  });
}
