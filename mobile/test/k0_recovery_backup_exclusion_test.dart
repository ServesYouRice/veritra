import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/account_recovery.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// K0 design, client flow step 4 and D71: the waiting recovery claim (claim
/// token, device secret, sealed MLS state and its key) lives in the
/// encrypted local store only, and a backup never carries it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const claimToken = 'claim-SENTINEL-k0r4-token';
  const deviceSecret = 'secret-SENTINEL-k0r4-device';
  final stateKey = List<int>.generate(32, (i) => 0xC0 + (i % 16));
  final sealed = utf8.encode('sealed-SENTINEL-k0r4-mls');

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-k0r4-');
    databases = <EncryptedLocalDatabase>[];
  });

  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    await SecureLocalStore.releaseInstanceLocks();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('the pending claim never reaches a backup', () async {
    final store = SecureLocalStore(
      storage: const FlutterSecureStorage(),
      directoryProvider: () async => directory,
      databaseFactory: (file, keyHex) {
        final database = openEncryptedLocalDatabase(file, keyHex);
        databases.add(database);
        return database;
      },
    );
    // A backup needs a signed-in device: here one that still holds a claim
    // record (export reads no settings at all, so any state shows it).
    await store.saveSession(const Session(
        baseUrl: 'https://chat.example.org',
        token: 'tok',
        accountId: 'acct_me',
        deviceId: 'dev_old',
        username: 'alice',
        deviceSecret: 'old-secret'));
    await store.saveCryptoState(
        StoredCryptoState(
            counter: 1,
            stateKey: List<int>.filled(32, 1),
            sealedState: utf8.encode('device-state')),
        0);
    await store.saveSnapshot(
        <Conversation>[Conversation(id: 'conv_1', kind: 'dm', title: 'Chat')],
        const <String, List<ReceivedMessageEnvelope>>{},
        0);
    final pending = PendingAccountRecovery(
      origin: 'https://chat.example.org',
      username: 'alice',
      accountId: 'acct_me',
      deviceId: 'dev_new',
      deviceName: 'Phone',
      requestId: 'arr_1',
      claimToken: claimToken,
      deviceSecret: deviceSecret,
      readyAt: DateTime.utc(2026, 11, 8),
      mlsState: StoredCryptoState(
          counter: 1, stateKey: stateKey, sealedState: sealed),
    );
    await store.savePendingEnrollment(pending.toEnrollment());
    expect(
        PendingAccountRecovery.fromEnrollment(
                await store.loadPendingEnrollment())
            ?.claimToken,
        claimToken);

    final backup = utf8.decode(await store.exportBackup());
    for (final forbidden in <String>[
      claimToken,
      deviceSecret,
      'dev_new',
      'arr_1',
      'k0.pending_recovery',
      base64Encode(stateKey),
      base64Encode(sealed),
      utf8.decode(sealed),
    ]) {
      expect(backup, isNot(contains(forbidden)), reason: forbidden);
    }
    // The backup still holds what it is for.
    expect(backup, contains('acct_me'));
  });
}
