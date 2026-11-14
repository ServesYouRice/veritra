// U27: the new-chat sheet lists the people this device already shares chats
// with, from local data only. Search filters the list, tapping a person opens
// the chat, and the button says Message. A stranger whose request is pending is
// never listed: starting a chat with them would accept it.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/new_conversation_sheet.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/widgets/account_picker.dart';

import 'test_crypto_service.dart';

class _Api extends ApiClient {
  _Api(this.list) : super(baseUrl: 'https://localhost:8080');

  List<Conversation> list;
  final List<String> searches = <String>[];

  @override
  Future<List<Conversation>> conversations(String token) async => list;

  @override
  Future<List<MetadataSearchResult>> searchMetadata(
    String token,
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    searches.add(query);
    return const <MetadataSearchResult>[];
  }
}

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

Conversation _dm(String id, String peer, {String? createdBy}) => Conversation(
      id: id,
      kind: 'dm',
      peerAccountId: peer,
      peerUsername: peer.replaceFirst('acct_', ''),
      createdBy: createdBy ?? 'acct_me',
      createdAt: DateTime.utc(2026, 6, 1),
    );

Future<(AppState, _Api)> _state(
  WidgetTester tester, {
  List<Conversation>? list,
}) async {
  final api = _Api(list ??
      <Conversation>[
        _dm('d_ana', 'acct_ana'),
        _dm('d_bo', 'acct_bo'),
        // A stranger's request, and a blocked account.
        _dm('d_eve', 'acct_eve', createdBy: 'acct_eve'),
        _dm('d_bad', 'acct_bad'),
        Conversation(
          id: 'g',
          kind: 'group',
          title: 'Family',
          createdBy: 'acct_me',
        ),
        Conversation(id: 'shared', kind: 'community_shared'),
      ]);
  final state = AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _NoSync(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'https://localhost:8080',
      token: 'token',
      accountId: 'acct_me',
      deviceId: 'dev_me',
    );
  addTearDown(state.dispose);
  await tester.runAsync(state.refreshConversations);
  state
    ..blockedAccounts = <BlockedAccount>[BlockedAccount(accountId: 'acct_bad')]
    ..membersByConversation = <String, List<ConversationMember>>{
      'g': <ConversationMember>[
        ConversationMember(accountId: 'acct_me', username: 'me', role: 'owner'),
        ConversationMember(
            accountId: 'acct_cy', username: 'cy', role: 'member'),
        // In a group with this person, but a request in a chat of two.
        ConversationMember(
            accountId: 'acct_eve', username: 'eve', role: 'member'),
        ConversationMember(
            accountId: 'acct_bad', username: 'bad', role: 'member'),
      ],
      // A community channel's members are not people this device chats with.
      'shared': <ConversationMember>[
        ConversationMember(
            accountId: 'acct_stray', username: 'stray', role: 'member'),
      ],
    };
  return (state, api);
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

Widget _opener(AppState state, {void Function(Conversation?)? onResult}) =>
    _app(Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async {
            final result = await showNewConversationSheet(context, state);
            onResult?.call(result);
          },
          child: const Text('open'),
        ),
      ),
    ));

void main() {
  testWidgets('who is known: chats of two and group members, never a stranger',
      (tester) async {
    final (state, _) = await _state(tester);
    final people = knownPeople(state);
    expect(
      people.map((person) => person.id),
      <String>['acct_ana', 'acct_bo', 'acct_cy'],
    );
    // Not yourself, not a blocked account, not a pending request (even one who
    // is also in a group), not a community channel's member.
    expect(
      people.map((person) => person.id),
      isNot(anyOf(contains('acct_me'), contains('acct_bad'),
          contains('acct_eve'), contains('acct_stray'))),
    );
  });

  testWidgets('a person is labelled by username', (tester) async {
    final (state, _) = await _state(tester);
    expect(knownPeople(state).first.label, '@ana');
  });

  testWidgets('the sheet lists them, and the button says Message',
      (tester) async {
    final (state, api) = await _state(tester);
    await tester.pumpWidget(_opener(state));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(englishL10n.accountPickerKnown), findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('known-acct_ana')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('known-acct_bo')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('known-acct_eve')), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Message'), findsOneWidget);
    // Listing them asked the server nothing.
    expect(api.searches, isEmpty);
  });

  testWidgets('typing filters the list on this device', (tester) async {
    final (state, api) = await _state(tester);
    await tester.pumpWidget(_opener(state));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'an');
    await tester.pump();
    expect(
        find.byKey(const ValueKey<String>('known-acct_ana')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('known-acct_bo')), findsNothing);
    // Nothing was asked of the server before the pause that follows typing.
    expect(api.searches, isEmpty);

    // Someone not on the list is still found by exact username.
    await tester.enterText(find.byType(TextField), 'zed');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('known-acct_ana')), findsNothing);
    expect(api.searches, <String>['zed']);
  });

  testWidgets('tapping a person starts the chat and the list opens it',
      (tester) async {
    final (state, _) = await _state(tester);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();

    await tester.tap(find.byTooltip(englishL10n.chatListNewChat));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('known-acct_ana')));
    // An open chat never settles (its timers and spinners run on), so pump
    // for as long as the sheet and the route take instead.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // The sheet is gone and the chat with Ana is open, with no Message tap.
    expect(find.text(englishL10n.newConversationTitle), findsNothing);
    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(chat.conversationId, 'd_ana');
    expect(state.selectedConversationId, 'd_ana');
  });

  testWidgets('a person picked for a group is added, not opened',
      (tester) async {
    final (state, _) = await _state(tester);
    Conversation? result;
    await tester.pumpWidget(_opener(state, onResult: (c) => result = c));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('known-acct_ana')));
    await tester.pumpAndSettle();

    expect(find.byType(InputChip), findsOneWidget);
    expect(find.text(englishL10n.newConversationTitle), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('a plain AccountPicker offers no list', (tester) async {
    final (state, _) = await _state(tester);
    await tester.pumpWidget(_app(Scaffold(
      body: AccountPicker(state: state, onChanged: (_) {}),
    )));
    expect(find.text(englishL10n.accountPickerKnown), findsNothing);
    expect(find.byType(ListTile), findsNothing);
  });
}
