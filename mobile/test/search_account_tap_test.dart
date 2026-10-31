// Tapping an account in the people search starts one direct message, however
// often the row is tapped while the start is pending (TASK-076).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/search/search_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

/// Finds one account and starts a conversation only when the test says so.
class _PeopleState extends AppState {
  _PeopleState()
      : super(
          apiClientFactory: (_) => ApiClient(baseUrl: 'https://localhost'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _NoSync(),
        );

  int starts = 0;
  Completer<Conversation?>? pending;

  @override
  Future<List<MetadataSearchResult>> searchMetadata(String query) async =>
      <MetadataSearchResult>[
        MetadataSearchResult(type: 'account', id: 'acct_sam', label: 'Samuel'),
      ];

  @override
  Future<Conversation?> startConversation({
    required String kind,
    String? title,
    String? communityId,
    String? channelId,
    List<String> memberAccountIds = const <String>[],
    int? retentionSeconds,
  }) {
    starts++;
    return (pending = Completer<Conversation?>()).future;
  }
}

Future<_PeopleState> _openSearch(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = _PeopleState()
    ..session = const Session(
      baseUrl: 'https://localhost',
      token: 'token',
      accountId: 'acct_me',
      deviceId: 'dev_me',
    );
  addTearDown(state.dispose);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SearchScreen(state: state),
  ));
  await tester.tap(find.text('People and communities'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'peer');
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
  expect(find.text('Samuel'), findsOneWidget);
  return state;
}

void main() {
  testWidgets('two quick taps start one conversation and open one chat',
      (tester) async {
    final state = await _openSearch(tester);
    final row = find.text('Samuel');
    await tester.tap(row);
    await tester.tap(row);
    await tester.pump();
    expect(state.starts, 1);

    // A third tap while it is still pending does nothing either.
    await tester.tap(row, warnIfMissed: false);
    await tester.pump();
    expect(state.starts, 1);

    state.pending!.complete(
      Conversation(id: 'conv_sam', kind: 'dm', peerAccountId: 'acct_sam'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the row works again after a failed start', (tester) async {
    final state = await _openSearch(tester);
    await tester.tap(find.text('Samuel'));
    await tester.pump();
    state.pending!.complete(null);
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsNothing);

    await tester.tap(find.text('Samuel'));
    await tester.pump();
    expect(state.starts, 2, reason: 'a failed start does not lock the row');
    state.pending!.complete(
      Conversation(id: 'conv_sam', kind: 'dm', peerAccountId: 'acct_sam'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('leaving the search while a start is pending is harmless',
      (tester) async {
    final state = await _openSearch(tester);
    await tester.tap(find.text('Samuel'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    state.pending!.complete(
      Conversation(id: 'conv_sam', kind: 'dm', peerAccountId: 'acct_sam'),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
