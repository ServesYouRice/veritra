// A process killed during an attachment encryption or opening leaves
// plaintext and ciphertext working files behind; a sweep at start removes
// them without touching anything else in the shared directory (TASK-050).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/attachments.dart';

/// 32 hex characters, as `.attachment-` names carry (16 random bytes).
const _id32 = '0123456789abcdef0123456789abcdef';
const _id16 = '89abcdef01234567';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('attachment_orphans_test_');
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
    await cleanupAttachmentOrphans(dir);
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
    await cleanupAttachmentOrphans(dir);
    expect(await recent.exists(), isTrue);
    expect(await upload.exists(), isTrue);
    // The threshold can be given.
    await cleanupAttachmentOrphans(dir, minAge: const Duration(minutes: 1));
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
    await cleanupAttachmentOrphans(dir);
    for (final file in protected) {
      expect(await file.exists(), isTrue, reason: file.path);
    }
  });

  test('a directory with an orphan-like name is not removed', () async {
    final directory =
        Directory('${dir.path}/.veritra-attachment-$_id32.plaintext');
    await directory.create();
    await File('${directory.path}/inner').writeAsBytes(<int>[1]);
    await cleanupAttachmentOrphans(dir);
    expect(await directory.exists(), isTrue);
    expect(await File('${directory.path}/inner').exists(), isTrue);
  });

  test('a missing directory is not an error', () async {
    await dir.delete(recursive: true);
    await cleanupAttachmentOrphans(dir);
    await dir.create();
  });

  group('while the app runs', () {
    // Real time, not fakeAsync: the sweep does file I/O.
    const tick = Duration(milliseconds: 150);

    Future<void> ticks(int count) =>
        Future<void>.delayed(tick * count + const Duration(milliseconds: 50));

    test('a file left after start is swept on a later tick', () async {
      final sweeper = AttachmentOrphanSweeper(() async => dir, interval: tick)
        ..start();
      addTearDown(sweeper.stop);
      await ticks(1);
      // A crash of an earlier run of this process's work, found later.
      final late = await seed('.veritra-attachment-$_id32.plaintext.part');
      final young = await seed('.veritra-attachment-$_id16.plaintext',
          age: const Duration(minutes: 5));
      await ticks(2);
      expect(await late.exists(), isFalse);
      expect(await young.exists(), isTrue,
          reason: 'an operation that may still run keeps its file');
    });

    test('nothing is swept after stop', () async {
      final sweeper = AttachmentOrphanSweeper(() async => dir, interval: tick)
        ..start();
      await ticks(1);
      sweeper.stop();
      final orphan = await seed('.veritra-attachment-$_id32.plaintext');
      await ticks(3);
      expect(await orphan.exists(), isTrue);
    });

    test('a directory that cannot be found does not stop the sweeps', () async {
      var calls = 0;
      final sweeper = AttachmentOrphanSweeper(() async {
        calls++;
        if (calls == 1) throw const FileSystemException('no provider');
        return dir;
      }, interval: tick)
        ..start();
      addTearDown(sweeper.stop);
      final orphan = await seed('.veritra-attachment-$_id32.ciphertext');
      await ticks(2);
      expect(calls, greaterThan(1));
      expect(await orphan.exists(), isFalse);
    });
  });
}
