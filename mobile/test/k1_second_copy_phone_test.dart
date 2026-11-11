import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/k1_backup.dart';
import 'package:private_messenger/core/k1_second_copy.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart'
    show BackupHeaderInfo, OpenedBackup;
import 'package:private_messenger/crypto/sha256.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'k0_recovery_fakes.dart';
import 'k1_backup_test.dart' show K1Api, K1Crypto, K1Upload;

/// K1 second copy on phones (D91): Android keeps it in a picked document
/// tree through the platform channel, iOS saves it by hand through the
/// document picker. The native sides (`K1SecondCopy.kt`, `AppDelegate.swift`)
/// are not built here; these tests mock the channel.
const _tree = 'content://com.android.externalstorage.documents/tree/'
    'primary%3ABackups';

/// Copies of at least the 416-byte header a peek reads.
class _PhoneCrypto extends K1Crypto implements BackupOpenCryptoService {
  String peekAccount = 'acct_me';
  String peekDevice = 'dev_old';
  int? peekCounter;
  Uint8List? peekRkId;

  @override
  Future<Uint8List> sealK1Backup({
    required String accountId,
    required String sourceDeviceId,
    required int createdAtMs,
    required int counter,
    required Uint8List rkPub,
    required Uint8List plaintext,
  }) async {
    final sealed = await super.sealK1Backup(
        accountId: accountId,
        sourceDeviceId: sourceDeviceId,
        createdAtMs: createdAtMs,
        counter: counter,
        rkPub: rkPub,
        plaintext: plaintext);
    return Uint8List(600)..setAll(0, sealed);
  }

  @override
  BackupHeaderInfo peekK1Backup(Uint8List prefix) => BackupHeaderInfo(
      accountId: peekAccount,
      sourceDeviceId: peekDevice,
      createdAtMs: 1731000000000,
      counter: peekCounter ?? prefix[4],
      rkId: peekRkId ?? _storedRkId!,
      plaintextVersion: 1,
      paddedSize: 1 << 20);

  Uint8List? _storedRkId;

  @override
  Future<OpenedBackup> openK1Backup({
    required Uint8List ciphertext,
    required Uint8List entropy,
    required String accountId,
    String? sourceDeviceId,
  }) =>
      throw StateError('an export never opens the copy');
}

/// Lists and serves what was uploaded, as the server's K1 rows.
class _PhoneApi extends K1Api {
  _PhoneApi(super.server, super.uploads, super.failures);

  /// A server that serves other bytes than the row it lists.
  Uint8List? served;
  int? listedCounter;

  @override
  Future<List<Map<String, Object?>>> listBackups(String token,
          {int limit = 100}) async =>
      <Map<String, Object?>>[
        for (final upload in uploads)
          <String, Object?>{
            'id': 'backup_${upload.counter.toRadixString(16).padLeft(32, '0')}',
            'device_id': 'dev_old',
            'device_name': 'This phone',
            'device_revoked': false,
            'kind': 1,
            'ciphertext_sha256': sha256(upload.bytes)
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join(),
            'size_bytes': upload.bytes.length,
            'created_at': '2026-11-08T09:00:00Z',
            'counter': listedCounter ?? upload.counter,
            'rk_id': base64.encode(upload.rkId),
            'superseded': upload != uploads.last,
          },
      ];

