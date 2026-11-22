import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/communities/community_workspace.dart';
import 'package:private_messenger/features/search/search_screen.dart';
import 'package:private_messenger/features/settings/linked_devices_screen.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/storage/message_search.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/theme.dart';
import 'package:private_messenger/ui/tokens.dart';
import 'package:private_messenger/ui/widgets/quick_switcher.dart';

class _StubApi extends ApiClient {
  _StubApi() : super(baseUrl: 'https://example.test');

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {}

  @override
  Future<List<ConversationMember>> conversationMembers(
    String token,
    String conversationId,
  ) async =>
      const <ConversationMember>[];
}

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

class _MlsStub implements MlsConversationCryptoService {
  final List<(AppPayloadType, Map<String, Object?>)> encrypted =
      <(AppPayloadType, Map<String, Object?>)>[];

  @override
  Future<void> dispose() async {}

  @override
  Future<MessageEnvelope> encryptPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    List<String> attachmentRefs = const <String>[],
    String? draftText,
  }) async {
    encrypted.add((type, body));
    return MessageEnvelope(
      conversationId: conversationId,
      idempotencyKey: 'k-${encrypted.length}',
      ciphertext: const <int>[1],
      cryptoProtocol: 'test',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _TestState extends AppState {
  _TestState(this.stub, this.store,
      {this.searchHits = const <MessageSearchHit>[]})
      : super(
          apiClientFactory: (_) => _StubApi(),
          cryptoService: stub,
          localStore: store,
          syncServiceFactory: (_, __) => _QuietSync(),
        );

  final _MlsStub stub;
  final MemoryLocalStore store;
  final List<MessageSearchHit> searchHits;

  @override
  Future<List<MessageSearchHit>> searchMessages(
    String query, {
    int limit = 50,
  }) async =>
      searchHits;
}

_TestState _makeState({
  MemoryLocalStore? store,
  List<MessageSearchHit> searchHits = const <MessageSearchHit>[],
}) {
  final stub = _MlsStub();
  final localStore = store ?? MemoryLocalStore();
  return _TestState(stub, localStore, searchHits: searchHits)
    ..api = _StubApi()
    ..session = const Session(
      baseUrl: 'https://example.test',
      token: 'token',
      accountId: 'alice',
      deviceId: 'dev_alice',
      username: 'alice',
    )
    ..conversations = <Conversation>[
      Conversation(
        id: 'conv_dm',
        kind: 'dm',
        peerAccountId: 'bob',
        peerUsername: 'bob',
        createdBy: 'alice',
      ),
      Conversation(
        id: 'conv_grp',
        kind: 'group',
        title: 'Design Crew',
        createdBy: 'alice',
      ),
    ]
    ..membersByConversation = <String, List<ConversationMember>>{
      'conv_grp': <ConversationMember>[
        ConversationMember(
            accountId: 'alice', username: 'alice', role: 'owner'),
        ConversationMember(accountId: 'bob', username: 'bob', role: 'member'),
        ConversationMember(
            accountId: 'carol', username: 'carol', role: 'member'),
      ],
    }
    ..conversationsLoaded = true
    ..devicesLoaded = true
    ..devices = <Device>[
      Device(
        id: 'dev_alice',
        accountId: 'alice',
        name: 'Laptop',
        createdAt: DateTime.utc(2026, 5, 1),
      ),
      Device(
        id: 'dev_phone',
        accountId: 'alice',
        name: 'Phone',
        createdAt: DateTime.utc(2026, 5, 2),
      ),
    ];
}

Future<void> _seedEffects(
  MemoryLocalStore store,
  String conversationId,
  List<MessageEffect> effects,
) async {
  if (await store.loadCryptoState() == null) {
    await store.saveCryptoState(
      StoredCryptoState(
        counter: 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: const <int>[1],
      ),
      0,
    );
  }
  final current = (await store.loadCryptoState())!;
  final cursor = await store.loadSyncCursor();
  await store.commitMlsTransition(
    MlsStateTransition(
      messageId: 'seed-${cursor + 1}',
      conversationId: conversationId,
      expectedCounter: current.counter,
      expectedCursor: cursor,
      state: StoredCryptoState(
        counter: current.counter + 1,
        stateKey: current.stateKey,
        sealedState: <int>[current.counter + 1],
      ),
      cursor: cursor + 1,
      messageEffects: effects,
    ),
  );
}

Widget _app(Widget home, {ThemeData? theme}) => MaterialApp(
      theme: theme ?? veritraDarkTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void main() {
  group('Bone tokens & contrast', () {
    test('active nav label on calm navActiveFill clears WCAG AA 4.5:1', () {
      for (final theme in <ThemeData>[
        veritraLightTheme(),
        veritraDarkTheme()
      ]) {
        final scheme = theme.colorScheme;
        final bg = compositeColor(
          BoneColors.navActiveFill(theme.brightness),
          scheme.surfaceContainerLow,
        );
        expect(
          contrastRatio(scheme.primary, bg),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.brightness}',
        );
      }
    });
  });

  group('Chat UX upgrades', () {
    testWidgets('consecutive messages within 2 minutes cluster sender header', (
      tester,
    ) async {
      final state = _makeState();
      addTearDown(state.dispose);
      final t0 = DateTime.utc(2026, 8, 1, 10, 0, 0).millisecondsSinceEpoch;
      final t1 = DateTime.utc(2026, 8, 1, 10, 0, 30).millisecondsSinceEpoch;
      final t2 = DateTime.utc(2026, 8, 1, 10, 5, 0).millisecondsSinceEpoch;
      await _seedEffects(state.store, 'conv_grp', <MessageEffect>[
        InsertMessageEffect(
          key: 'dev_bob:1',
          conversationId: 'conv_grp',
          senderAccountId: 'bob',
          senderDeviceId: 'dev_bob',
          kind: LocalMessageKind.text,
          body: 'First thought',
          createdAt: t0,
          state: LocalMessageState.received,
        ),
        InsertMessageEffect(
          key: 'dev_bob:2',
          conversationId: 'conv_grp',
          senderAccountId: 'bob',
          senderDeviceId: 'dev_bob',
          kind: LocalMessageKind.text,
          body: 'Second thought right after',
          createdAt: t1,
          state: LocalMessageState.received,
        ),
        InsertMessageEffect(
          key: 'dev_bob:3',
          conversationId: 'conv_grp',
          senderAccountId: 'bob',
          senderDeviceId: 'dev_bob',
          kind: LocalMessageKind.text,
          body: 'Much later thought',
          createdAt: t2,
          state: LocalMessageState.received,
        ),
      ]);
      await state.refreshHistory('conv_grp');
      await tester.pumpWidget(
        _app(ChatScreen(state: state, conversationId: 'conv_grp')),
      );
      await tester.pumpAndSettle();

      // @bob header shows once for the 30s burst, and once again 5 min later.
      expect(find.text('@bob'), findsNWidgets(2));
    });

    testWidgets('swipe right triggers reply bar without opening actions menu', (
      tester,
    ) async {
      final state = _makeState();
      addTearDown(state.dispose);
      final t0 = DateTime.utc(2026, 8, 1, 10, 0).millisecondsSinceEpoch;
      await _seedEffects(state.store, 'conv_dm', <MessageEffect>[
        InsertMessageEffect(
          key: 'dev_bob:m1',
          conversationId: 'conv_dm',
          senderAccountId: 'bob',
          senderDeviceId: 'dev_bob',
          kind: LocalMessageKind.text,
          body: 'Reply to this',
          createdAt: t0,
          state: LocalMessageState.received,
        ),
      ]);
      await state.refreshHistory('conv_dm');
      await tester.pumpWidget(
        _app(ChatScreen(state: state, conversationId: 'conv_dm')),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.text('Reply to this'), const Offset(110, 0));
      await tester.pumpAndSettle();

      expect(find.text('Replying to: Reply to this'), findsOneWidget);
      expect(find.text(englishL10n.chatCopyText), findsNothing);
      state.flushDrafts();
    });

    testWidgets('tapping a reaction pill toggles the reaction', (tester) async {
      final state = _makeState();
      addTearDown(state.dispose);
      final t0 = DateTime.utc(2026, 8, 1, 10, 0).millisecondsSinceEpoch;
      await _seedEffects(state.store, 'conv_dm', <MessageEffect>[
        InsertMessageEffect(
          key: 'dev_bob:m1',
          conversationId: 'conv_dm',
          senderAccountId: 'bob',
          senderDeviceId: 'dev_bob',
          kind: LocalMessageKind.text,
          body: 'Celebrate!',
          createdAt: t0,
          state: LocalMessageState.received,
        ),
        ReactionEffect(
          targetKey: 'dev_bob:m1',
          reactorAccountId: 'bob',
          reaction: '🎉',
          at: t0 + 10,
        ),
      ]);
      await state.refreshHistory('conv_dm');
      await tester.pumpWidget(
        _app(ChatScreen(state: state, conversationId: 'conv_dm')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('🎉'));
      await tester.pumpAndSettle();

      expect(state.stub.encrypted, hasLength(1));
      expect(state.stub.encrypted.single.$1, AppPayloadType.reaction);
      expect(state.stub.encrypted.single.$2['reaction'], '🎉');
    });

    testWidgets('compact 1-row pin bar cycles pins and opens pinned sheet', (
      tester,
    ) async {
      final state = _makeState();
      addTearDown(state.dispose);
      final now = DateTime.now().millisecondsSinceEpoch;
      await _seedEffects(state.store, 'conv_dm', <MessageEffect>[
        InsertMessageEffect(
          key: 'dev_bob:p1',
          conversationId: 'conv_dm',
          senderAccountId: 'bob',
          senderDeviceId: 'dev_bob',
          kind: LocalMessageKind.text,
          body: 'First pinned note',
          createdAt: now - 2000,
          state: LocalMessageState.received,
        ),
        InsertMessageEffect(
          key: 'dev_bob:p2',
          conversationId: 'conv_dm',
          senderAccountId: 'bob',
          senderDeviceId: 'dev_bob',
          kind: LocalMessageKind.text,
          body: 'Second pinned note',
          createdAt: now - 1000,
          state: LocalMessageState.received,
        ),
        PinMessageEffect(
          conversationId: 'conv_dm',
          targetKey: 'dev_bob:p1',
          accountId: 'alice',
          at: now - 500,
          pinned: true,
          durationSeconds: 86400,
        ),
        PinMessageEffect(
          conversationId: 'conv_dm',
          targetKey: 'dev_bob:p2',
          accountId: 'alice',
          at: now,
          pinned: true,
          durationSeconds: 86400,
        ),
      ]);
      await state.refreshHistory('conv_dm');
      await tester.pumpWidget(
        _app(ChatScreen(state: state, conversationId: 'conv_dm')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('pin-bar')), findsOneWidget);
      expect(find.text('1 of 2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('pin-bar-all')));
      await tester.pumpAndSettle();
      expect(find.text(englishL10n.chatPinnedMessagesTitle), findsOneWidget);
      expect(find.text('First pinned note'), findsWidgets);
      expect(find.text('Second pinned note'), findsWidgets);
    });
  });

  group('Chat list indicators', () {
    testWidgets('shows pin icon and Draft prefix only when previews are on', (
      tester,
    ) async {
      final state = _makeState();
      addTearDown(state.dispose);
      state.conversationPrefs = <String, LocalConversationPref>{
        'conv_dm': const LocalConversationPref(
          conversationId: 'conv_dm',
          pinnedAt: 1000,
        ),
      };
      state.composerDrafts.setText('conv_dm', 'See you at 5');
      state.showChatPreviews = true;

      await tester.pumpWidget(_app(ChatListScreen(state: state)));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
      expect(find.text('Draft: See you at 5'), findsOneWidget);

      // Privacy check: turning previews off hides unsent draft text on the list.
      state.showChatPreviews = false;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Draft: See you at 5'), findsNothing);
      state.flushDrafts();
    });
  });

  group('Desktop workspace, Quick Switcher, Settings & Scoped Search', () {
    testWidgets('CommunityWorkspace renders 3 panes and collapses categories', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final state = _makeState();
      addTearDown(state.dispose);
      final community = Community(
        id: 'comm_1',
        name: 'Builders',
      );
      final channel = Channel(
        id: 'chan_1',
        communityId: 'comm_1',
        name: 'announcements',
        kind: 'open',
      );
      state
        ..communitiesLoaded = true
        ..communities = <Community>[community]
        ..channelsByCommunity = <String, List<Channel>>{
          'comm_1': <Channel>[channel],
        }
        ..conversations = <Conversation>[
          ...state.conversations,
          Conversation(
            id: 'conv_chan_1',
            kind: 'community_channel',
            channelId: 'chan_1',
            title: 'announcements',
            createdBy: 'alice',
          ),
        ];

      await tester.pumpWidget(
        _app(Scaffold(body: CommunityWorkspace(state: state))),
      );
      await tester.pumpAndSettle();

      expect(find.text(englishL10n.communityPlaceholderName), findsOneWidget);
      expect(find.text(englishL10n.channelPlaceholderName), findsOneWidget);
      expect(
        find.text(englishL10n.communitySelectPromptTitle),
        findsOneWidget,
      );

      await tester.tap(find.text(englishL10n.channelPlaceholderName));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(ChatScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Quick Switcher filters local conversations and returns target',
        (
      tester,
    ) async {
      final state = _makeState();
      addTearDown(state.dispose);
      QuickSwitchTarget? picked;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  picked = await showQuickSwitcher(context, state);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('quick-switcher-input')),
        'Design',
      );
      await tester.pumpAndSettle();

      expect(find.text('Design Crew'), findsOneWidget);
      expect(find.text('@bob'), findsNothing);

      await tester.tap(find.text('Design Crew'));
      await tester.pumpAndSettle();
      expect(picked?.conversationId, 'conv_grp');
    });

    testWidgets(
        'Settings opens LinkedDevicesScreen and places Delete in Danger zone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final state = _makeState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_app(SettingsScreen(state: state)));
      await tester.pumpAndSettle();

      expect(
        find.text(englishL10n.settingsSectionDangerZone.toUpperCase()),
        findsOneWidget,
      );
      final deleteY = tester
          .getTopLeft(
              find.byKey(const ValueKey<String>('settings-delete-account')))
          .dy;
      final dangerY = tester
          .getTopLeft(
            find.text(englishL10n.settingsSectionDangerZone.toUpperCase()),
          )
          .dy;
      final signOutY = tester
          .getTopLeft(find.byKey(const ValueKey<String>('settings-sign-out')))
          .dy;
      expect(deleteY, greaterThan(dangerY));
      expect(signOutY, greaterThan(deleteY));

      await tester.tap(
        find.byKey(const ValueKey<String>('settings-linked-devices')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LinkedDevicesScreen), findsOneWidget);
      expect(find.text('Phone'), findsOneWidget);
    });

    testWidgets(
        'SearchScreen scopes message results to This chat and toggles to All chats',
        (
      tester,
    ) async {
      final now = DateTime.utc(2026, 8, 1, 12, 0).millisecondsSinceEpoch;
      final state = _makeState(
        searchHits: <MessageSearchHit>[
          MessageSearchHit(
            key: 'dev_bob:1',
            conversationId: 'conv_dm',
            senderAccountId: 'bob',
            createdAt: now,
            snippet: 'hello from dm',
          ),
          MessageSearchHit(
            key: 'dev_carol:2',
            conversationId: 'conv_grp',
            senderAccountId: 'carol',
            createdAt: now,
            snippet: 'hello from group',
          ),
        ],
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(
        _app(SearchScreen(state: state, conversationId: 'conv_dm')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(find.text('hello from dm'), findsOneWidget);
      expect(find.text('hello from group'), findsNothing);

      await tester.tap(find.byKey(const Key('search-scope-all-chats')));
      await tester.pumpAndSettle();
      expect(find.text('hello from dm'), findsOneWidget);
      expect(find.text('hello from group'), findsOneWidget);
    });
  });
}
