import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/backup_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'backup_recovery_server.dart';
import 'native_test_env.dart';

/// A finished recovery download is the only copy of a backup once its
/// transfer used up the code, so it is not aged out like an orphaned upload
/// file: a retry days later still restores it.

const _partialName = '.veritra-recovery.partial';

Future<MemoryLocalStore> _seededStore() async {
  final store = MemoryLocalStore();
  await store.saveSession(const Session(
    baseUrl: 'https://chat.example.org',
    token: 'token',
    accountId: 'acct_1',
    deviceId: 'dev_1',
    deviceSecret: 'secret',
  ));
  await store.saveCryptoState(
    StoredCryptoState(
      counter: 1,
      stateKey: List<int>.filled(32, 3),
      sealedState: const <int>[1, 2, 3],
    ),
    6,
  );
  return store;
}

void main() {
  final skip = nativeCryptoSkip();

  late BackupRecoveryServer server;
  late Directory scratch;
  late NativeCryptoBindings bindings;
  BackupRecoveryServer? startedServer;
  Directory? createdScratch;

  setUp(() async {
    startedServer = null;
    createdScratch = null;
    if (skip != false) return;
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    server = startedServer = await BackupRecoveryServer.start();
    scratch = createdScratch =
        await Directory.systemTemp.createTemp('veritra-backup-partial-age-');
  });

  tearDown(() async {
    await startedServer?.close();
    final directory = createdScratch;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  BackupService serviceFor(LocalStore store) => BackupService(
        bindings: bindings,
        localStore: store,
        directoryProvider: () async => scratch,
      );

  Future<(String, List<int>)> makeBackup() async {
    final client = ApiClient(baseUrl: server.baseUrl);
    addTearDown(client.close);
    final code =
        await serviceFor(await _seededStore()).createAndUpload(client, 't');
    return (code, List<int>.from(server.stored!));
  }

  File partial() => File('${scratch.path}/$_partialName');
  final old = DateTime.now().subtract(const Duration(hours: 25));

  test('a complete download older than a day still restores', () async {
    final (code, ciphertext) = await makeBackup();
    partial()
      ..writeAsBytesSync(ciphertext)
      ..setLastModifiedSync(old);
    server.stored = null;
    final target = MemoryLocalStore();
    await serviceFor(target).recover(code);
    expect((await target.loadSession())?.deviceId, 'dev_1');
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('making a backup does not age out a kept recovery download', () async {
    partial()
      ..writeAsBytesSync(const <int>[1, 2, 3])
      ..setLastModifiedSync(old);
    final orphan = File('${scratch.path}/.0123.backup-ciphertext')
      ..writeAsBytesSync(const <int>[4, 5, 6])
      ..setLastModifiedSync(old);
    await makeBackup();
    expect(partial().existsSync(), isTrue);
    expect(orphan.existsSync(), isFalse);
  }, skip: skip);
}
