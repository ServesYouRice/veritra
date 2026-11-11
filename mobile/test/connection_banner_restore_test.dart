import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_recovery.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/widgets/connection_banner.dart';

import 'test_crypto_service.dart';

/// The paused-sync banner offers every recovery choice the record allows,
/// and no backup restore: VBK2 and its restore action are retired (K1-6).
/// An account with one device that cannot sync starts again from "Lost all
/// your devices?" (K0 recovery), which restores from the newest K1 backup.
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

  testWidgets('an expired cursor offers a relink and no backup restore',
      (tester) async {
    final state = stateWith(SyncFailureKind.cursorExpired);
    addTearDown(state.dispose);
    expect(state.syncRecovery!.choices,
        orderedEquals(<SyncRecoveryChoice>[SyncRecoveryChoice.relink]));

    await tester.pumpWidget(app(state));
    expect(find.text('Messages paused'), findsOneWidget);
    expect(find.text('Link this device again'), findsOneWidget);
    expect(find.text('Restore from backup'), findsNothing);
  });

  testWidgets('every failure kind is free of a restore action', (tester) async {
    for (final kind in SyncFailureKind.values) {
      final state = stateWith(kind);
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      expect(find.text('Restore from backup'), findsNothing, reason: '$kind');
    }
  });

  testWidgets('a local storage failure offers only a retry', (tester) async {
    final state = stateWith(SyncFailureKind.localStorage);
    addTearDown(state.dispose);
    expect(state.syncRecovery!.choices,
        orderedEquals(<SyncRecoveryChoice>[SyncRecoveryChoice.retry]));
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
