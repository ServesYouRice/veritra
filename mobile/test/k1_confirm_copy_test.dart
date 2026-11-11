import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/k1_backup.dart';
import 'package:private_messenger/core/k1_second_copy.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'k0_recovery_fakes.dart';
import 'k1_backup_test.dart' show K1Api, K1Crypto, K1Upload;

/// K1-5: the key confirmation schedule and the second copy.
class _Writer implements K1SecondCopyWriter {
  final List<Uint8List> written = <Uint8List>[];
  final List<String> folders = <String>[];
  bool fail = false;

  @override
  Future<void> write(
      {required String folder,
      required String accountId,
      required String deviceId,
      required Uint8List ciphertext}) async {
    if (fail) throw const FileSystemException('disk full');
    folders.add(folder);
    written.add(Uint8List.fromList(ciphertext));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('schedule', () {
    final t0 = DateTime.utc(2026, 11, 1);
    K1BackupState fresh() =>
        K1BackupState(baseUrl: 'https://x', accountId: 'a', deviceId: 'd')
          ..setKey(Uint8List(32), Uint8List(16), t0);

    test('3 days, then 14 days, then every 90; not now waits 7', () {
      final s = fresh();
      expect(s.confirmDue(t0.add(const Duration(days: 2))), isFalse);
      expect(s.confirmDue(t0.add(const Duration(days: 3))), isTrue);
      final d3 = t0.add(const Duration(days: 3));
      s.recordConfirmed(d3);
      expect(s.confirmDueAt, d3.add(const Duration(days: 14)));
      final d17 = d3.add(const Duration(days: 14));
      s.recordConfirmed(d17);
      expect(s.confirmDueAt, d17.add(const Duration(days: 90)));
      s.postponeConfirm(d17);
      expect(s.confirmDueAt, d17.add(const Duration(days: 7)));
    });

    test('three misses keep a badge until the key is confirmed', () {
      final s = fresh();
      for (var i = 0; i < 3; i++) {
        expect(s.confirmBadge, isFalse);
        s.postponeConfirm(t0);
      }
      expect(s.confirmBadge, isTrue);
      s.recordConfirmed(t0);
      expect(s.confirmBadge, isFalse);
    });

    test('the schedule and the second copy survive a reload', () {
      final s = fresh()
        ..postponeConfirm(t0)
        ..secondCopyPath = '/backups'
        ..secondCopyAt = t0
        ..secondCopyFailed = true;
      final back = K1BackupState.decode(s.encode())!;
      expect(back.confirmDueAt, s.confirmDueAt);
      expect(back.confirmMisses, 1);
      expect(back.secondCopyPath, '/backups');
      expect(back.secondCopyFailed, isTrue);
    });
  });

  group('second copy file', () {
    test('replaces the file by rename and keeps no part file', () async {
      final dir = await Directory.systemTemp.createTemp('k1copy');
      addTearDown(() => dir.delete(recursive: true));
      const writer = FileK1SecondCopyWriter();
      await writer.write(
          folder: dir.path,
          accountId: 'acct/1',
          deviceId: 'dev_1',
          ciphertext: Uint8List.fromList(<int>[1, 2, 3]));
      await writer.write(
          folder: dir.path,
          accountId: 'acct/1',
          deviceId: 'dev_1',
          ciphertext: Uint8List.fromList(<int>[9, 9]));
      final names = dir.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(names, <String>['veritra-backup-acct_1-dev_1.vhc']);
      expect(
          File('${dir.path}/${names.single}').readAsBytesSync(), <int>[9, 9]);
      await expectLater(
          writer.write(
              folder: '${dir.path}/missing',
              accountId: 'a',
              deviceId: 'd',
              ciphertext: Uint8List(1)),
          throwsA(isA<FileSystemException>()));
    });
  });

  group('AppState', () {
    late K0Server server;
    late MemoryLocalStore store;
    late K1Crypto crypto;
    late List<K1Upload> uploads;
    late AppState state;
    late DateTime now;
    late _Writer writer;

    setUp(() async {
      server = K0Server()..requireRecentAuth = false;
      store = MemoryLocalStore();
      crypto = K1Crypto();
      uploads = <K1Upload>[];
      now = DateTime.utc(2026, 11, 8, 9);
      writer = _Writer();
      state = AppState(
        apiClientFactory: (url) => K1Api(server, uploads, <Object>[], url),
        cryptoService: crypto,
        localStore: store,
        syncServiceFactory: (_, __) => K0QuietSync(),
      )
        ..k1Clock = (() => now)
        ..k1DesktopTimerEnabled = false
        ..k1SecondCopyWriter = writer;
      await store.saveSession(k0SignedIn);
      await state.tryRestoreSession();
      final draft = await state.createRecoveryKeyDraft();
      expect(await state.saveRecoveryKey(draft), RecoveryActionResult.done);
      draft.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });

    tearDown(() => state.dispose());

    test('confirming: a match schedules the next ask, a miss does not',
        () async {
      expect(state.k1ConfirmDue, isFalse);
      now = now.add(const Duration(days: 3));
      expect(state.k1ConfirmDue, isTrue);
      expect(await state.confirmK1Key('not a key'), isFalse);
      expect(state.k1ConfirmDue, isTrue);
      expect(await state.confirmK1Key(k0Display), isTrue);
      expect(state.k1ConfirmDue, isFalse);
      now = now.add(const Duration(days: 14));
      expect(state.k1ConfirmDue, isTrue);
      for (var i = 0; i < 3; i++) {
        await state.postponeK1Confirm();
        now = now.add(const Duration(days: 7));
      }
      expect(state.k1ConfirmBadge, isTrue);
      expect(state.k1BackupNeedsAttention, isTrue);
      expect(await state.confirmK1Key(k0Display), isTrue);
      expect(state.k1ConfirmBadge, isFalse);
    });

    test('the second copy is the same ciphertext, and its failure is its own',
        () async {
      await state.setK1SecondCopyFolder('/picked');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(writer.folders, <String>['/picked']);
      expect(writer.written.single, uploads.last.bytes);
      expect(state.k1BackupState!.secondCopyAt, isNotNull);
      expect(state.k1BackupState!.secondCopyFailed, isFalse);

      writer.fail = true;
      expect(await state.runK1BackupIfDue(force: true), isTrue);
      expect(state.k1BackupState!.secondCopyFailed, isTrue);
      expect(state.k1BackupState!.lastError, isNull);

      await state.setK1SecondCopyFolder(null);
      final count = uploads.length;
      writer.fail = false;
      await state.runK1BackupIfDue(force: true);
      expect(uploads.length, count + 1);
      expect(writer.written, hasLength(1));
    });
  });
}
