// People and communities search: communities and channels are found in this
// device's decrypted names (C3: the server keeps none) as the user types,
// accounts on the server only when the user submits, and a query that cannot
// be an account never leaves the device.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/community_name_search.dart';
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

/// Decrypted names stand in for the C3 records; the server answers with an
/// account and with a stale community row a C3 app must not show.
class _SearchState extends AppState {
  _SearchState()
      : super(
          apiClientFactory: (_) => ApiClient(baseUrl: 'https://localhost'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _NoSync(),
        );

  final serverQueries = <String>[];
  final selected = <(String, String?)>[];
  Object? serverFailure;

  /// While set, account lookups wait for the test to complete it.
  Completer<void>? hold;
  final names = <String, String>{
    'comm_club': 'Chess Club',
    'chan_general': 'Club General',
    'chan_secret': 'Club Secrets',
    'chan_board': 'Club Board',
  };

  @override
  Future<List<MetadataSearchResult>> searchMetadata(String query) async {
    serverQueries.add(query);
    final failure = serverFailure;
    if (failure != null) throw failure;
    final wait = hold;
    if (wait != null) await wait.future;
    return <MetadataSearchResult>[
      MetadataSearchResult(type: 'account', id: 'acct_club', label: 'club'),
      MetadataSearchResult(
          type: 'community', id: 'comm_stale', label: 'Stale Club'),
    ];
  }

  @override
  List<MetadataSearchResult> searchCommunityNamesLocally(String query) =>
      searchCommunityNames(
        query,
        communities: communities,
        channelsByCommunity: channelsByCommunity,
        conversations: conversations,
        communityName: (community) => names[community.id],
        channelName: (channel) => names[channel.id],
      );

  @override
  void selectChannel(String conversationId, String? channelId) {
    selected.add((conversationId, channelId));
    super.selectChannel(conversationId, channelId);
  }
}

Future<_SearchState> _openSearch(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = _SearchState()
    ..session = const Session(
      baseUrl: 'https://localhost',
      token: 'token',
      accountId: 'acct_me',
      deviceId: 'dev_me',
    )
    ..communities = <Community>[
      Community(id: 'comm_club', name: '', sharedConversationId: 'conv_shared'),
    ]
    ..channelsByCommunity = <String, List<Channel>>{
      'comm_club': <Channel>[
        Channel(
            id: 'chan_general',
            communityId: 'comm_club',
            name: '',
            kind: 'open',
            conversationId: 'conv_shared',
            layoutGeneration: 1),
        Channel(
            id: 'chan_secret',
            communityId: 'comm_club',
            name: '',
            kind: 'private',
            conversationId: 'conv_secret',
            layoutGeneration: 1),
        // Not a member: never listed.
        Channel(
            id: 'chan_board',
            communityId: 'comm_club',
            name: '',
            kind: 'private',
            conversationId: 'conv_board',
            layoutGeneration: 1),
      ],
    }
    ..conversations = <Conversation>[
      Conversation(
          id: 'conv_shared',
          kind: 'community_shared',
          communityId: 'comm_club'),
      Conversation(
          id: 'conv_secret',
          kind: 'community_channel',
          communityId: 'comm_club'),
    ];
  addTearDown(state.dispose);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SearchScreen(state: state),
  ));
  await tester.tap(find.text('People and communities'));
  await tester.pumpAndSettle();
  return state;
}

