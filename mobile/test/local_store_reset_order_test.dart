import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// A reset of the local database runs under the same serialization and
/// profile locks as opening it (TASK-080): no handle of the store is open on
/// the files it moves, an open requested meanwhile sees only the files left
/// after it, and a profile another process owns is never reset.

/// Logs its open and close, and can hold its first read or its close.
class _RecordingDatabase extends EncryptedLocalDatabase {
  _RecordingDatabase(QueryExecutor executor, this.id, this.log, this.file)
      : super(executor);

  final int id;
  final List<String> log;
  final File file;
  Completer<void>? readGate;
  Completer<void>? closeGate;

  @override
  Future<int> readCursor() async {
    final gate = readGate;
    readGate = null;
    if (gate != null) await gate.future;
    return super.readCursor();
  }

  @override
  Future<void> close() async {
    // Where the database file is when this handle lets go of it.
    log.add('close#$id ${file.existsSync() ? 'in-place' : 'moved'}');
    final gate = closeGate;
    closeGate = null;
    if (gate != null) await gate.future;
    await super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;
  late List<String> log;
  late List<_RecordingDatabase> opened;
  Completer<void>? directoryGate;
  Completer<void>? nextReadGate;
  const storage = FlutterSecureStorage();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-reset-order-');
    databases = <EncryptedLocalDatabase>[];
    log = <String>[];
    opened = <_RecordingDatabase>[];
    directoryGate = null;
    nextReadGate = null;
  });

  tearDown(() async {
    for (final database in databases) {
      try {
        await database.close();
      } catch (_) {}
    }
    await SecureLocalStore.releaseInstanceLocks();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  bool resetDone() =>
      !File('${directory.path}/veritra-local.reset-intent').existsSync() &&
      directory
          .listSync()
          .whereType<Directory>()
          .any((item) => item.path.contains('unreadable-'));

  SecureLocalStore recordingStore() => SecureLocalStore(
        storage: storage,
        directoryProvider: () async {
          final gate = directoryGate;
          if (gate != null) await gate.future;
          return directory;
        },
        databaseFactory: (file, keyHex) {
          final id = opened.length;
          final database = _RecordingDatabase(
              openEncryptedLocalDatabase(file, keyHex).executor, id, log, file)
            ..readGate = nextReadGate;
          nextReadGate = null;
          opened.add(database);
          databases.add(database);
          // Whether this open sees the files left after a finished reset.
          log.add('open#$id ${resetDone() ? 'after-reset' : 'before-reset'}');
          return database;
        },
      );

  Future<void> seedClosed() async {
    final seed = SecureLocalStore(
      storage: storage,
      directoryProvider: () async => directory,
      databaseFactory: (file, keyHex) {
        final database = openEncryptedLocalDatabase(file, keyHex);
        databases.add(database);
        return database;
      },
    );
    await seed.saveSyncCursor(4);
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test('an open requested before the reset takes its locks waits for it',
      () async {
    final store = recordingStore();
    await store.saveSyncCursor(4);
    expect(log, <String>['open#0 before-reset']);

    // Hold the reset before it reaches the profile locks.
    final gate = directoryGate = Completer<void>();
    final reset = store.quarantineUnreadableDatabase(confirmed: true);
    await settle();
    final gapRead = store.loadSyncCursor();
    await settle();
    directoryGate = null;
    gate.complete();

    await reset;
    // The caller in the gap gets a handle opened on the new files.
    expect(await gapRead, 0);
    expect(await store.loadSyncCursor(), 0);
    expect(log, <String>[
      'open#0 before-reset',
      'close#0 in-place',
      'open#1 after-reset',
    ]);
    expect(opened, hasLength(2));
  });

  test('a reset requested while an open runs waits for that open', () async {
    await seedClosed();
    final store = recordingStore();
    final gate = nextReadGate = Completer<void>();
    final read = store.loadSyncCursor();
    await settle();
    expect(log, <String>['open#0 before-reset']);

    final reset = store.quarantineUnreadableDatabase(confirmed: true);
    await settle();
    // The open still holds the profile: nothing has moved.
    expect(File('${directory.path}/veritra-local.reset-intent').existsSync(),
        isFalse);
    expect(File('${directory.path}/veritra-local.db').existsSync(), isTrue);

    gate.complete();
    expect(await read, 4);
    await reset;
    expect(await store.loadSyncCursor(), 0);
    expect(log, <String>[
      'open#0 before-reset',
      'close#0 in-place',
      'open#1 after-reset',
    ]);
  });

  test('an open requested while a reset runs waits for the reset', () async {
    final store = recordingStore();
    await store.saveSyncCursor(4);
    final gate = opened.single.closeGate = Completer<void>();

    final reset = store.quarantineUnreadableDatabase(confirmed: true);
    await settle();
    expect(log, <String>['open#0 before-reset', 'close#0 in-place']);
    final read = store.loadSyncCursor();
    await settle();
    // No second handle while the reset holds the profile.
    expect(opened, hasLength(1));

    gate.complete();
    await reset;
    expect(await read, 0);
    expect(log, <String>[
      'open#0 before-reset',
      'close#0 in-place',
      'open#1 after-reset',
    ]);
  });

  test('a profile another process owns is not reset', () async {
    await seedClosed();
    await SecureLocalStore.releaseInstanceLocks();
    final original =
        await File('${directory.path}/veritra-local.db').readAsBytes();
    final key = await storage.read(key: 'veritra.database_key.v1');

    // A POSIX record lock, the kind RandomAccessFile.lock takes, held by
    // another process.
    final owner = await Process.start('python3', <String>[
      '-c',
      'import fcntl, sys\n'
          'f = open(sys.argv[1], "a")\n'
          'fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)\n'
          'print("locked", flush=True)\n'
          'sys.stdin.read()\n',
      '${directory.path}/veritra-instance.lock',
    ]);
    addTearDown(() async {
      owner.kill();
      await owner.exitCode;
    });
    final lines =
        owner.stdout.transform(utf8.decoder).transform(const LineSplitter());
    expect(await lines.first.timeout(const Duration(seconds: 20)), 'locked');

    final refused = isA<LocalStoreUnavailableException>().having(
        (error) => error.kind, 'kind', LocalStoreFailureKind.profileLocked);
    // Control: an open is refused, so the two lock kinds do meet.
    await expectLater(recordingStore().loadSyncCursor(), throwsA(refused));

    await expectLater(
        recordingStore().quarantineUnreadableDatabase(confirmed: true),
        throwsA(refused));
    expect(await File('${directory.path}/veritra-local.db').readAsBytes(),
        original);
    expect(File('${directory.path}/veritra-local.reset-intent').existsSync(),
        isFalse);
    expect(
        directory.listSync().where((item) => item.path.contains('unreadable-')),
        isEmpty);
    expect(await storage.read(key: 'veritra.database_key.v1'), key);
  },
      skip: Platform.isLinux || Platform.isMacOS
          ? false
          : 'needs python3 and POSIX record locks');
}
