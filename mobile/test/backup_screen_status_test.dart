import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/backup_service.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/settings/backup_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// A new backup replaces the old one and its recovery code, so the screen
/// never makes one without the replace warning unless it knows there is
/// none (TASK-085, Q-006 default).
void main() {
  Future<(AppState, _FakeBackups, _StatusStore)> open(
      WidgetTester tester) async {
    final store = _StatusStore()..gate = Completer<void>();
    final backups = _FakeBackups();
    final state = AppState(
      apiClientFactory: (url) => ApiClient(baseUrl: url),
      cryptoService: _FakeMls(),
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
      backupService: backups,
    )
      ..session = const Session(
        baseUrl: 'https://chat.example.org',
        token: 'token',
        accountId: 'acct_1',
        deviceId: 'dev_1',
      )
      ..api = ApiClient(baseUrl: 'https://chat.example.org');
    await tester.pumpWidget(MaterialApp(home: BackupScreen(state: state)));
    await tester.pump();
    return (state, backups, store);
  }

  FilledButton makeButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.ancestor(
          of: find.text('Make a backup'), matching: find.byType(FilledButton)));

  testWidgets('the button waits while the backup status loads', (tester) async {
    final (_, backups, store) = await open(tester);
    expect(makeButton(tester).onPressed, isNull);
    await tester.tap(find.text('Make a backup'));
    await tester.pump();
    expect(backups.created, 0);

    // Known: no backup yet. Then no warning is needed.
    store.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('No backup from this device yet'), findsOneWidget);
    expect(makeButton(tester).onPressed, isNotNull);
    await tester.tap(find.text('Make a backup'));
    await tester.pumpAndSettle();
    expect(find.text('Replace your backup?'), findsNothing);
    expect(backups.created, 1);
    expect(find.text('v1.code'), findsOneWidget);
  });

  testWidgets('a status that failed to load asks before replacing',
      (tester) async {
    final (_, backups, store) = await open(tester);
    store.failure = StateError('storage busy');
    store.gate!.complete();
    await tester.pumpAndSettle();
    // Unknown, with a way to try again.
    expect(find.text('Unknown'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Make a backup'));
    await tester.pumpAndSettle();
    expect(find.text('Replace your backup?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backups.created, 0);

    await tester.tap(find.text('Make a backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace backup'));
    await tester.pumpAndSettle();
    expect(backups.created, 1);
    expect(find.text('v1.code'), findsOneWidget);
  });

  testWidgets('a retried status load that succeeds is trusted', (tester) async {
    final (_, backups, store) = await open(tester);
    store.failure = StateError('storage busy');
    store.gate!.complete();
    await tester.pumpAndSettle();

    store.failure = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No backup from this device yet'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await tester.tap(find.text('Make a backup'));
    await tester.pumpAndSettle();
    expect(find.text('Replace your backup?'), findsNothing);
    expect(backups.created, 1);
  });

  testWidgets('an existing backup is confirmed before it is replaced',
      (tester) async {
    final (_, backups, store) = await open(tester);
    store.last = DateTime.utc(2026, 10, 1);
    store.gate!.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make a new backup'));
    await tester.pumpAndSettle();
    expect(find.text('Replace your backup?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backups.created, 0);
  });
}

/// Backup status that can wait for a gate and fail.
class _StatusStore extends MemoryLocalStore {
  Completer<void>? gate;
  Object? failure;
  DateTime? last;

  @override
  Future<DateTime?> loadLastBackupAt() async {
    await gate?.future;
    final error = failure;
    if (error != null) throw error;
    return last;
  }
}

class _FakeBackups implements BackupService {
  int created = 0;

  @override
  Future<String> createAndUpload(ApiClient client, String authToken) async {
    created++;
    return 'v1.code';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeMls implements MlsConversationCryptoService {
  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
