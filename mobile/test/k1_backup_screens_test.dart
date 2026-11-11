import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart'
    show BackupHeaderInfo, OpenedBackup;
import 'package:private_messenger/features/settings/auto_backup_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/ui/theme.dart';
import 'package:private_messenger/features/settings/k1_restore_screen.dart';
import 'package:private_messenger/ui/widgets/history_copy_banner.dart';
import 'package:private_messenger/ui/widgets/recovery_key_prompt_banner.dart';

import 'k0_recovery_fakes.dart';

class _SealCrypto extends K0Crypto implements BackupSealCryptoService {
  @override
  int get k1BackupMaxPlaintextBytes => 1 << 20;

  @override
  Future<Uint8List> sealK1Backup({
    required String accountId,
    required String sourceDeviceId,
    required int createdAtMs,
    required int counter,
    required Uint8List rkPub,
    required Uint8List plaintext,
  }) async =>
      Uint8List.fromList(<int>[1, 2, 3]);
}

class _OpenCrypto extends _SealCrypto implements BackupOpenCryptoService {
  @override
  BackupHeaderInfo peekK1Backup(Uint8List prefix) => throw UnimplementedError();

  @override
  Future<OpenedBackup> openK1Backup({
    required Uint8List ciphertext,
    required Uint8List entropy,
    required String accountId,
    String? sourceDeviceId,
  }) async =>
      throw UnimplementedError();
}

class _Api extends K0Api {
  _Api(super.server);
  int uploads = 0;

  @override
  Future<List<Map<String, Object?>>> listBackups(String token,
          {int limit = 100}) async =>
      <Map<String, Object?>>[
        <String, Object?>{
          'id': 'backup_a',
          'device_id': 'dev_src',
          'device_name': 'Old phone',
          'device_revoked': true,
          'kind': 1,
          'ciphertext_sha256': 'a' * 64,
          'size_bytes': 10,
          'created_at': '2026-11-08T09:00:00Z',
          'counter': 2,
          'rk_id': base64.encode(List<int>.filled(16, 0xB2)),
          'superseded': false,
        },
        <String, Object?>{'id': 'legacy', 'kind': 0},
      ];

  @override
  Future<void> uploadK1Backup(String token, Uint8List ciphertext,
      {required List<int> rkId, required int counter}) async {
    uploads++;
  }
}

