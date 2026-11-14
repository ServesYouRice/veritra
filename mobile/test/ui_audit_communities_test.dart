import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader;
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
import 'package:private_messenger/features/communities/membership_screens.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/ui/theme.dart';
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
      [
        ConversationMember(
            accountId: 'alice', role: 'owner', username: 'alice'),
        ConversationMember(accountId: 'bob', role: 'member', username: 'bob'),
        ConversationMember(
            accountId: 'carol', role: 'member', username: 'carol'),
      ];
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
      theme: veritraLightTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

/// Loads the real Roboto from the Flutter SDK, so widths are the phone's and
/// not the test font's. False when the SDK files cannot be found; the width
/// checks are then skipped.
Future<bool> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return false;
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  final files = <File>[
    for (final name in <String>[
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf'
    ])
      File('${dir.path}/$name'),
  ];
  if (!files.every((f) => f.existsSync())) return false;
  final loader = FontLoader('Roboto');
  for (final file in files) {
    loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await loader.load();
  return true;
}

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
    expect(find.byType(IconButton), findsNWidgets(1),
        reason: "only the menu's own button; Join and New are words");

    // Every tap target is named for a screen reader.
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

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
      // Save is off, and the field says why.
      expect(find.text('Enter a name.'), findsOneWidget);
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

  group('U31: communities tab and page', () {
    testWidgets(
        'Join and New are labelled top-bar actions that fit 320 dp; no '
        'floating button', (tester) async {
      final realFonts = await _loadRoboto();
      for (final width in <double>[360, 320]) {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = _ownerState();
        addTearDown(state.dispose);
        await tester.pumpWidget(_app(CommunityScreen(state: state)));
        await tester.pumpAndSettle();

        expect(find.widgetWithText(TextButton, 'Join'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'New'), findsOneWidget);
        expect(find.byTooltip('Join with a link'), findsOneWidget);
        expect(find.byTooltip('New community'), findsOneWidget);
        expect(find.byType(FloatingActionButton), findsNothing);
        // The title is not cut to make room for them.
        final title = tester
            .renderObject<RenderParagraph>(find.text('Communities').first);
        if (realFonts) {
          expect(title.didExceedMaxLines, isFalse, reason: 'at $width dp');
        }
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

        await tester.tap(find.text('Join'));
        await tester.pumpAndSettle();
        expect(find.byType(JoinByLinkScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('at text scale 2.0 the actions keep their names as icons',
        (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final state = _ownerState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_app(CommunityScreen(state: state)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Join with a link'), findsOneWidget);
      expect(find.byTooltip('New community'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Join'), findsNothing);
    });

    testWidgets('the empty state offers both ways in', (tester) async {
      final state = _ownerState()
        ..communities = <Community>[]
        ..conversations = <Conversation>[]
        ..communitiesLoaded = true;
      addTearDown(state.dispose);
      await tester.pumpWidget(_app(CommunityScreen(state: state)));
      await tester.pumpAndSettle();
      // The top-bar actions carry tooltips only, so the visible words are the
      // two buttons of the empty state.
      expect(find.text('New community'), findsOneWidget);
      expect(find.text('Join with a link'), findsOneWidget);
      await tester.tap(find.text('Join with a link'));
      await tester.pumpAndSettle();
      expect(find.byType(JoinByLinkScreen), findsOneWidget);
    });

    testWidgets('a private channel shows a padlock, an open one does not',
        (tester) async {
      final state = _ownerState()
        ..channelsByCommunity = <String, List<Channel>>{
          'comm_1': <Channel>[
            Channel(
                id: 'chan_open',
                communityId: 'comm_1',
                name: '',
                kind: 'open',
                conversationId: 'shared',
                layoutGeneration: 1),
            Channel(
                id: 'chan_private',
                communityId: 'comm_1',
                name: '',
                kind: 'private',
                conversationId: 'private_group',
                layoutGeneration: 1),
          ],
        };
      addTearDown(state.dispose);
      await tester.pumpWidget(_app(CommunityScreen(state: state)));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(
          find.byWidgetPredicate((w) =>
              w is Icon &&
              w.icon == Icons.lock_outline &&
              w.semanticLabel == 'Private channel'),
          findsOneWidget);
      expect(find.byIcon(Icons.tag), findsOneWidget);
    });

    testWidgets('a member in a running timeout is marked, others are not',
        (tester) async {
      final api = _Api();
      final state = _ownerState();
      state.api = api;
      final until = DateTime.now().add(const Duration(hours: 2));
      final expired = DateTime.now().subtract(const Duration(hours: 1));
      state.governanceOverrideForTesting = (_) => GovernanceState(
            rev: 3,
            owner: 'alice',
            ownerRev: 1,
            joined: const {'alice': 1, 'bob': 2, 'carol': 2},
            timeouts: {
              'bob': MemberTimeout(
                  epoch: 4,
                  fromMs: until.millisecondsSinceEpoch - 7200000,
                  untilMs: until.millisecondsSinceEpoch),
              'carol': MemberTimeout(
                  epoch: 4,
                  fromMs: expired.millisecondsSinceEpoch - 7200000,
                  untilMs: expired.millisecondsSinceEpoch),
            },
          );
      addTearDown(state.dispose);
      await tester.pumpWidget(_app(CommunityDetailsScreen(
          state: state,
          community: Community(
              id: 'comm_1', name: 'Club', sharedConversationId: 'shared'))));
      await tester.pumpAndSettle();
      expect(find.textContaining('Timed out until'), findsOneWidget);
      expect(find.textContaining('bob'), findsWidgets);
    });
  });
}
