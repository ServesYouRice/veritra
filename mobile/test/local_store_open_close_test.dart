import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

class _FailingOpenDatabase extends EncryptedLocalDatabase {
  _FailingOpenDatabase() : super(NativeDatabase.memory());

  bool closed = false;

  @override
  Future<int> readCursor() async => throw StateError('open failed');

  @override
  Future<void> close() {
    closed = true;
    return super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late List<_FailingOpenDatabase> opened;

  SecureLocalStore store() => SecureLocalStore(
      storage: const FlutterSecureStorage(),
      directoryProvider: () async => directory,
      databaseFactory: (file, key) {
        final db = _FailingOpenDatabase();
        opened.add(db);
        return db;
      });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('veritra-open-close-');
    opened = [];
  });
  tearDown(() async {
    await SecureLocalStore.releaseInstanceLocks();
    await directory.delete(recursive: true);
  });

  test('a failed open of a new database closes its handle', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await expectLater(store().loadSession(), throwsA(isA<StateError>()));
    expect(opened, hasLength(1));
    expect(opened.single.closed, isTrue);
  });

  test('a rejected key closes the handle of an existing database', () async {
    FlutterSecureStorage.setMockInitialValues(
        {'veritra.database_key.v1': 'ab' * 32});
    await File('${directory.path}/veritra-local.db').writeAsBytes([1, 2, 3]);
    await expectLater(
        store().loadSession(),
        throwsA(isA<LocalStoreUnavailableException>()
            .having((e) => e.kind, 'kind', LocalStoreFailureKind.keyRejected)));
    expect(opened, hasLength(1));
    expect(opened.single.closed, isTrue);
  });
}
