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

/// Card I45 (T45C): the backup screen and the restore dialog.
void main() {
  testWidgets('making a backup shows the recovery code once and records it',
      (tester) async {
    final backups = _FakeBackups();
    final store = MemoryLocalStore();
    final state = _state(store, backups)
      ..session = const Session(
        baseUrl: 'https://chat.example.org',
        token: 'token',
        accountId: 'acct_1',
        deviceId: 'dev_1',
      )
      ..api = ApiClient(baseUrl: 'https://chat.example.org');
    expect(state.backupAvailable, isTrue);

    await tester.pumpWidget(MaterialApp(home: BackupScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.text('No backup from this device yet'), findsOneWidget);

    await tester.tap(find.text('Make a backup'));
    await tester.pumpAndSettle();
    expect(find.text('Save your recovery code'), findsOneWidget);
    expect(find.text('v1.code'), findsOneWidget);
    await tester.tap(find.text('I saved it'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Last backup'), findsOneWidget);
    expect(await store.loadLastBackupAt(), isNotNull);
  });

  group('the one-time recovery code', () {
    final navigatorKey = GlobalKey<NavigatorState>();

    /// The backup screen on top of a home page, so it can be popped.
    Future<_FakeBackups> openBackupScreen(WidgetTester tester) async {
      final backups = _FakeBackups()..createGate = Completer<void>();
      final state = _state(MemoryLocalStore(), backups)
        ..session = const Session(
          baseUrl: 'https://chat.example.org',
          token: 'token',
          accountId: 'acct_1',
          deviceId: 'dev_1',
        )
        ..api = ApiClient(baseUrl: 'https://chat.example.org');
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BackupScreen(state: state),
              ),
            ),
            child: const Text('open backup'),
          ),
        ),
      ));
      await tester.tap(find.text('open backup'));
      await tester.pumpAndSettle();
      return backups;
    }

    testWidgets('system back is blocked while the backup is being made',
        (tester) async {
      final backups = await openBackupScreen(tester);
      await tester.tap(find.text('Make a backup'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      // Long enough for the route to leave, were it popped.
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(BackupScreen), findsOneWidget,
          reason: 'leaving would lose the only chance to see the code');

      backups.createGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('v1.code'), findsOneWidget);
      await tester.tap(find.text('I saved it'));
      await tester.pumpAndSettle();
      // Once done, going back works again.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(BackupScreen), findsNothing);
    });

    testWidgets('a screen replaced during creation still shows the code',
        (tester) async {
      final backups = await openBackupScreen(tester);
      await tester.tap(find.text('Make a backup'));
      await tester.pump();

      // Something other than back removes the screen (a desktop destination
      // switch, a replaced route).
      unawaited(navigatorKey.currentState!.pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('somewhere else')),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(BackupScreen), findsNothing);

      backups.createGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Save your recovery code'), findsOneWidget);
      expect(find.text('v1.code'), findsOneWidget);
      await tester.tap(find.text('I saved it'));
      await tester.pumpAndSettle();
      expect(find.text('Save your recovery code'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('system back does not dismiss the recovery code dialog',
        (tester) async {
      final backups = await openBackupScreen(tester);
      backups.createGate!.complete();
      await tester.tap(find.text('Make a backup'));
      await tester.pumpAndSettle();
      expect(find.text('v1.code'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('v1.code'), findsOneWidget,
          reason: 'only "I saved it" closes the dialog');
      expect(find.byType(BackupScreen), findsOneWidget);

      await tester.tap(find.text('I saved it'));
      await tester.pumpAndSettle();
      expect(find.text('v1.code'), findsNothing);
      expect(find.byType(BackupScreen), findsOneWidget);
    });
  });

  testWidgets('a failed restore explains why and keeps the dialog open',
      (tester) async {
    final backups = _FakeBackups()
      ..restoreFailure = const BackupException(BackupFailureKind.wrongKey);
    final state = _state(MemoryLocalStore(), backups);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showRestoreBackupDialog(context, state),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'v1.wrong');
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.text('This recovery code does not open the backup.'),
        findsOneWidget);
    expect(find.text('Restore from a backup'), findsOneWidget);
    expect(backups.recovered, <String>['v1.wrong']);
  });
}

AppState _state(MemoryLocalStore store, _FakeBackups backups) => AppState(
      apiClientFactory: (url) => ApiClient(baseUrl: url),
      cryptoService: _FakeMls(),
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
      backupService: backups,
    );

class _FakeBackups implements BackupService {
  BackupException? restoreFailure;
  final List<String> recovered = <String>[];

  /// When set, creating the backup waits for it.
  Completer<void>? createGate;

  @override
  Future<String> createAndUpload(ApiClient client, String authToken) async {
    await createGate?.future;
    return 'v1.code';
  }

  @override
  Future<void> recover(String recoveryCode) async {
    recovered.add(recoveryCode);
    final failure = restoreFailure;
    if (failure != null) throw failure;
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