  @override
  Future<Stream<List<int>>> downloadBackup(String token, String id,
      {int? start, int? end}) async {
    final upload = uploads.lastWhere(
        (u) => 'backup_${u.counter.toRadixString(16).padLeft(32, '0')}' == id);
    return Stream<List<int>>.value(served ?? upload.bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(k1SecondCopyChannelName);
  late K0Server server;
  late MemoryLocalStore store;
  late _PhoneCrypto crypto;
  late List<K1Upload> uploads;
  late _PhoneApi api;
  late AppState state;
  late List<MethodCall> calls;
  late Object? Function(MethodCall call) answer;

  setUp(() async {
    server = K0Server()..requireRecentAuth = false;
    store = MemoryLocalStore();
    crypto = _PhoneCrypto();
    uploads = <K1Upload>[];
    calls = <MethodCall>[];
    answer = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final result = answer(call);
      if (result is PlatformException) throw result;
      return result;
    });
    api = _PhoneApi(server, uploads, <Object>[]);
    state = AppState(
      apiClientFactory: (url) => api,
      cryptoService: crypto,
      localStore: store,
      syncServiceFactory: (_, __) => K0QuietSync(),
    )..k1DesktopTimerEnabled = false;
    await store.saveSession(k0SignedIn);
    await state.tryRestoreSession();
    final draft = await state.createRecoveryKeyDraft();
    expect(await state.saveRecoveryKey(draft), RecoveryActionResult.done);
    draft.dispose();
    await _until(() => state.k1BackupState?.lastSuccessAt != null);
    crypto._storedRkId = Uint8List.fromList(state.k1BackupState!.rkId!);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    state.dispose();
  });

  test('the mode follows the platform: phones are no longer server-only', () {
    expect(
        k1SecondCopyModeFor(TargetPlatform.android), K1SecondCopyMode.folder);
    expect(k1SecondCopyModeFor(TargetPlatform.iOS), K1SecondCopyMode.export);
    expect(k1SecondCopyModeFor(TargetPlatform.linux), K1SecondCopyMode.folder);
    expect(
        k1SecondCopyModeFor(TargetPlatform.windows), K1SecondCopyMode.folder);
    expect(k1SecondCopyModeFor(TargetPlatform.macOS), K1SecondCopyMode.folder);
    expect(k1SecondCopyModeFor(TargetPlatform.fuchsia), K1SecondCopyMode.none);
    expect(state.k1SecondCopyWriter, isA<PlatformK1SecondCopyWriter>());
  });

  group('Android', () {
    void picks() => answer = (call) => switch (call.method) {
          'pickFolder' => <String, Object?>{'tree': _tree, 'label': 'Backups'},
          _ => null,
        };

    test(
        'a picked tree gets the same ciphertext through the channel, '
        'and Settings keeps its name, not the URI', () async {
      picks();
      expect(await state.pickK1SecondCopyFolder(), K1SecondCopyPick.picked);
      await _until(() => calls.any((c) => c.method == 'write'));
      await _until(() => state.k1BackupState?.secondCopyAt != null);
      final write = calls.lastWhere((c) => c.method == 'write');
      final args = (write.arguments as Map).cast<String, Object?>();
      expect(args['tree'], _tree);
      expect(args['name'], k1SecondCopyFileName('acct_me', 'dev_old'));
      expect(args['bytes'], uploads.last.bytes);
      final backup = state.k1BackupState!;
      expect(backup.secondCopyPath, _tree);
      expect(backup.secondCopyLabel, 'Backups');
      expect(backup.secondCopyFailed, isFalse);
      final reread = K1BackupState.decode(backup.encode())!;
      expect(reread.secondCopyLabel, 'Backups');
      expect(reread.secondCopyPath, _tree);
    });

    test('a failed write is its own warning and never fails the backup',
        () async {
      picks();
      await state.pickK1SecondCopyFolder();
      await _until(() => state.k1BackupState?.secondCopyAt != null);
      answer = (call) => call.method == 'write'
          ? PlatformException(code: 'write_failed')
          : null;
      final before = uploads.length;
      expect(await state.runK1BackupIfDue(force: true), isTrue);
      expect(uploads, hasLength(before + 1));
      expect(state.k1BackupState!.secondCopyFailed, isTrue);
      expect(state.k1BackupState!.lastError, isNull);
      // The next good write clears the warning.
      answer = (_) => null;
      expect(await state.runK1BackupIfDue(force: true), isTrue);
      expect(state.k1BackupState!.secondCopyFailed, isFalse);
    });

    test('a cancelled or failed pick changes nothing', () async {
      answer = (_) => null;
      expect(await state.pickK1SecondCopyFolder(), K1SecondCopyPick.cancelled);
      answer = (_) => PlatformException(code: 'no_picker');
      expect(await state.pickK1SecondCopyFolder(), K1SecondCopyPick.failed);
      answer = (_) => <String, Object?>{'tree': '/sdcard/Backups'};
      expect(await state.pickK1SecondCopyFolder(), K1SecondCopyPick.failed,
          reason: 'only a document tree is taken');
      expect(state.k1BackupState!.secondCopyPath, isNull);
      expect(calls.where((c) => c.method == 'write'), isEmpty);
    });

    test('a folder no longer used gives up its grant', () async {
      picks();
      await state.pickK1SecondCopyFolder();
      const other = '${_tree}2';
      answer = (call) => call.method == 'pickFolder'
          ? <String, Object?>{'tree': other, 'label': ''}
          : null;
      await state.pickK1SecondCopyFolder();
      expect(
          calls
              .where((c) => c.method == 'release')
              .map((c) => (c.arguments as Map)['tree']),
          [_tree]);
      await state.setK1SecondCopyFolder(null);
      expect(
          calls
              .where((c) => c.method == 'release')
              .map((c) => (c.arguments as Map)['tree']),
          [_tree, other]);
      expect(state.k1BackupState!.secondCopyLabel, isNull);
    });
  });