/// K1-3 screens: the automatic backup screen and the D49 prompt.
void main() {
  late K0Server server;
  late MemoryLocalStore store;

  setUp(() {
    server = K0Server();
    store = MemoryLocalStore();
  });

  AppState signedIn() {
    final state = k0App(server, store, _SealCrypto())
      ..session = k0SignedIn
      ..api = _Api(server);
    state.k1DesktopTimerEnabled = false;
    return state;
  }

  Widget app(Widget home) =>
      MaterialApp(theme: veritraLightTheme(), home: Scaffold(body: home));

  testWidgets('another device: "Type recovery key" turns backups on here',
      (tester) async {
    server.status = RecoveryKeyStatus(
        available: true,
        configured: true,
        rkId: Uint8List.fromList(List<int>.filled(16, 0xB2)));
    final state = signedIn();
    addTearDown(state.dispose);
    state.recoveryKeyStatus = server.status;
    await tester.pumpWidget(app(AutoBackupScreen(state: state, isPhone: true)));
    await tester.pumpAndSettle();
    expect(find.text('Type your recovery key to turn on backups here'),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('auto-backup-now')), findsNothing);

    await tester
        .tap(find.byKey(const ValueKey<String>('auto-backup-type-key')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey<String>('auto-backup-key-field')), k0Display);
    await tester
        .tap(find.byKey(const ValueKey<String>('auto-backup-key-submit')));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Backups are on for this device.'), findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('auto-backup-now')), findsOneWidget);
    expect(find.text('This phone backs up when you open the app.'),
        findsOneWidget);
  });

  // Phones (D91): iOS saves a copy by hand, Android names the picked folder
  // and never shows its content URI.
  for (final platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.android,
  ]) {
    testWidgets('the second copy on ${platform.name}', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        server.status = RecoveryKeyStatus(
            available: true,
            configured: true,
            rkId: Uint8List.fromList(List<int>.filled(16, 0xB2)));
        final state = signedIn();
        addTearDown(state.dispose);
        state.recoveryKeyStatus = server.status;
        await tester
            .pumpWidget(app(AutoBackupScreen(state: state, isPhone: true)));
        await tester.pumpAndSettle();
        await tester
            .tap(find.byKey(const ValueKey<String>('auto-backup-type-key')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey<String>('auto-backup-key-field')),
            k0Display);
        await tester
            .tap(find.byKey(const ValueKey<String>('auto-backup-key-submit')));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pumpAndSettle();
        expect(find.text('Backups are on for this device.'), findsOneWidget);
        final save =
            find.byKey(const ValueKey<String>('auto-backup-save-copy'));
        final folder =
            find.byKey(const ValueKey<String>('auto-backup-second-copy'));
        if (platform == TargetPlatform.iOS) {
          expect(save, findsOneWidget);
          expect(folder, findsNothing);
          expect(find.text('Save a copy of the backup'), findsOneWidget);
          return;
        }
        expect(save, findsNothing);
        expect(find.text('Keep a second copy in a folder'), findsOneWidget);
        const tree = 'content://com.android.externalstorage.documents/tree/'
            'primary%3ABackups';
        await tester.runAsync(
            () => state.setK1SecondCopyFolder(tree, label: 'Backups'));
        await tester.pumpAndSettle();
        expect(find.text('Second copy: Backups'), findsOneWidget);
        expect(find.textContaining('content://'), findsNothing);
        await tester.runAsync(() => state.setK1SecondCopyFolder(tree));
        await tester.pumpAndSettle();
        expect(find.text('Second copy: the folder you chose'), findsOneWidget);
        expect(find.textContaining('content://'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets(
      'the restore screen lists copies of other devices and asks for '
      'the key', (tester) async {
    final state = k0App(server, store, _OpenCrypto())
      ..session = k0SignedIn
      ..api = _Api(server);
    state.k1DesktopTimerEnabled = false;
    addTearDown(state.dispose);
    state.recoveryKeyStatus =
        const RecoveryKeyStatus(available: true, configured: true);
    await tester.pumpWidget(app(K1RestoreScreen(state: state)));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Old phone'), findsOneWidget);
    expect(find.text('This device was removed from your account.'),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('k1-restore-legacy')), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('k1-restore-backup_a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('auto-backup-key-field')),
        findsOneWidget);
  });

  testWidgets('a history copy that ended offers the restore from a backup',
      (tester) async {
    final state = k0App(server, store, _OpenCrypto())
      ..session = k0SignedIn
      ..api = _Api(server)
      ..historyTransferStatus = const HistoryTransferStatus(
          incoming: true, phase: HistoryTransferPhase.ended);
    state.k1DesktopTimerEnabled = false;
    addTearDown(state.dispose);
    state.recoveryKeyStatus =
        const RecoveryKeyStatus(available: true, configured: true);
    await tester.pumpWidget(app(HistoryCopyBanner(state: state)));
    expect(find.byKey(const ValueKey<String>('history-copy-restore')),
        findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey<String>('history-copy-restore')));
    await tester.pumpAndSettle();
    expect(find.byType(K1RestoreScreen), findsOneWidget);
    // The sending side never sees it.
    state.historyTransferStatus = const HistoryTransferStatus(
        incoming: false, phase: HistoryTransferPhase.ended);
    await tester.pumpWidget(app(HistoryCopyBanner(state: state)));
    expect(find.byKey(const ValueKey<String>('history-copy-restore')),
        findsNothing);
  });

  testWidgets('the prompt shows without a key and hides on "Not now"',
      (tester) async {
    final state = signedIn();
    addTearDown(state.dispose);
    state.recoveryKeyStatus =
        const RecoveryKeyStatus(available: true, configured: false);
    await tester.pumpWidget(app(RecoveryKeyPromptBanner(state: state)));
    expect(find.byKey(const ValueKey<String>('recovery-key-prompt')),
        findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey<String>('recovery-key-prompt-later')));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('recovery-key-prompt')),
        findsNothing);
  });

  testWidgets('a server with recovery off shows no prompt', (tester) async {
    final state = signedIn();
    addTearDown(state.dispose);
    state.recoveryKeyStatus =
        const RecoveryKeyStatus(available: false, configured: false);
    await tester.pumpWidget(app(RecoveryKeyPromptBanner(state: state)));
    expect(find.byKey(const ValueKey<String>('recovery-key-prompt')),
        findsNothing);
  });
}
