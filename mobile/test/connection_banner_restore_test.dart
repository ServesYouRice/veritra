import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/settings/backup_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_recovery.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/widgets/connection_banner.dart';

import 'test_crypto_service.dart';

/// The paused-sync banner offers every recovery choice the record allows.
/// Restoring a backup is the way out for an account with one device, which
/// cannot be linked again from another (STATE.md "Banner hides backup
/// restore").
void main() {
  AppState stateWith(SyncFailureKind kind) => AppState(
        apiClientFactory: (url) => ApiClient(baseUrl: url),
        cryptoService: TestOnlyCryptoService(),
        localStore: MemoryLocalStore(),
        syncServiceFactory: (_, __) => _IdleSync(),
      )
        ..session = const Session(
          baseUrl: 'https://localhost:8080',
          token: 'token',
          accountId: 'acct_me',
          deviceId: 'dev_me',
        )
        ..syncRecovery = SyncRecovery(
          kind: kind,
          recordedAt: DateTime.utc(2026, 10, 31),
          eventId: 7,
        );

  Widget app(AppState state) => MaterialApp(
        home: Scaffold(body: ConnectionBanner(state: state)),
      );

  testWidgets('an expired cursor offers a backup restore that opens backups',
      (tester) async {
    final state = stateWith(SyncFailureKind.cursorExpired);
    addTearDown(state.dispose);
    expect(state.syncRecovery!.choices,
        contains(SyncRecoveryChoice.restoreBackup));

    await tester.pumpWidget(app(state));
    expect(find.text('Messages paused'), findsOneWidget);
    expect(find.text('Link this device again'), findsOneWidget);
    final restore = find.widgetWithText(TextButton, 'Restore from backup');
    expect(restore, findsOneWidget);

    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(find.byType(BackupScreen), findsOneWidget);
  });

  testWidgets('the restore waits while the app is busy', (tester) async {
    final state = stateWith(SyncFailureKind.cursorExpired)..busy = true;
    addTearDown(state.dispose);
    await tester.pumpWidget(app(state));
    final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Restore from backup'));
    expect(button.onPressed, isNull);
  });

  testWidgets('a local storage failure offers no restore', (tester) async {
    final state = stateWith(SyncFailureKind.localStorage);
    addTearDown(state.dispose);
    expect(state.syncRecovery!.choices,
        isNot(contains(SyncRecoveryChoice.restoreBackup)));
    await tester.pumpWidget(app(state));
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Restore from backup'), findsNothing);
  });
}

class _IdleSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
