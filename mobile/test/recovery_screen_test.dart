// The recovery screen keeps every action reachable on a short screen with
// large text, and stays centred on a tall one (TASK-090).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/app_shell.dart';

import 'test_crypto_service.dart';

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

class _RecoveryAppState extends AppState {
  _RecoveryAppState()
      : super(
          apiClientFactory: (_) => ApiClient(baseUrl: 'https://localhost'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _NoSync(),
        );

  int retries = 0;
  int continues = 0;

  @override
  Future<void> tryRestoreSession() async => retries++;

  @override
  void continueWithoutRestore() => continues++;
}

String get _longMessage => List<String>.filled(
      12,
      'The saved data on this device could not be opened.',
    ).join(' ');

Future<_RecoveryAppState> _show(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
  LocalStoreFailureKind? failure,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = _RecoveryAppState()
    ..lifecycle = SessionLifecycle.recoveryRequired
    ..recoveryMessage = _longMessage
    ..localStoreFailure = failure;
  addTearDown(state.dispose);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: AppShell(state: state),
  ));
  await tester.pump();
  return state;
}

void main() {
  final l10n = englishL10n;

  testWidgets('on a short screen with large text every action is reachable',
      (tester) async {
    final state = await _show(
      tester,
      size: const Size(320, 360),
      textScale: 2,
    );
    expect(tester.takeException(), isNull, reason: 'no overflow');

    await tester.ensureVisible(find.text(l10n.shellRetryRestore));
    await tester.tap(find.text(l10n.shellRetryRestore));
    await tester.pump();
    expect(state.retries, 1);

    await tester.ensureVisible(find.text(l10n.shellContinueToSignIn));
    await tester.tap(find.text(l10n.shellContinueToSignIn));
    await tester.pump();
    expect(state.continues, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the reset action is reachable too', (tester) async {
    await _show(
      tester,
      size: const Size(320, 360),
      textScale: 2,
      failure: LocalStoreFailureKind.keyMissing,
    );
    expect(tester.takeException(), isNull);
    // Scrolled into view it can be tapped (the confirmation dialog it opens
    // has its own layout and is not part of this check).
    await tester.ensureVisible(find.text(l10n.shellResetDevice));
    await tester.pump();
    expect(find.text(l10n.shellResetDevice).hitTestable(), findsOneWidget);
  });

  testWidgets('a tall screen keeps the content centred', (tester) async {
    await _show(tester, size: const Size(800, 1400));
    expect(tester.takeException(), isNull);
    final top = tester.getTopLeft(find.byIcon(Icons.lock_reset_outlined)).dy;
    final bottom =
        tester.getBottomLeft(find.text(l10n.shellContinueToSignIn)).dy;
    final space = 1400 - bottom;
    expect(top, greaterThan(100), reason: 'not pinned to the top');
    expect((top - space).abs(), lessThan(48),
        reason: 'equal room above and below');
  });
}