  group('iOS export', () {
    test('saves the copy this device uploaded last, with its date', () async {
      answer = (call) => call.method == 'export' ? true : null;
      expect(state.k1BackupState!.secondCopyAt, isNull);
      expect(await state.exportK1SecondCopy(), K1SecondCopyExport.saved);
      final export = calls.singleWhere((c) => c.method == 'export');
      final args = (export.arguments as Map).cast<String, Object?>();
      expect(args['name'], k1SecondCopyFileName('acct_me', 'dev_old'));
      expect(args['bytes'], uploads.last.bytes);
      expect(state.k1BackupState!.secondCopyAt, isNotNull);
    });

    test('a cancelled export changes nothing', () async {
      answer = (call) => call.method == 'export' ? false : null;
      expect(await state.exportK1SecondCopy(), K1SecondCopyExport.cancelled);
      expect(state.k1BackupState!.secondCopyAt, isNull);
    });

    test('a copy that is not the one this device uploaded is never exported',
        () async {
      answer = (call) => call.method == 'export' ? true : null;
      // Bytes that do not match the row.
      api.served = Uint8List(600);
      expect(await state.exportK1SecondCopy(), K1SecondCopyExport.failed);
      api.served = null;
      // A header for another device, an older counter, another key.
      crypto.peekDevice = 'dev_other';
      expect(await state.exportK1SecondCopy(), K1SecondCopyExport.failed);
      crypto.peekDevice = 'dev_old';
      crypto.peekCounter = 0;
      expect(await state.exportK1SecondCopy(), K1SecondCopyExport.failed);
      crypto.peekCounter = null;
      crypto.peekRkId = Uint8List(16);
      expect(await state.exportK1SecondCopy(), K1SecondCopyExport.failed);
      crypto.peekRkId = null;
      // A row whose counter is not this device's last one: nothing to save.
      api.listedCounter = 99;
      expect(await state.exportK1SecondCopy(), K1SecondCopyExport.noCopy);
      api.listedCounter = null;
      expect(calls.where((c) => c.method == 'export'), isEmpty);
      expect(state.k1BackupState!.secondCopyAt, isNull);
      // A channel failure (no screen, picker busy) is a failure, not a save.
      answer = (call) =>
          call.method == 'export' ? PlatformException(code: 'busy') : null;
      expect(await state.exportK1SecondCopy(), K1SecondCopyExport.failed);
      expect(state.k1BackupState!.secondCopyAt, isNull);
    });
  });
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}
