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

/// D70 S4: the record-limit stop names the conversation it offers to
/// leave, in the banner and in the confirmation, and falls back to generic
/// wording when the conversation is not listed.
void main() {
  AppState stateWith(String conversationId) => AppState(
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
        ..conversations = <Conversation>[
          Conversation(id: 'conv_team', kind: 'group', title: 'Team'),
        ]
        ..syncRecovery = SyncRecovery(
          kind: SyncFailureKind.recordLimit,
          recordedAt: DateTime.utc(2026, 11, 1),
          eventId: 7,
          conversationId: conversationId,
        );

  Widget app(AppState state) => MaterialApp(
        home: Scaffold(body: ConnectionBanner(state: state)),
      );

  testWidgets('a listed conversation is named in the banner and the dialog',
      (tester) async {
    final state = stateWith('conv_team');
    addTearDown(state.dispose);
    await tester.pumpWidget(app(state));
    expect(find.text(state.l10n.syncErrorRecordLimitNamed('Team')),
        findsOneWidget);
    final leave = find.widgetWithText(TextButton, 'Leave "Team"');
    expect(leave, findsOneWidget);
    await tester.tap(leave);
    await tester.pumpAndSettle();
    expect(find.text('Leave "Team"?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('an unlisted conversation gets the generic wording',
      (tester) async {
    final state = stateWith('conv_gone');
    addTearDown(state.dispose);
    await tester.pumpWidget(app(state));
    expect(find.text(state.l10n.syncErrorRecordLimit), findsOneWidget);
    expect(
        find.widgetWithText(TextButton, 'Leave conversation'), findsOneWidget);
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
