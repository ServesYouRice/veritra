// U28: the chat list is tidy. Requests collapse into one row and stay out of
// Archived, New chat is a top-bar action, the timer chip has an icon, the empty
// state offers "Start a chat" and "Invite someone", and Archived is a page with
// Back.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _Api extends ApiClient {
  _Api(this.list) : super(baseUrl: 'https://localhost:8080');

  List<Conversation> list;

  @override
  Future<List<Conversation>> conversations(String token) async => list;
}

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

Conversation _dm(
  String id,
  String peer,
  String createdBy, {
  int? retentionSeconds,
}) =>
    Conversation(
      id: id,
      kind: 'dm',
      peerAccountId: peer,
      peerUsername: peer.replaceFirst('acct_', ''),
      createdBy: createdBy,
      createdAt: DateTime.utc(2026, 6, 1),
      retentionSeconds: retentionSeconds,
    );

Future<AppState> _state(
  WidgetTester tester,
  List<Conversation> list, {
  String? role,
}) async {
  final api = _Api(list);
  final state = AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _NoSync(),
  )
    ..api = api
    ..session = Session(
      baseUrl: 'https://localhost:8080',
      token: 'token',
      accountId: 'acct_me',
      deviceId: 'dev_me',
      role: role,
    );
  addTearDown(state.dispose);
  await tester.runAsync(state.refreshConversations);
  return state;
}

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void main() {
  testWidgets('requests collapse into one row and stay out of Archived', (
    tester,
  ) async {
    final state = await _state(tester, <Conversation>[
      _dm('mine', 'acct_pal', 'acct_me'),
      _dm('req1', 'acct_stranger', 'acct_stranger'),
      _dm('req2', 'acct_other', 'acct_other'),
    ]);
    await state.setConversationArchived('mine', true);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();

    // Two strangers, one row; neither is listed on the main page.
    expect(find.byKey(const Key('requests-row')), findsOneWidget);
    expect(find.text('Requests (2)'), findsOneWidget);
    expect(find.textContaining('stranger'), findsNothing);
    expect(find.textContaining('other'), findsNothing);

    // The Requests row opens a page that lists them.
    await tester.tap(find.byKey(const Key('requests-row')));
    await tester.pumpAndSettle();
    expect(find.textContaining('stranger'), findsOneWidget);
    expect(find.textContaining('other'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Archived shows the archived chat and no requests.
    await tester.tap(find.byTooltip(englishL10n.w8ArchivedChats));
    await tester.pumpAndSettle();
    expect(find.textContaining('pal'), findsWidgets);
    expect(find.byKey(const Key('requests-row')), findsNothing);
    expect(find.textContaining('stranger'), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('requests-row')), findsOneWidget);
  });

  testWidgets('New chat is in the top bar and nothing floats over a row', (
    tester,
  ) async {
    final state = await _state(tester, <Conversation>[
      _dm('mine', 'acct_pal', 'acct_me'),
    ]);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();

    expect(find.byType(FloatingActionButton), findsNothing);
    final newChat = find.byTooltip(englishL10n.chatListNewChat);
    expect(newChat, findsOneWidget);
    expect(
      find.ancestor(of: newChat, matching: find.byType(AppBar)),
      findsOneWidget,
    );
    await tester.tap(newChat);
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.newConversationTitle), findsOneWidget);
  });

  testWidgets('the disappearing-timer chip has an icon', (tester) async {
    final state = await _state(tester, <Conversation>[
      _dm('mine', 'acct_pal', 'acct_me', retentionSeconds: 86400),
    ]);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();

    expect(find.text('1d'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('1d'),
          matching: find.byType(Container),
        ),
        matching: find.byIcon(Icons.timer_outlined),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the empty state offers Start a chat, and Invite for an admin', (
    tester,
  ) async {
    final member = await _state(tester, const <Conversation>[]);
    await tester.pumpWidget(_app(ChatListScreen(state: member)));
    await tester.pump();
    expect(find.text(englishL10n.chatListStartChat), findsOneWidget);
    expect(find.text(englishL10n.chatListInviteSomeone), findsNothing);

    final admin = await _state(tester, const <Conversation>[], role: 'admin');
    await tester.pumpWidget(_app(ChatListScreen(state: admin)));
    await tester.pump();
    expect(find.text(englishL10n.chatListStartChat), findsOneWidget);
    expect(find.text(englishL10n.chatListInviteSomeone), findsOneWidget);

    await tester.tap(find.text(englishL10n.chatListStartChat));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.newConversationTitle), findsOneWidget);
  });

  testWidgets('an empty archive says so', (tester) async {
    final state = await _state(tester, <Conversation>[
      _dm('mine', 'acct_pal', 'acct_me'),
    ]);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();
    await tester.tap(find.byTooltip(englishL10n.w8ArchivedChats));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.chatListArchivedEmptyTitle), findsOneWidget);
  });

  testWidgets('a named group shows its initials, an unnamed one its icon', (
    tester,
  ) async {
    final state = await _state(tester, <Conversation>[
      Conversation(id: 'g1', kind: 'group', title: 'book club'),
      Conversation(id: 'g2', kind: 'group'),
    ]);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();
    expect(find.text('BC'), findsOneWidget);
    expect(find.byIcon(Icons.group_outlined), findsOneWidget);
  });

  testWidgets('U36: a swipe opens the row actions and keeps the row', (
    tester,
  ) async {
    final state = await _state(tester, <Conversation>[
      _dm('mine', 'acct_pal', 'acct_me'),
    ]);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();

    await tester.drag(find.textContaining('pal').first, const Offset(-400, 0));
    await tester.pumpAndSettle();
    // The same menu a long press opens.
    expect(find.text(englishL10n.w8Archive), findsOneWidget);
    expect(find.text(englishL10n.chatListDetails), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.textContaining('pal'), findsWidgets);
  });
}
