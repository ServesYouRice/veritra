import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// The plaintext backup a store exports (I45) holds one consistent state
/// even while MLS commits land (TASK-083).

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

/// Can hold an export after its MLS state read.
class _HoldingDatabase extends EncryptedLocalDatabase {
  _HoldingDatabase(QueryExecutor executor) : super(executor);

  Completer<void>? _gate;
  Completer<void> _reached = Completer<void>();

  Future<void> get cryptoReadHeld => _reached.future;

  Completer<void> holdNextCryptoRead() {
    _reached = Completer<void>();
    return _gate = Completer<void>();
  }

  @override
  Future<({int counter, List<int> stateKey, List<int> sealedState})?>
      readCryptoState() async {
    final state = await super.readCryptoState();
    final gate = _gate;
    _gate = null;
    if (gate != null) {
      _reached.complete();
      await gate.future;
    }
    return state;
  }
}

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

  Map<String, Object?> decode(List<int> backup) =>
      Map<String, Object?>.from(jsonDecode(utf8.decode(backup)) as Map);

  test('a backup taken while MLS commits land holds one committed state',
      () async {
    // Holds the export right after it read the MLS state, so a commit can
    // try to land between that read and the cursor and outbox reads.
    final held = <_HoldingDatabase>[];
    final store = SecureLocalStore(
      storage: const FlutterSecureStorage(),
      directoryProvider: () async => directory,
      databaseFactory: (file, keyHex) {
        final database =
            _HoldingDatabase(openEncryptedLocalDatabase(file, keyHex).executor);
        held.add(database);
        databases.add(database);
        return database;
      },
    );
    await store.saveSession(_session);
    await store.saveCryptoState(_state(1), 10);
    final database = held.single;

    for (final outgoing in <bool>[false, true]) {
      final counter = (await store.loadCryptoState())!.counter;
      final cursor = await store.loadSyncCursor();
      final gate = database.holdNextCryptoRead();
      final export = store.exportBackup();
      await database.cryptoReadHeld;
      final commit = outgoing
          ? store.commitOutgoingMlsTransition(OutgoingMlsStateTransition(
              expectedCounter: counter,
              expectedCursor: cursor,
              state: _state(counter + 1),
              messages: <PendingMlsMessage>[_message('mls_$counter')],
            ))
          : store.commitMlsTransition(MlsStateTransition(
              messageId: 'application:${cursor + 1}:srv_$counter',
              conversationId: 'conv_1',
              expectedCounter: counter,
              expectedCursor: cursor,
              state: _state(counter + 1),
              cursor: cursor + 1,
            ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.complete();
      final backup = decode(await export);
      await commit;

      // The export read the state before the commit, so all of it is from
      // before: the counter, the cursor and the queued MLS messages.
      expect((backup['crypto_state'] as Map)['counter'], counter);
      expect(backup['cursor'], cursor);
      expect(
          (backup['mls_outbox'] as List).length, counter - 1 - (cursor - 10));
    }
  });
}
