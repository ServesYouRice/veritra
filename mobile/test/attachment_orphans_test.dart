// A process killed during an attachment encryption or opening leaves
// plaintext and ciphertext working files behind; a sweep at start removes
// them without touching anything else in the shared directory (TASK-050).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

class _NoBindings implements NativeCryptoBindings {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 32 hex characters, as `.attachment-` names carry (16 random bytes).
const _id32 = '0123456789abcdef0123456789abcdef';
const _id16 = '89abcdef01234567';

void main() {
  late Directory dir;
  late AttachmentCryptoService service;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('attachment_orphans_test_');
    service = AttachmentCryptoService(
      _NoBindings(),
      directoryProvider: () async => dir,
    );
  });

  tearDown(() => dir.delete(recursive: true));

  Future<File> seed(String name,
      {Duration age = const Duration(hours: 5)}) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(<int>[1, 2, 3]);
    await file.setLastModified(DateTime.now().subtract(age));
    return file;
  }

  test('old attachment working files are deleted', () async {
    final orphans = <File>[
      await seed('.attachment-$_id32.ciphertext'),
      await seed('.veritra-attachment-$_id32.ciphertext'),
      await seed('.veritra-attachment-$_id32.plaintext'),
      await seed('.veritra-attachment-$_id32.plaintext.part'),
      await seed('.veritra-attachment-$_id16.plaintext.part'),
    ];
    await service.cleanupOrphans();
    for (final file in orphans) {
      expect(await file.exists(), isFalse, reason: file.path);
    }
  });

  test('a file that may belong to a running operation is kept', () async {
    final recent = await seed(
      '.veritra-attachment-$_id32.plaintext.part',
      age: const Duration(minutes: 5),
    );
    final upload = await seed(
      '.attachment-$_id32.ciphertext',
      age: const Duration(minutes: 59),
    );
    await service.cleanupOrphans();
    expect(await recent.exists(), isTrue);
    expect(await upload.exists(), isTrue);
    // The threshold can be given.
    await service.cleanupOrphans(minAge: const Duration(minutes: 1));
    expect(await recent.exists(), isFalse);
    expect(await upload.exists(), isFalse);
  });

  test('recovery, backup, database and key files are never touched', () async {
    final protected = <File>[
      await seed('.veritra-recovery.partial', age: const Duration(days: 30)),
      await seed('.abcdef0123456789abcdef01.backup-ciphertext',
          age: const Duration(days: 30)),
      await seed('veritra.sqlite', age: const Duration(days: 30)),
      await seed('veritra.sqlite-wal', age: const Duration(days: 30)),
      await seed('key.bin', age: const Duration(days: 30)),
      // Names that only look similar.
      await seed('.attachment-$_id32.txt', age: const Duration(days: 30)),
      await seed('.attachment-xyz.ciphertext', age: const Duration(days: 30)),
      await seed('attachment-$_id32.ciphertext', age: const Duration(days: 30)),
      await seed('.veritra-attachment-$_id32.plaintext.part.bak',
          age: const Duration(days: 30)),
      await seed('.veritra-attachment-.ciphertext',
          age: const Duration(days: 30)),
      await seed('.veritra-attachment-$_id32', age: const Duration(days: 30)),
    ];
    await service.cleanupOrphans();
    for (final file in protected) {
      expect(await file.exists(), isTrue, reason: file.path);
    }
  });

  test('a directory with an orphan-like name is not removed', () async {
    final directory =
        Directory('${dir.path}/.veritra-attachment-$_id32.plaintext');
    await directory.create();
    await File('${directory.path}/inner').writeAsBytes(<int>[1]);
    await service.cleanupOrphans();
    expect(await directory.exists(), isTrue);
    expect(await File('${directory.path}/inner').exists(), isTrue);
  });

  test('a missing directory or provider failure is not an error', () async {
    await dir.delete(recursive: true);
    await service.cleanupOrphans();
    await dir.create();

    final failing = AttachmentCryptoService(
      _NoBindings(),
      directoryProvider: () async => throw const FileSystemException('gone'),
    );
    await failing.cleanupOrphans();
  });
}
