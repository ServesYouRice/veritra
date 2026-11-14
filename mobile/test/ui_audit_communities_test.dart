import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/communities/community_screen.dart';
import 'package:private_messenger/features/communities/create_channel_screen.dart';
import 'package:private_messenger/features/communities/edit_info_dialog.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

// UI audit 2026-11-14, communities cards (U1, U4, U31, U32, part of U8).

class _Sync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _Roles implements VerifiedRoleSource {
  _Roles(this.state);
  final GovernanceState state;
  @override
  GovernanceState? governanceOf(String conversationId) => state;
  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) =>
      false;
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');
  @override
  Future<List<ConversationMember>> communityMembers(
          String token, String id) async =>
      [ConversationMember(accountId: 'alice', role: 'owner')];
}

AppState _ownerState() {
  final api = _Api();
  final state = AppState(
    apiClientFactory: (_) => api,
    syncServiceFactory: (_, __) => _Sync(),
    localStore: MemoryLocalStore(),
    cryptoService: UnavailableCryptoService(),
  )
    ..api = api
    ..session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: 'alice',
        deviceId: 'device')
    ..communities = <Community>[
      Community(id: 'comm_1', name: 'Club', sharedConversationId: 'shared'),
    ]
    ..conversations = <Conversation>[
      Conversation(
          id: 'shared',
          kind: 'community_shared',
          communityId: 'comm_1',
          currentRole: 'owner'),
    ]
    ..debugInfoRoleSource = _Roles(GovernanceState(
        rev: 1, owner: 'alice', ownerRev: 1, joined: const {'alice': 1}));
  return state;
}

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void main() {
  testWidgets(
      'U1: at 360 dp an owner sees the whole name, one actions menu, and a '
      'header under 100 dp', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _ownerState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_app(CommunityScreen(state: state)));
    await tester.pumpAndSettle();

    // The community name is not squeezed out by trailing buttons.
    final name = find.text('Community');
    expect(name, findsOneWidget);
    expect(tester.getSize(name).width, greaterThan(100));
    expect(tester.getSize(name).height, lessThan(30),
        reason: 'one line, not one letter per line');
    // The header (first tile of the card) is under 100 dp tall.
    expect(tester.getSize(find.byType(ListTile).first).height, lessThan(100));
    // One labelled menu, no loose icon buttons on the header.
    final menu = find.byType(PopupMenuButton<String>);
    expect(menu, findsOneWidget);
    expect(find.byTooltip('Actions for Community'), findsOneWidget);
    expect(find.byType(IconButton), findsNWidgets(2),
        reason: 'only the top bar: Join with a link and Refresh');

    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('Edit community'), findsOneWidget);
    expect(find.text('Categories and icon'), findsOneWidget);
    expect(find.text('Roles'), findsOneWidget);
    expect(find.text('New channel'), findsOneWidget);
  });

  group('U32: channel dialogs', () {
    final community =
        Community(id: 'comm_1', name: 'Club', sharedConversationId: 'shared');
    final channel = Channel(
        id: 'chan_1',
        communityId: 'comm_1',
        name: '',
        kind: 'open',
        conversationId: 'shared',
        layoutGeneration: 1);

    // [forChannel] false edits the community itself, which only owners and
    // admins may (channel names and topics are open to members, D80).
    Future<void> openEdit(WidgetTester tester, AppState state,
        {bool forChannel = true}) async {
      await tester.pumpWidget(_app(Scaffold(
          body: EditInfoDialog(
              state: state,
              community: community,
              channel: forChannel ? channel : null))));
      await tester.pumpAndSettle();
    }

    FilledButton save(WidgetTester tester) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));

    testWidgets(
        'edit and create share one name limit and say what is wrong under '
        'the field', (tester) async {
      final state = _ownerState();
      addTearDown(state.dispose);
      await openEdit(tester, state);
      // An untouched empty name is a prompt, not an error; Save stays off.
      expect(find.text('Enter a name.'), findsNothing);
      expect(save(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, 'x' * 101);
      await tester.pump();
      expect(find.text('That name is too long.'), findsOneWidget);
      expect(save(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, 'x' * 100);
      await tester.pump();
      expect(find.text('That name is too long.'), findsNothing);
      expect(save(tester).onPressed, isNotNull);

      await tester.enterText(find.byType(TextField).first, 'a\u202eb');
      await tester.pump();
      expect(find.text('That name has characters that are not allowed.'),
          findsOneWidget);
      expect(save(tester).onPressed, isNull);

      // Create takes exactly what edit takes.
      await tester.pumpWidget(
          _app(CreateChannelScreen(state: state, community: community)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'x' * 101);
      await tester.pump();
      expect(find.text('That name is too long.'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'x' * 100);
      await tester.pump();
      expect(find.text('That name is too long.'), findsNothing);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
              .onPressed,
          isNotNull);
    });

    testWidgets('edit says why Save is off when the account may not edit',
        (tester) async {
      final state = _ownerState();
      addTearDown(state.dispose);
      await openEdit(tester, state, forChannel: false);
      await tester.enterText(find.byType(TextField).first, 'general');
      await tester.pump();
      expect(save(tester).onPressed, isNotNull);
      expect(find.byKey(const Key('edit-not-allowed')), findsNothing);

      // Demoted: the verified record no longer lets this account edit.
      state.debugInfoRoleSource = _Roles(GovernanceState(
          rev: 2, owner: 'bob', ownerRev: 1, joined: const {'alice': 1}));
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(save(tester).onPressed, isNull);
      expect(
          find.text(
              'You cannot save changes here any more, because your role or account has changed.'),
          findsOneWidget);
    });
  });
}
