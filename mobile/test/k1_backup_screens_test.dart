import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/settings/auto_backup_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/ui/theme.dart';
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

class _Api extends K0Api {
  _Api(super.server);
  int uploads = 0;

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
