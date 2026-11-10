import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/communities/community_screen.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/l10n/app_localizations_en.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'native_test_env.dart';
import 'test_crypto_service.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(baseUrl: 'https://localhost:8080');

  int sends = 0;
  int channelCreations = 0;

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);

  @override
  Future<List<ConversationMember>> conversationMembers(
          String token, String conversationId) async =>
      const <ConversationMember>[];

  @override
  Future<ConversationMute> conversationMute(
          String token, String conversationId) async =>
      ConversationMute(muted: false);

  @override
  Future<List<Conversation>> conversations(String token) async =>
      const <Conversation>[];

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    sends++;
  }

  @override
  Future<ChannelCreation> createChannel(
    String token,
    String communityId,
    String name, {
    String kind = 'private',
  }) async {
    channelCreations++;
    final channel = Channel(
      id: 'chan_$channelCreations',
      communityId: communityId,
      name: name,
      kind: kind,
    );
    final conversation = Conversation(
      id: 'conv_chan_$channelCreations',
      kind: 'community_channel',
      communityId: communityId,
      channelId: channel.id,
      postingRestricted: kind == 'announcement',
    );
    return ChannelCreation(channel: channel, conversation: conversation);
  }

  @override
  Future<Conversation> setPostingPolicy(
    String token,
    String conversationId,
    String policy,
  ) async {
    return Conversation(
      id: conversationId,
      kind: 'group',
      postingRestricted: policy == 'admins',
    );
  }

  @override
  Future<void> markRead(
      String token, String conversationId, String messageId) async {}
}

