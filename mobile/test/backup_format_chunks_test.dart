import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/crypto/backup_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'backup_recovery_server.dart';
import 'native_test_env.dart';

/// VBK2 frames are bound to their index and to whether they are last, and
/// nothing may follow the last one: a reordered, duplicated or extra frame,
/// or trailing bytes, fail as a damaged backup and never reach the store.

const _chunk = 1024 * 1024;

class _PlainStore extends MemoryLocalStore {
  _PlainStore(this.plaintext);

  final List<int> plaintext;
  final List<List<int>> restored = <List<int>>[];

  @override
  Future<List<int>> exportBackup() async => List<int>.from(plaintext);

  @override
  Future<void> restoreBackup(List<int> encoded) async {
    restored.add(List<int>.from(encoded));
  }
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
        await Directory.systemTemp.createTemp('veritra-backup-chunks-');
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

  /// Makes a three-chunk backup and returns its code and its frames: the
  /// 24-byte header, then each frame with its 4-byte length.
  Future<(String, List<int>, List<List<int>>)> makeBackup() async {
    final source = _PlainStore(
        List<int>.generate(2 * _chunk + 12345, (i) => (i * 31 + 7) & 0xff));
    await source.saveCryptoState(
      StoredCryptoState(
          counter: 3, stateKey: List<int>.filled(32, 3), sealedState: [1]),
      1,
    );
    final client = ApiClient(baseUrl: server.baseUrl);
    addTearDown(client.close);
    final code = await serviceFor(source).createAndUpload(client, 'token');
    final data = server.stored!;
    final frames = <List<int>>[];
    var offset = 24;
    while (offset < data.length) {
      final length = ByteData.sublistView(
              Uint8List.fromList(data.sublist(offset, offset + 4)))
          .getUint32(0);
      frames.add(data.sublist(offset, offset + 4 + length));
      offset += 4 + length;
    }
    expect(offset, data.length);
    // Header frame, then three data frames.
    expect(frames, hasLength(4));
    return (code, data.sublist(0, 24), frames);
  }

  Future<void> expectRefused(String code, List<int> file) async {
    server.stored = file;
    final target = _PlainStore(const <int>[]);
    await expectLater(
        serviceFor(target).recover(code),
        throwsA(isA<BackupException>()
            .having((error) => error.kind, 'kind', BackupFailureKind.corrupt)));
    expect(target.restored, isEmpty);
  }

  List<int> join(List<int> header, List<List<int>> frames) =>
      <int>[...header, for (final frame in frames) ...frame];

  test('the unchanged frames restore', () async {
    final (code, header, frames) = await makeBackup();
    server.stored = join(header, frames);
    final target = _PlainStore(const <int>[]);
    await serviceFor(target).recover(code);
    expect(target.restored, hasLength(1));
  }, skip: skip);

  test('reordered data frames are refused', () async {
    final (code, header, f) = await makeBackup();
    await expectRefused(code, join(header, [f[0], f[2], f[1], f[3]]));
  }, skip: skip);

  test('a data frame duplicated in place of another is refused', () async {
    final (code, header, f) = await makeBackup();
    await expectRefused(code, join(header, [f[0], f[1], f[1], f[3]]));
  }, skip: skip);

  test('a duplicated last frame after the end is refused', () async {
    final (code, header, f) = await makeBackup();
    await expectRefused(code, join(header, [...f, f[3]]));
  }, skip: skip);

  test('trailing bytes after the last frame are refused', () async {
    final (code, header, f) = await makeBackup();
    await expectRefused(code, [...join(header, f), 0, 0, 0, 1, 7]);
  }, skip: skip);
}
