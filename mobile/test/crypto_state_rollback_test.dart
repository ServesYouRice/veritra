// TASK-095: a crypto-state save that would not move the counter forward is
// refused in both stores, and the refused save leaves the stored state and
// the sync cursor exactly as they were.

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// Saves counter 4 at cursor 91, then tries an equal counter and a lower
/// one. After each refusal the full state and the cursor must be unchanged.
Future<void> expectRollbackRefused(LocalStore store) async {
  await store.saveCryptoState(
    StoredCryptoState(
      counter: 4,
      stateKey: List<int>.filled(32, 7),
      sealedState: <int>[1, 2, 3],
    ),
    91,
  );

  Future<void> expectUnchanged(String after) async {
    final state = await store.loadCryptoState();
    expect(state?.counter, 4, reason: after);
    expect(state?.stateKey, List<int>.filled(32, 7), reason: after);
    expect(state?.sealedState, <int>[1, 2, 3], reason: after);
    expect(await store.loadSyncCursor(), 91, reason: after);
  }

  for (final (name, counter, cursor) in <(String, int, int)>[
    ('an equal counter', 4, 92),
    ('a lower counter', 3, 93),
  ]) {
    await expectLater(
      store.saveCryptoState(
        StoredCryptoState(
          counter: counter,
          stateKey: List<int>.filled(32, 8),
          sealedState: <int>[counter],
        ),
        cursor,
      ),
      throwsStateError,
      reason: name,
    );
    await expectUnchanged('after $name');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('memory store refuses an equal or lower counter and keeps its state',
      () => expectRollbackRefused(MemoryLocalStore()));

  group('encrypted store', () {
    late Directory directory;
    late List<EncryptedLocalDatabase> databases;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      directory = await Directory.systemTemp.createTemp('veritra-rollback-');
      databases = <EncryptedLocalDatabase>[];
    });

    tearDown(() async {
      for (final database in databases) {
        await database.close();
      }
      await SecureLocalStore.releaseInstanceLocks();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('refuses an equal or lower counter and keeps its state', () async {
      final store = SecureLocalStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
        databaseFactory: (file, keyHex) {
          final database = openEncryptedLocalDatabase(file, keyHex);
          databases.add(database);
          return database;
        },
      );
      await expectRollbackRefused(store);
    });
  });
}
