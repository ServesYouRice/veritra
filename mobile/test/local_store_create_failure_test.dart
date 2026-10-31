import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

/// A first create that fails (the disk filled, say) leaves an empty
/// version-0 file. The next open runs the create again; when that fails
/// too, it failed after the key opened the file, so it is an upgrade
/// failure, never a rejected key whose reset would delete the legacy record.

final _keyA = 'ab' * 32;
final _keyB = 'cd' * 32;

/// An encrypted, version-0 file holding only an index that takes a history
/// table's name, so onCreate fails after createAll() has already run.
void _seedPoisonedFile(File file, String keyHex) {
  final raw = sqlite3.open(file.path);
  try {
    raw.execute("PRAGMA cipher = 'chacha20'");
    raw.execute("PRAGMA hexkey = '$keyHex'");
    raw.execute('CREATE TABLE poison (x INTEGER)');
    raw.execute('CREATE INDEX local_history_imports ON poison(x)');
  } finally {
    raw.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('veritra-create-fail-');
    file = File('${directory.path}/veritra-local.db');
  });
  tearDown(() async {
    await SecureLocalStore.releaseInstanceLocks();
    await directory.delete(recursive: true);
  });

  test('a wrong key fails before onCreate runs on a non-empty file', () async {
    _seedPoisonedFile(file, _keyA);

    final wrong = openEncryptedLocalDatabase(file, _keyB);
    await expectLater(wrong.readCursor(), throwsA(anything));
    expect(wrong.createStarted, isFalse);
    expect(wrong.upgradeStarted, isFalse);
    try {
      await wrong.close();
    } catch (_) {}

    // Control: the right key reaches onCreate on the same file.
    final right = openEncryptedLocalDatabase(file, _keyA);
    await expectLater(right.readCursor(), throwsA(anything));
    expect(right.createStarted, isTrue);
    try {
      await right.close();
    } catch (_) {}
  });

  test('a create that fails again is an upgrade failure, not a wrong key',
      () async {
    _seedPoisonedFile(file, _keyA);
    const legacy = '{"legacy":"record"}';
    FlutterSecureStorage.setMockInitialValues({
      'veritra.database_key.v1': _keyA,
      'veritra.account_state.v2': legacy,
    });
    const storage = FlutterSecureStorage();
    final store = SecureLocalStore(
      storage: storage,
      directoryProvider: () async => directory,
    );
    await expectLater(
        store.loadSession(),
        throwsA(isA<LocalStoreUnavailableException>().having(
            (e) => e.kind, 'kind', LocalStoreFailureKind.upgradeFailed)));
    expect(await storage.read(key: 'veritra.account_state.v2'), legacy);
    expect(await storage.read(key: 'veritra.database_key.v1'), _keyA);
    expect(file.existsSync(), isTrue);
  });
}