/// Types [text] and waits well past any debounce: nothing is submitted.
Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// Types [text] and presses Enter (the keyboard's search action).
Future<void> _submit(WidgetTester tester, String text) async {
  await _type(tester, text);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a multi-word name is found on the device and never sent',
      (tester) async {
    final state = await _openSearch(tester);
    await _type(tester, 'chess club');
    expect(find.text('Chess Club'), findsOneWidget);
    expect(find.text('COMMUNITY'), findsOneWidget);
    expect(state.serverQueries, isEmpty,
        reason: 'no account can match, so the name stays on this device');
  });

  testWidgets('local hits merge with server accounts only', (tester) async {
    final state = await _openSearch(tester);
    await _submit(tester, 'club');
    expect(state.serverQueries, <String>['club']);
    expect(find.text('club'), findsWidgets, reason: 'the account');
    // The community row, and each channel's second line.
    expect(find.text('Chess Club'), findsNWidgets(3));
    expect(find.text('Club General'), findsOneWidget);
    expect(find.text('Club Secrets'), findsOneWidget);
    expect(find.text('Club Board'), findsNothing,
        reason: 'a private channel this account is not in');
    expect(find.text('Stale Club'), findsNothing,
        reason: 'the server answers for accounts only');
  });

  testWidgets('a failed account lookup keeps the local hits', (tester) async {
    final state = await _openSearch(tester);
    state.serverFailure = StateError('offline');
    await _submit(tester, 'club');
    expect(find.text('Club General'), findsOneWidget);
    expect(find.text('Club Secrets'), findsOneWidget);
    expect(find.text('COMMUNITY'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('a lookup for older text never leaves the progress bar on',
      (tester) async {
    final state = await _openSearch(tester);
    final hold = state.hold = Completer<void>();
    await tester.enterText(find.byType(TextField), 'club');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await _type(tester, 'chess club');
    expect(find.byType(LinearProgressIndicator), findsNothing);
    hold.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Club General'), findsNothing,
        reason: 'the older answer is dropped');
    expect(state.serverQueries, <String>['club']);
  });

  testWidgets('typing updates local hits and never sends a lookup',
      (tester) async {
    final state = await _openSearch(tester);
    // Each prefix a user types on the way to a username.
    for (final prefix in <String>['cl', 'clu', 'club']) {
      await _type(tester, prefix);
    }
    expect(find.text('Club General'), findsOneWidget,
        reason: 'local names follow the typing');
    expect(find.text('COMMUNITY'), findsOneWidget);
    expect(state.serverQueries, isEmpty,
        reason: 'no prefix of what is typed reaches the server');
    await _type(tester, 'secrets');
    expect(find.text('Club Secrets'), findsOneWidget);
    expect(find.text('Club General'), findsNothing);
    expect(state.serverQueries, isEmpty);
  });

  testWidgets('the search button sends one lookup for the whole query',
      (tester) async {
    final state = await _openSearch(tester);
    await _type(tester, 'club');
    expect(state.serverQueries, isEmpty);
    await tester.tap(find.byKey(const Key('search-submit')));
    await tester.pumpAndSettle();
    expect(state.serverQueries, <String>['club']);
    expect(find.text('club'), findsWidgets, reason: 'the account');
  });

  testWidgets('a leading @ is dropped from the account lookup', (tester) async {
    final state = await _openSearch(tester);
    await _submit(tester, '@club');
    expect(state.serverQueries, <String>['club']);
    expect(find.text('club'), findsWidgets, reason: 'the account');
  });

  testWidgets('a bare @ or a multi-word submit sends nothing', (tester) async {
    final state = await _openSearch(tester);
    await _submit(tester, '@');
    await _submit(tester, 'chess club');
    expect(find.text('Chess Club'), findsOneWidget);
    expect(state.serverQueries, isEmpty);
  });

  testWidgets('typing after a submit drops the account result', (tester) async {
    final state = await _openSearch(tester);
    await _submit(tester, 'club');
    expect(find.text('ACCOUNT'), findsOneWidget);
    await _type(tester, 'clu');
    expect(find.text('ACCOUNT'), findsNothing,
        reason: 'the account answered a query that is no longer typed');
    expect(find.text('Club General'), findsOneWidget);
    expect(state.serverQueries, <String>['club']);
  });

  test('accountLookupQuery strips one @ and refuses non-usernames', () {
    expect(accountLookupQuery(' @alice '), 'alice');
    expect(accountLookupQuery('alice'), 'alice');
    expect(accountLookupQuery('@@alice'), isNull);
    expect(accountLookupQuery('@'), isNull);
    expect(accountLookupQuery('chess club'), isNull);
    expect(accountLookupQuery('@acct_${'0' * 32}'), 'acct_${'0' * 32}');
  });

  testWidgets('an open channel opens its shared group on that channel',
      (tester) async {
    final state = await _openSearch(tester);
    await _type(tester, 'general');
    await tester.tap(find.text('Club General'));
    await tester.pumpAndSettle();
    expect(
        state.selected, <(String, String?)>[('conv_shared', 'chan_general')]);
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('a private channel opens its own group', (tester) async {
    final state = await _openSearch(tester);
    await _type(tester, 'secrets');
    await tester.tap(find.text('Club Secrets'));
    await tester.pumpAndSettle();
    expect(state.selected, <(String, String?)>[('conv_secret', null)]);
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('a community opens its first channel open to this account',
      (tester) async {
    final state = await _openSearch(tester);
    await _type(tester, 'chess club');
    await tester.tap(find.text('Chess Club'));
    await tester.pumpAndSettle();
    expect(
        state.selected, <(String, String?)>[('conv_shared', 'chan_general')]);
    expect(find.byType(ChatScreen), findsOneWidget);
  });
}
