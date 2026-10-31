import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// A backup carries plain outbox envelopes but not their delivery state, so
/// every restored entry, a backed-off or terminal one included, is
/// deliverable again: no attempts, no backoff, no failure class. Both
/// stores export and restore the same entries.

const _session = Session(
  baseUrl: 'https://chat.example.org',
  token: 'token',
  accountId: 'acct_1',
  deviceId: 'dev_1',
  deviceSecret: 'secret',
);

MessageEnvelope _envelope(String key) => MessageEnvelope(
      conversationId: 'conv_1',
      idempotencyKey: key,
      ciphertext: const <int>[1, 2, 3],
      cryptoProtocol: 'mls10-openmls-v1',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory =
        await Directory.systemTemp.createTemp('veritra-backup-plain-outbox-');
    databases = <EncryptedLocalDatabase>[];
  });

  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    await SecureLocalStore.releaseInstanceLocks();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  SecureLocalStore createStore({String namespace = ''}) => SecureLocalStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
        namespace: namespace,
        databaseFactory: (file, keyHex) {
          final database = openEncryptedLocalDatabase(file, keyHex);
          databases.add(database);
          return database;
        },
      );

  Future<List<int>> backupWithFailures(LocalStore store) async {
    await store.saveSession(_session);
    await store.saveCryptoState(
        StoredCryptoState(
            counter: 1,
            stateKey: List<int>.filled(32, 3),
            sealedState: const <int>[1]),
        10);
    for (final key in ['plain_terminal', 'plain_backoff', 'plain_fresh']) {
      await store.enqueueEnvelope(_envelope(key));
    }
    await store.recordOutboxFailure('plain_terminal',
        failureClass: 'rejected', terminal: true);
    await store.recordOutboxFailure('plain_backoff',
        failureClass: 'network',
        terminal: false,
        nextAttemptAt: DateTime.utc(2030, 1, 2));
    final before = {
      for (final r in await store.pendingEnvelopeRecords())
        r.envelope.idempotencyKey: r
    };
    expect(before['plain_terminal']!.terminal, isTrue);
    expect(before['plain_backoff']!.attemptCount, 1);
    return store.exportBackup();
  }

  void expectDeliverable(List<PendingEnvelopeRecord> restored) {
    expect(restored.map((r) => r.envelope.idempotencyKey),
        unorderedEquals(['plain_terminal', 'plain_backoff', 'plain_fresh']));
    for (final record in restored) {
      expect(record.attemptCount, 0, reason: record.envelope.idempotencyKey);
      expect(record.terminal, isFalse);
      expect(record.nextAttemptAt, isNull);
      expect(record.failureClass, isNull);
    }
  }

  test('restored plain outbox entries are deliverable (encrypted store)',
      () async {
    final backup = await backupWithFailures(createStore());
    final target = createStore(namespace: 'restored');
    await target.restoreBackup(backup);
    expectDeliverable(await target.pendingEnvelopeRecords());
  });

  test('restored plain outbox entries are deliverable (memory store)',
      () async {
    final backup = await backupWithFailures(MemoryLocalStore());
    final target = MemoryLocalStore();
    await target.restoreBackup(backup);
    expectDeliverable(await target.pendingEnvelopeRecords());
  });
}