class _FakeSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  GovernanceState testGovernanceRecord({
    bool adminsOnly = false,
    Set<String> announcements = const {},
  }) =>
      GovernanceState(
        rev: 1,
        owner: 'acct_owner',
        ownerRev: 0,
        admins: {'acct_admin': 1},
        moderators: {'acct_mod'},
        adminsOnlyPosting: adminsOnly,
        announcementChannels: announcements,
        joined: {
          'acct_owner': 0,
          'acct_admin': 1,
          'acct_mod': 2,
          'acct_member': 3,
        },
      );

  AppState createAppState({
    required _FakeApi api,
    String accountId = 'acct_member',
    String? role,
  }) {
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _FakeSync(),
    )
      ..api = api
      ..session = Session(
        baseUrl: 'https://localhost:8080',
        token: 'token_$accountId',
        accountId: accountId,
        deviceId: 'dev_$accountId',
        username: accountId,
        role: role,
      );
    return state;
  }

  group('C2: AppState VerifiedRoleSource & Permissions', () {
    test(
        'serverRestrictsPosting correctly detects restricted conversations and channels',
        () {
      final api = _FakeApi();
      final state = createAppState(api: api)
        ..conversations = <Conversation>[
          Conversation(id: 'c_open', kind: 'group', postingRestricted: false),
          Conversation(
              id: 'c_restricted', kind: 'group', postingRestricted: true),
          Conversation(
              id: 'c_legacy_ann',
              kind: 'community_channel',
              channelId: 'ch_ann'),
        ]
        ..channelsByCommunity = {
          'comm_1': [
            Channel(
                id: 'ch_open',
                communityId: 'comm_1',
                name: 'general',
                kind: 'open'),
            Channel(
                id: 'ch_ann',
                communityId: 'comm_1',
                name: 'news',
                kind: 'announcement'),
          ],
        };

      expect(state.serverRestrictsPosting('c_open', null), isFalse);
      expect(state.serverRestrictsPosting('c_restricted', null), isTrue);
      // Channel route restriction
      expect(state.serverRestrictsPosting('c_open', 'ch_ann'), isTrue);
      expect(state.serverRestrictsPosting('c_open', 'ch_open'), isFalse);
      // Legacy channel conversation where channel is announcement
      expect(state.serverRestrictsPosting('c_legacy_ann', null), isTrue);
    });

    test('mayPost enforces roles using governance record or server role', () {
      final api = _FakeApi();
      final state = createAppState(api: api, accountId: 'acct_member')
        ..conversations = <Conversation>[
          Conversation(id: 'c_group', kind: 'group', postingRestricted: true),
        ];

      // 1. With governance record
      state.governanceOverrideForTesting =
          (_) => testGovernanceRecord(adminsOnly: true);

      expect(state.mayPost('c_group'), isFalse,
          reason: 'member cannot post when adminsOnly');

      // Admin and owner may post
      state.session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 't',
        accountId: 'acct_admin',
      );
      expect(state.mayPost('c_group'), isTrue);

      state.session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 't',
        accountId: 'acct_owner',
      );
      expect(state.mayPost('c_group'), isTrue);

      state.session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 't',
        accountId: 'acct_mod',
      );
      expect(state.mayPost('c_group'), isFalse);

      // 2. Without governance record (server-reported role fallback)
      state.governanceOverrideForTesting = null;
      state.session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 't',
        accountId: 'acct_member',
      );
      state.conversations = [
        Conversation(
            id: 'c_group',
            kind: 'group',
            postingRestricted: true,
            currentRole: 'member'),
      ];
      expect(state.mayPost('c_group'), isFalse);

      state.conversations = [
        Conversation(
            id: 'c_group',
            kind: 'group',
            postingRestricted: true,
            currentRole: 'moderator'),
      ];
      expect(state.mayPost('c_group'), isFalse);

      state.conversations = [
        Conversation(
            id: 'c_group',
            kind: 'group',
            postingRestricted: true,
            currentRole: 'admin'),
      ];
      expect(state.mayPost('c_group'), isTrue);

      state.conversations = [
        Conversation(
            id: 'c_group',
            kind: 'group',
            postingRestricted: true,
            currentRole: 'owner'),
      ];
      expect(state.mayPost('c_group'), isTrue);
    });

    test(
        'roleOf does not leak session currentRole to other accounts and resolves creator',
        () {
      final api = _FakeApi();
      final state = createAppState(api: api, accountId: 'acct_alice')
        ..conversations = [
          Conversation(
            id: 'c_group',
            kind: 'group',
            postingRestricted: true,
            createdBy: 'acct_bob',
            currentRole: 'admin',
          ),
          Conversation(
            id: 'c_chan',
            kind: 'community_channel',
            communityId: 'comm_1',
            channelId: 'ch_1',
            currentRole: 'member',
          ),
        ]
        ..communities = [
          Community(
            id: 'comm_1',
            name: 'Comm 1',
            createdBy: 'acct_founder',
          ),
        ];

      // Local user Alice gets her currentRole 'admin'
      expect(state.roleOf('c_group', 'acct_alice'), 'admin');

      // Conversation creator Bob gets 'owner' even though Alice is admin
      expect(state.roleOf('c_group', 'acct_bob'), 'owner');

      // Community creator Founder gets 'owner' for channels in the community
      expect(state.roleOf('c_chan', 'acct_founder'), 'owner');

      // Third party Carol has no record -> null, NOT Alice's 'admin'
      expect(state.roleOf('c_group', 'acct_carol'), isNull);
    });

    test('canCreateChannel allows only admins and owners', () {
      final api = _FakeApi();
      final state = createAppState(api: api, accountId: 'acct_member')
        ..communities = [
          Community(
              id: 'comm_1',
              name: 'My Community',
              sharedConversationId: 'c_shared'),
        ]
        ..conversations = [
          Conversation(
              id: 'c_shared',
              kind: 'community_shared',
              communityId: 'comm_1',
              currentRole: 'member'),
        ];

      expect(state.canCreateChannel('comm_1'), isFalse);

      // Moderator cannot create channels (owner decision)
      state.conversations = [
        Conversation(
            id: 'c_shared',
            kind: 'community_shared',
            communityId: 'comm_1',
            currentRole: 'moderator'),
      ];
      expect(state.canCreateChannel('comm_1'), isFalse);

      // Admin and owner can create channels
      state.conversations = [
        Conversation(
            id: 'c_shared',
            kind: 'community_shared',
            communityId: 'comm_1',
            currentRole: 'admin'),
      ];
      expect(state.canCreateChannel('comm_1'), isTrue);

      state.conversations = [
        Conversation(
            id: 'c_shared',
            kind: 'community_shared',
            communityId: 'comm_1',
            currentRole: 'owner'),
      ];
      expect(state.canCreateChannel('comm_1'), isTrue);

      // With governance record
      state.governanceOverrideForTesting = (_) => testGovernanceRecord();
      state.session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 't',
        accountId: 'acct_member',
      );
      expect(state.canCreateChannel('comm_1'), isFalse);

      state.session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 't',
        accountId: 'acct_mod',
      );
      expect(state.canCreateChannel('comm_1'), isFalse);

      state.session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 't',
        accountId: 'acct_admin',
      );
      expect(state.canCreateChannel('comm_1'), isTrue);

      state.session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 't',
        accountId: 'acct_owner',
      );
      expect(state.canCreateChannel('comm_1'), isTrue);
    });

    test('createChannel guards non-admins from creating channels', () async {
      final api = _FakeApi();
      final state = createAppState(api: api, accountId: 'acct_member')
        ..communities = [
          Community(
              id: 'comm_1',
              name: 'Community',
              sharedConversationId: 'c_shared'),
        ]
        ..conversations = [
          Conversation(
              id: 'c_shared',
              kind: 'community_shared',
              communityId: 'comm_1',
              currentRole: 'member'),
        ];

      await state.createChannel('comm_1', 'new-channel');
      expect(api.channelCreations, 0);
      expect(state.error, isNotNull);

      // Now as admin
      state.conversations = [
        Conversation(
            id: 'c_shared',
            kind: 'community_shared',
            communityId: 'comm_1',
            currentRole: 'admin'),
      ];
      await state.createChannel('comm_1', 'admin-channel');
      expect(api.channelCreations, 1);
    });

    test('sendMessageTo refuses early when posting is restricted', () async {
      final api = _FakeApi();
      final state = createAppState(api: api, accountId: 'acct_member')
        ..conversations = [
          Conversation(
              id: 'c_restricted',
              kind: 'group',
              postingRestricted: true,
              currentRole: 'member'),
        ];

      final sent = await state.sendMessageTo('c_restricted', 'hello');
      expect(sent, isFalse);
      expect(state.errorFor(Ops.send), contains('Only admins can post'));
      expect(api.sends, 0);
    });

    test('setPostingPolicy updates conversation state and preserves metadata',
        () async {
      final api = _FakeApi();
      final state = createAppState(api: api, accountId: 'acct_owner')
        ..conversations = [
          Conversation(
              id: 'c_group',
              kind: 'group',
              postingRestricted: false,
              unreadCount: 5,
              currentRole: 'owner'),
        ];

      await state.setPostingPolicy('c_group', 'admins');
      expect(state.conversations.first.postingRestricted, isTrue);
      expect(state.conversations.first.currentRole, 'owner');
      expect(state.conversations.first.unreadCount, 5);
    });

    test(
        'shouldDropRestrictedPost with AppState drops posts from non-admins in restricted conversations',
        () {
      final api = _FakeApi();
      final state = createAppState(api: api)
        ..conversations = <Conversation>[
          Conversation(
              id: 'c_restricted', kind: 'group', postingRestricted: true),
        ];
      state.governanceOverrideForTesting =
          (_) => testGovernanceRecord(adminsOnly: true);

      // acct_member is below admin -> dropped
      expect(
        shouldDropRestrictedPost(
          record: state.governanceOf('c_restricted'),
          sender: 'acct_member',
          channelId: null,
          serverRestricts: state.serverRestrictsPosting('c_restricted', null),
        ),
        isTrue,
      );

      // acct_mod is moderator (below admin) -> dropped
      expect(
        shouldDropRestrictedPost(
          record: state.governanceOf('c_restricted'),
          sender: 'acct_mod',
          channelId: null,
          serverRestricts: state.serverRestrictsPosting('c_restricted', null),
        ),
        isTrue,
      );

      // acct_admin -> kept
      expect(
        shouldDropRestrictedPost(
          record: state.governanceOf('c_restricted'),
          sender: 'acct_admin',
          channelId: null,
          serverRestricts: state.serverRestrictsPosting('c_restricted', null),
        ),
        isFalse,
      );

      // acct_owner -> kept
      expect(
        shouldDropRestrictedPost(
          record: state.governanceOf('c_restricted'),
          sender: 'acct_owner',
          channelId: null,
          serverRestricts: state.serverRestrictsPosting('c_restricted', null),
        ),
        isFalse,
      );

      // No governance record -> shouldDropRestrictedPost returns false (no drop without verified record)
      state.governanceOverrideForTesting = null;
      expect(
        shouldDropRestrictedPost(
          record: state.governanceOf('c_restricted'),
          sender: 'acct_member',
          channelId: null,
          serverRestricts: state.serverRestrictsPosting('c_restricted', null),
        ),
        isFalse,
      );

      // Announcement channel in open group
      final channelState = createAppState(api: api)
        ..conversations = <Conversation>[
          Conversation(id: 'c_open', kind: 'group', postingRestricted: false),
        ]
        ..channelsByCommunity = {
          'comm_1': [
            Channel(
                id: 'ch_ann',
                communityId: 'comm_1',
                name: 'news',
                kind: 'announcement'),
          ],
        };
      channelState.governanceOverrideForTesting =
          (_) => testGovernanceRecord(announcements: {'ch_ann'});

      expect(
        shouldDropRestrictedPost(
          record: channelState.governanceOf('c_open'),
          sender: 'acct_member',
          channelId: 'ch_ann',
          serverRestricts:
              channelState.serverRestrictsPosting('c_open', 'ch_ann'),
        ),
        isTrue,
      );
    });
  });

  group('C2: UI restrictions in ChatScreen Composer & CommunityScreen', () {
    testWidgets(
        'ChatScreen composer shows restriction and disables input for restricted members',
        (tester) async {
      final api = _FakeApi();
      final state = createAppState(api: api, accountId: 'acct_member')
        ..conversations = [
          Conversation(
              id: 'c_restricted',
              kind: 'group',
              postingRestricted: true,
              currentRole: 'member'),
        ];

      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatScreen(state: state, conversationId: 'c_restricted'),
      ));
      await tester.pumpAndSettle();

      // Check for lock icon in TextField and restricted hint
      expect(
        find.descendant(
            of: find.byType(TextField),
            matching: find.byIcon(Icons.lock_outline)),
        findsOneWidget,
      );
      expect(
          find.text(AppLocalizationsEn().chatPostingRestricted), findsWidgets);

      // Verify TextField is disabled
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.enabled, isFalse);

      // Verify send button is disabled (IconButton with Icons.send has onPressed: null)
      final sendFinder = find.widgetWithIcon(IconButton, Icons.send);
      expect(sendFinder, findsOneWidget);
      final sendButton = tester.widget<IconButton>(sendFinder);
      expect(sendButton.onPressed, isNull);

      // Verify attach button is disabled
      final attachFinder = find.widgetWithIcon(IconButton, Icons.attach_file);
      expect(attachFinder, findsOneWidget);
      final attachButton = tester.widget<IconButton>(attachFinder);
      expect(attachButton.onPressed, isNull);

      // Clean up timer
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets(
        'ChatScreen composer remains enabled for admins in restricted conversations',
        (tester) async {
      final api = _FakeApi();
      final state = createAppState(api: api, accountId: 'acct_admin')
        ..conversations = [
          Conversation(
              id: 'c_restricted',
              kind: 'group',
              postingRestricted: true,
              currentRole: 'admin'),
        ];

      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatScreen(state: state, conversationId: 'c_restricted'),
      ));
      await tester.pumpAndSettle();

      // Lock icon in composer is NOT present
      expect(
        find.descendant(
            of: find.byType(TextField),
            matching: find.byIcon(Icons.lock_outline)),
        findsNothing,
      );
      expect(find.text(AppLocalizationsEn().chatComposerHint), findsOneWidget);

      // Verify TextField is enabled
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.enabled, isTrue);

      // Clean up timer
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets(
        'CommunityCard shows create channel button only for admins/owners',
        (tester) async {
      final api = _FakeApi();
      // 1. As Member
      final memberState = createAppState(api: api, accountId: 'acct_member')
        ..communities = [
          Community(
              id: 'comm_1',
              name: 'Community One',
              sharedConversationId: 'c_shared'),
        ]
        ..conversations = [
          Conversation(
              id: 'c_shared',
              kind: 'community_shared',
              communityId: 'comm_1',
              currentRole: 'member'),
        ];

      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CommunityScreen(state: memberState),
      ));
      await tester.pumpAndSettle();

      // No "New channel" icon button for member
      expect(find.byTooltip(AppLocalizationsEn().communityNewChannel),
          findsNothing);

      // 2. As Admin
      final adminState = createAppState(api: api, accountId: 'acct_admin')
        ..communities = [
          Community(
              id: 'comm_1',
              name: 'Community One',
              sharedConversationId: 'c_shared'),
        ]
        ..conversations = [
          Conversation(
              id: 'c_shared',
              kind: 'community_shared',
              communityId: 'comm_1',
              currentRole: 'admin'),
        ];

      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CommunityScreen(state: adminState),
      ));
      await tester.pumpAndSettle();

      // "New channel" icon button IS shown for admin
      expect(find.byTooltip(AppLocalizationsEn().communityNewChannel),
          findsOneWidget);
    });
  });

  group('C2: CryptoService governanceOf safe defaults', () {
    test('UnavailableCryptoService and TestOnlyCryptoService return null', () {
      final unavail = UnavailableCryptoService();
      expect(unavail.governanceOf('conv_1'), isNull);

      final testOnly = TestOnlyCryptoService();
      expect(testOnly.governanceOf('conv_1'), isNull);
    });

    test(
        'NativeCryptoService.governanceOf returns null without active device or record',
        () {
      if (nativeCryptoSkip() != false) return;
      final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
      final service = NativeCryptoService(
        bindings: bindings,
        localStore: MemoryLocalStore(),
      );
      expect(service.governanceOf('conv_unknown'), isNull);
    });
  });
}
