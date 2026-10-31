import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// MLS outbox delivery state (attempts, backoff, failure class, terminal)
/// survives a backup round trip; an older backup without it restores the
/// defaults (TASK-084).

StoredCryptoState _state(int counter) => StoredCryptoState(
      counter: counter,
      stateKey: List<int>.filled(32, 3),
      sealedState: <int>[counter, 1, 2],
    );

const _session = Session(
  baseUrl: 'https://chat.example.org',
  token: 'token',
  accountId: 'acct_1',
  deviceId: 'dev_1',
  deviceSecret: 'secret',
);

PendingMlsMessage _message(String key) => PendingMlsMessage(
      idempotencyKey: key,
      conversationId: 'conv_1',
      kind: 'commit',
      payload: <int>[1, 2, 3],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-backup-store-');
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

  Map<String, Object?> decode(List<int> backup) =>
      Map<String, Object?>.from(jsonDecode(utf8.decode(backup)) as Map);

  Future<List<int>> backupWithDeliveryState(LocalStore store) async {
    await store.saveSession(_session);
    await store.saveCryptoState(_state(1), 10);
    await store.commitOutgoingMlsTransition(OutgoingMlsStateTransition(
      expectedCounter: 1,
      expectedCursor: 10,
      state: _state(2),
      messages: <PendingMlsMessage>[
        _message('mls_terminal'),
        _message('mls_backoff'),
        _message('mls_fresh'),
      ],
    ));
    await store.recordMlsOutboxFailure('mls_terminal',
        failureClass: 'rejected', terminal: true);
    final retryAt = DateTime.utc(2030, 1, 2, 3, 4, 5);
    await store.recordMlsOutboxFailure('mls_backoff',
        failureClass: 'network', terminal: false, nextAttemptAt: retryAt);
    await store.recordMlsOutboxFailure('mls_backoff',
        failureClass: 'network', terminal: false, nextAttemptAt: retryAt);
    return store.exportBackup();
  }

  void expectDeliveryState(List<PendingMlsMessage> restored) {
    final byKey = {for (final item in restored) item.idempotencyKey: item};
    expect(byKey.keys, <String>['mls_terminal', 'mls_backoff', 'mls_fresh']);
    final terminal = byKey['mls_terminal']!;
    expect(terminal.terminal, isTrue);
    expect(terminal.attemptCount, 1);
    expect(terminal.failureClass, 'rejected');
    expect(terminal.nextAttemptAt, isNull);
    final backoff = byKey['mls_backoff']!;
    expect(backoff.terminal, isFalse);
    expect(backoff.attemptCount, 2);
    expect(backoff.failureClass, 'network');
    expect(backoff.nextAttemptAt, DateTime.utc(2030, 1, 2, 3, 4, 5));
    final fresh = byKey['mls_fresh']!;
    expect(fresh.terminal, isFalse);
    expect(fresh.attemptCount, 0);
    expect(fresh.failureClass, isNull);
    expect(fresh.nextAttemptAt, isNull);
  }

  test('MLS outbox delivery state survives a backup (encrypted store)',
      () async {
    final backup = await backupWithDeliveryState(createStore());
    final target = createStore(namespace: 'restored');
    await target.restoreBackup(backup);
    expectDeliveryState(await target.pendingMlsMessages());
  });

  test('MLS outbox delivery state survives a backup (memory store)', () async {
    final backup = await backupWithDeliveryState(MemoryLocalStore());
    final target = MemoryLocalStore();
    await target.restoreBackup(backup);
    expectDeliveryState(await target.pendingMlsMessages());
  });

  List<int> rewriteOutbox(
      List<int> backup, void Function(Map<String, Object?> item) change) {
    final root = decode(backup);
    final items = <Map<String, Object?>>[
      for (final item in root['mls_outbox'] as List)
        Map<String, Object?>.from(item as Map)
    ];
    items.forEach(change);
    root['mls_outbox'] = items;
    return utf8.encode(jsonEncode(root));
  }

  test('a backup without delivery state restores the defaults', () async {
    final backup = await backupWithDeliveryState(MemoryLocalStore());
    final older = rewriteOutbox(backup, (item) {
      item
        ..remove('attempt_count')
        ..remove('next_attempt_at')
        ..remove('failure_class')
        ..remove('terminal');
    });
    for (final target in <LocalStore>[
      MemoryLocalStore(),
      createStore(namespace: 'older'),
    ]) {
      await target.restoreBackup(older);
      final restored = await target.pendingMlsMessages();
      expect(restored, hasLength(3));
      for (final item in restored) {
        expect(item.attemptCount, 0);
        expect(item.nextAttemptAt, isNull);
        expect(item.failureClass, isNull);
        expect(item.terminal, isFalse);
      }
    }
  });

  test('malformed delivery state is refused, not guessed', () async {
    final backup = await backupWithDeliveryState(MemoryLocalStore());
    for (final change in <void Function(Map<String, Object?>)>[
      (item) => item['attempt_count'] = -1,
      (item) => item['attempt_count'] = '2',
      (item) => item['next_attempt_at'] = '2030-01-01',
      (item) => item['failure_class'] = 7,
      (item) => item['terminal'] = 'yes',
    ]) {
      await expectLater(
          MemoryLocalStore().restoreBackup(rewriteOutbox(backup, change)),
          throwsFormatException);
    }
  });
}
