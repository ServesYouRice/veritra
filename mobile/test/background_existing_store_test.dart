import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  const session = Session(
      baseUrl: 'https://chat.example',
      token: 'fixture',
      accountId: 'acct_fixture',
      deviceId: 'dev_fixture');
  late Directory directory;
  late List<EncryptedLocalDatabase> opened;

  SecureLocalStore store(
          {bool existingOnly = false,
          Future<Directory> Function()? provider,
          String namespace = '',
          LocalDatabaseFactory? existingFactory}) =>
      SecureLocalStore(
          storage: storage,
          directoryProvider: provider ?? () async => directory,
          namespace: namespace,
          existingOnly: existingOnly,
          databaseFactory: (file, key) {
            final db = openEncryptedLocalDatabase(file, key);
            opened.add(db);
            return db;
          },
          existingDatabaseFactory: existingFactory ??
              (file, key) {
                final db = openExistingEncryptedLocalDatabase(file, key);
                opened.add(db);
                return db;
              });

  Future<void> closeAll() async {
    for (final db in opened) {
      try {
        await db.close();
      } catch (_) {}
    }
    opened.clear();
    await SecureLocalStore.releaseInstanceLocks();
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory =
        await Directory.systemTemp.createTemp('veritra-background-existing-');
    opened = [];
  });
  tearDown(() async {
    await closeAll();
    await directory.delete(recursive: true);
  });

  test('missing profile creates no directory, database or key', () async {
    await expectLater(
        store(existingOnly: true, namespace: 'demo').loadSession(),
        throwsA(isA<ExistingDatabaseUnavailable>()));
    expect(await directory.list(recursive: true).toList(), isEmpty);
    expect(await storage.readAll(), isEmpty);
    expect(opened, isEmpty);
  });

  test('missing key cannot replace an existing encrypted database', () async {
    await store().saveSession(session);
    await closeAll();
    final file = File('${directory.path}/veritra-local.db');
    final before = await file.readAsBytes();
    await storage.delete(key: 'veritra.database_key.v1');
    await expectLater(store(existingOnly: true).loadSession(),
        throwsA(isA<ExistingDatabaseUnavailable>()));
    expect(await storage.read(key: 'veritra.database_key.v1'), isNull);
    expect(await file.readAsBytes(), before);
    expect(opened, isEmpty);
  });

  test('current existing profile opens without replacing protected state',
      () async {
    final original = store();
    await original.saveSession(session);
    await original.saveCryptoState(
        StoredCryptoState(
            counter: 1, stateKey: List.filled(32, 9), sealedState: [1, 2, 3]),
        0);
    await closeAll();
    final before = await storage.readAll();
    final background = store(existingOnly: true);
    expect((await background.loadSession())?.deviceId, 'dev_fixture');
    expect((await background.loadCryptoState())?.counter, 1);
    expect(await storage.readAll(), before);
  });

  test(
      'strict raw opener refuses zero, older and future schemas without migration',
      () async {
    for (final version in [
      0,
      EncryptedLocalDatabase.currentSchemaVersion - 1,
      EncryptedLocalDatabase.currentSchemaVersion + 1
    ]) {
      final sub = Directory('${directory.path}/version-$version');
      await sub.create();
      final file = File('${sub.path}/encrypted.db');
      final key = List.filled(64, 'a').join();
      final original = openEncryptedLocalDatabase(file, key);
      await original.readCursor();
      await original.customStatement('PRAGMA user_version = $version');
      await original.close();
      final before = await file.readAsBytes();
      final strict = openExistingEncryptedLocalDatabase(file, key);
      opened.add(strict);
      await expectLater(strict.readCursor(), throwsA(anything));
      try {
        await strict.close();
      } catch (_) {}
      opened.remove(strict);
      expect(await file.readAsBytes(), before, reason: 'version $version');
    }
  });

  test('file removal after preflight cannot cause SQLite CREATE', () async {
    await store().saveSession(session);
    await closeAll();
    final before = await storage.readAll();
    final file = File('${directory.path}/veritra-local.db');
    final background = store(
        existingOnly: true,
        existingFactory: (f, key) {
          f.deleteSync();
          final db = openExistingEncryptedLocalDatabase(f, key);
          opened.add(db);
          return db;
        });
    await expectLater(background.loadSession(), throwsA(anything));
    expect(await file.exists(), isFalse);
    expect(await storage.readAll(), before);
  });

  test('actual UI enablement cannot weaken an already pending strict open',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var first = true;
    final background = store(
        existingOnly: true,
        namespace: 'demo',
        provider: () async {
          if (first) {
            first = false;
            entered.complete();
            await release.future;
          }
          return directory;
        });
    final attempt = background.loadSession();
    final failure =
        expectLater(attempt, throwsA(isA<ExistingDatabaseUnavailable>()));
    await entered.future;
    background.allowForegroundInitialization();
    release.complete();
    await failure;
    expect(await directory.list(recursive: true).toList(), isEmpty);
    expect(await storage.readAll(), isEmpty);
    expect(await background.loadSession(), isNull);
    expect(await storage.readAll(), isNotEmpty);
  });

  test('reset intents and legacy records remain untouched by cold wake',
      () async {
    await store().saveSession(session);
    await closeAll();
    for (final suffix in ['', '.tmp']) {
      final intent =
          File('${directory.path}/veritra-local.reset-intent$suffix');
      await intent.writeAsString('fixture-reset-intent', flush: true);
      await expectLater(store(existingOnly: true).loadSession(),
          throwsA(isA<ExistingDatabaseUnavailable>()));
      expect(await intent.readAsString(), 'fixture-reset-intent');
      await intent.delete();
    }
    await storage.write(
        key: 'veritra.account_state.v2', value: 'fixture-legacy');
    final before = await storage.readAll();
    await expectLater(store(existingOnly: true).loadSession(),
        throwsA(isA<ExistingDatabaseUnavailable>()));
    expect(await storage.readAll(), before);
  });
}
