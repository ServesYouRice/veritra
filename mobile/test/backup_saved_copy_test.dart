import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/backup_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'backup_recovery_server.dart';
import 'native_test_env.dart';

/// The saved recovery download may be the only copy of a backup once its
/// transfer used up the code. A mistyped code, a saved prefix from another
/// code, or an unexpected server answer must not destroy it.

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
        await Directory.systemTemp.createTemp('veritra-backup-saved-copy-');
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

  Matcher failure(BackupFailureKind kind) =>
      isA<BackupException>().having((error) => error.kind, 'kind', kind);

  String withWrongKey(String code) {
    final parts = code.split('.');
    return '${parts[0]}.${parts[1]}.${parts[2]}.${'A' * parts[3].length}';
  }

  test('a mistyped key keeps a complete saved file the code no longer reaches',
      () async {
    final (code, ciphertext) = await makeBackup();
    partial().writeAsBytesSync(ciphertext);
    // The transfer that saved it used up the code.
    server.stored = null;
    final target = MemoryLocalStore();
    await expectLater(serviceFor(target).recover(withWrongKey(code)),
        throwsA(failure(BackupFailureKind.wrongKey)));
    expect(partial().readAsBytesSync(), ciphertext);
    expect(await target.loadSession(), isNull);

    // The corrected code still restores the kept copy.
    await serviceFor(target).recover(code);
    expect((await target.loadSession())?.deviceId, 'dev_1');
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('a saved prefix of another code is not continued with this code',
      () async {
    final (_, other) = await makeBackup();
    final (code, _) = await makeBackup();
    // An interrupted download for another code, long enough to hold frame 0.
    partial().writeAsBytesSync(other.sublist(0, 100));
    server.consumeOnComplete = true;
    final target = MemoryLocalStore();
    await serviceFor(target).recover(code);
    expect((await target.loadSession())?.deviceId, 'dev_1');
    // No range request: this code's tail never lands on the other prefix.
    expect(server.rangeStarts, <int>[0]);
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('a saved prefix whose frame 0 opens is continued', () async {
    final (code, ciphertext) = await makeBackup();
    partial().writeAsBytesSync(ciphertext.sublist(0, 100));
    server.consumeOnComplete = true;
    final target = MemoryLocalStore();
    await serviceFor(target).recover(code);
    expect((await target.loadSession())?.deviceId, 'dev_1');
    expect(server.rangeStarts, <int>[100]);
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  for (final status in <int>[400, 403, 407]) {
    test('an unexpected $status keeps the saved download for a retry',
        () async {
      final (code, ciphertext) = await makeBackup();
      partial().writeAsBytesSync(ciphertext.sublist(0, 100));
      // As from a proxy or captive portal in front of the server.
      server.recoveryStatus = status;
      final target = MemoryLocalStore();
      await expectLater(serviceFor(target).recover(code),
          throwsA(failure(BackupFailureKind.network)));
      expect(partial().readAsBytesSync(), ciphertext.sublist(0, 100));

      server.recoveryStatus = null;
      await serviceFor(target).recover(code);
      expect((await target.loadSession())?.deviceId, 'dev_1');
      expect(scratch.listSync(), isEmpty);
    }, skip: skip);
  }

  test('interrupted download, then key typo, then corrected key restores',
      () async {
    final (code, ciphertext) = await makeBackup();
    // A download the right code started, stopped at 90%.
    partial()
        .writeAsBytesSync(ciphertext.sublist(0, ciphertext.length * 9 ~/ 10));
    server.consumeOnComplete = true;
    final target = MemoryLocalStore();
    await expectLater(serviceFor(target).recover(withWrongKey(code)),
        throwsA(failure(BackupFailureKind.wrongKey)));
    // The whole transfer used up the code; the file is its only copy.
    expect(server.stored, isNull);
    expect(partial().readAsBytesSync(), ciphertext);

    await serviceFor(target).recover(code);
    expect((await target.loadSession())?.deviceId, 'dev_1');
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('a first attempt with a key typo keeps the download', () async {
    final (code, ciphertext) = await makeBackup();
    server.consumeOnComplete = true;
    final target = MemoryLocalStore();
    await expectLater(serviceFor(target).recover(withWrongKey(code)),
        throwsA(failure(BackupFailureKind.wrongKey)));
    expect(server.stored, isNull);
    expect(partial().readAsBytesSync(), ciphertext);

    await serviceFor(target).recover(code);
    expect((await target.loadSession())?.deviceId, 'dev_1');
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('a storage failure keeps the saved download', () async {
    final (code, ciphertext) = await makeBackup();
    final prefix = ciphertext.sublist(0, 100);
    partial().writeAsBytesSync(prefix);
    if (!await _makeUnwritable(partial())) {
      markTestSkipped('cannot make a file unwritable here');
      return;
    }
    addTearDown(() => _makeWritable(partial()));
    final target = MemoryLocalStore();
    await expectLater(serviceFor(target).recover(code),
        throwsA(failure(BackupFailureKind.storage)));
    await _makeWritable(partial());
    expect(partial().readAsBytesSync(), prefix);

    await serviceFor(target).recover(code);
    expect((await target.loadSession())?.deviceId, 'dev_1');
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('a malformed answer to a range request restarts from byte 0', () async {
    final (code, ciphertext) = await makeBackup();
    partial().writeAsBytesSync(ciphertext.sublist(0, 100));
    server.omitContentRange = true;
    final target = MemoryLocalStore();
    await serviceFor(target).recover(code);
    expect((await target.loadSession())?.deviceId, 'dev_1');
    expect(server.rangeStarts, <int>[100, 0]);
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('a malformed answer from byte 0 is a network error and keeps the file',
      () async {
    final (_, other) = await makeBackup();
    final (code, _) = await makeBackup();
    final saved = other.sublist(0, 100);
    partial().writeAsBytesSync(saved);
    // A 2xx that is not the 200 an unranged request needs.
    server.recoveryStatus = 203;
    final target = MemoryLocalStore();
    await expectLater(serviceFor(target).recover(code),
        throwsA(failure(BackupFailureKind.network)));
    expect(server.rangeStarts, <int>[0]);
    expect(partial().readAsBytesSync(), saved);
  }, skip: skip);
}

/// Makes appending to [file] fail: read-only for a normal user, immutable
/// for root (which ignores the mode bits). False if neither works here.
Future<bool> _makeUnwritable(File file) async {
  final root = (await Process.run('id', ['-u'])).stdout.toString().trim();
  try {
    await Process.run(root == '0' ? 'chattr' : 'chmod',
        [root == '0' ? '+i' : '444', file.path]);
  } on ProcessException {
    return false;
  }
  try {
    file.openSync(mode: FileMode.append).closeSync();
    return false;
  } on FileSystemException {
    return true;
  }
}

Future<void> _makeWritable(File file) async {
  if (!file.existsSync()) return;
  try {
    await Process.run('chattr', ['-i', file.path]);
  } on ProcessException {
    // Not root, or no chattr: the mode bits are enough.
  }
  await Process.run('chmod', ['644', file.path]);
}
