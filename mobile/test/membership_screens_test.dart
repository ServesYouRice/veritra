import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/communities/membership_screens.dart';
import 'package:private_messenger/features/communities/moderation_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'invite_binding_fixtures.dart';
import 'test_crypto_service.dart';

const _origin = 'https://localhost:8080';

void main() {
  group('join by link', () {
    testWidgets('a link of another server is refused without echoing it',
        (tester) async {
      final api = _Api();
      final state = _state(api);
      final foreign = newInviteLink(origin: 'https://evil.test');
      await tester.pumpWidget(_app(JoinByLinkScreen(state: state)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), foreign.url);
      await tester.pump();
      await tester.tap(find.text('Check link'));
      await tester.pumpAndSettle();

      expect(find.text('This is not an invitation link for this server.'),
          findsOneWidget);
      expect(find.textContaining('evil.test'), findsOneWidget,
          reason: 'only the text field holds what was typed');
      expect(api.previewed, isEmpty);
      expect(find.text('Ask to join'), findsNothing);
    });

    testWidgets('preview, ask to join, then the request is listed',
        (tester) async {
      final api = _Api();
      final state = _state(api);
      final link = newInviteLink(origin: _origin);
      api.link = link;
      await tester.pumpWidget(_app(JoinByLinkScreen(state: state)));
      await tester.pumpAndSettle();
      expect(find.text('No requests yet.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), link.url);
      await tester.pump();
      await tester.tap(find.text('Check link'));
      await tester.pumpAndSettle();

      expect(find.text('Hikers'), findsOneWidget);
      expect(find.text('Invited by alice'), findsOneWidget);
      expect(find.text('Ask to join'), findsOneWidget);
      expect(api.previewed, <String>[link.locator]);

      await tester.tap(find.text('Ask to join'));
      await tester.pumpAndSettle();

      expect(api.requested, <String>[link.locator]);
      expect(
          find.text(
              'Request sent. It stays under Your requests until someone decides.'),
          findsOneWidget);
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.text('Ask to join'), findsNothing);
      // The secret is dropped from the field once the request is made.
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
    });

    testWidgets('a dead link says so, and a member is told they are in',
        (tester) async {
      final api = _Api()..previewDead = true;
      final state = _state(api);
      final link = newInviteLink(origin: _origin);
      api.link = link;
      await tester.pumpWidget(_app(JoinByLinkScreen(state: state)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), link.url);
      await tester.pump();
      await tester.tap(find.text('Check link'));
      await tester.pumpAndSettle();
      expect(find.text('This link no longer works. Ask for a new one.'),
          findsOneWidget);

      api
        ..previewDead = false
        ..alreadyMember = true;
      await tester.tap(find.text('Check link'));
      await tester.pumpAndSettle();
      expect(find.text('You are already a member.'), findsOneWidget);
      expect(find.text('Ask to join'), findsNothing);
    });
  });

  group('invitations and requests', () {
    testWidgets('a created link is shown once and can be copied',
        (tester) async {
      final api = _Api();
      final state = _state(api);
      String? copied;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(_app(Scaffold(
        body: SingleChildScrollView(
          child: MembershipInvitesPanel(
            state: state,
            kind: InviteTargetKind.community,
            targetId: 'comm_1',
          ),
        ),
      )));
      await tester.pumpAndSettle();
      expect(find.text('No active links.'), findsOneWidget);

      await tester.tap(find.text('Create invitation link'));
      await tester.pumpAndSettle();

      final url = api.createdLocators.single;
      expect(url, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(find.textContaining('Copy this link now. It is not stored'),
          findsOneWidget);
      final shown = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .single
          .data!;
      expect(shown, startsWith('$_origin/join#v2.'));
      final made =
          MembershipInviteLink.tryParse(shown, expectedOrigin: _origin)!;
      expect(made.locator, url);
      // The binding sent with the link verifies against it, for this account
      // and device and the key the engine reports.
      final sent = api.createdBindings.single;
      expect(sent.signingKey, testDeviceSigningKey);
      expect(
          made.bindingTag(
            kind: InviteTargetKind.community,
            targetId: 'comm_1',
            inviterAccountId: 'acct_owner',
            inviterDeviceId: 'dev_owner',
            inviterSigningKey: testDeviceSigningKey,
          ),
          sent.tag);
      expect(
          sent.signature,
          fakeInviteSignature(
            testDeviceSigningKey,
            made.bindingMessage(
              kind: InviteTargetKind.community,
              targetId: 'comm_1',
              inviterAccountId: 'acct_owner',
              inviterDeviceId: 'dev_owner',
              inviterSigningKey: testDeviceSigningKey,
            ),
          ));

      await tester.tap(find.byTooltip('Copy link'));
      await tester.pump();
      expect(copied, shown);
    });

    testWidgets('an admin approves or declines a request by username',
        (tester) async {
      final api = _Api()
        ..pending = <JoinRequest>[
          JoinRequest(
            id: 'jreq_1',
            kind: InviteTargetKind.group,
            status: JoinRequestStatus.pending,
            createdAt: DateTime.utc(2026, 11, 7),
            targetId: 'conv_1',
            accountId: 'acct_alice',
            username: 'alice',
          ),
          JoinRequest(
            id: 'jreq_2',
            kind: InviteTargetKind.group,
            status: JoinRequestStatus.pending,
            createdAt: DateTime.utc(2026, 11, 7),
            targetId: 'conv_1',
            accountId: 'acct_bob',
            username: 'bob',
          ),
        ];
      final state = _state(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group', currentRole: 'owner'),
        ];
      await tester.pumpWidget(_app(Scaffold(
        body: SingleChildScrollView(
          child: JoinRequestsPanel(
            state: state,
            kind: InviteTargetKind.group,
            targetId: 'conv_1',
          ),
        ),
      )));
      await tester.pumpAndSettle();
      expect(find.text('@alice'), findsOneWidget);
      expect(find.text('@bob'), findsOneWidget);

      await tester.tap(find.byTooltip('Approve @alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Decline @bob'));
      await tester.pumpAndSettle();

      expect(api.decisions, <String>['jreq_1:approve', 'jreq_2:reject']);
      expect(find.text('No one is waiting.'), findsOneWidget);
    });
  });

  group('moderation (C5)', () {
    testWidgets(
        'an owner bans from the member menu and times out with a length',
        (tester) async {
      final api = _Api();
      final state = _state(api);
      await tester.pumpWidget(_app(CommunityDetailsScreen(
        state: state,
        community: Community(id: 'comm_1', name: 'Club'),
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Moderate @alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Time out…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 h'));
      await tester.pumpAndSettle();
      expect(api.moderation, <String>['timeout:comm_1:acct_alice:3600']);

      await tester.tap(find.byTooltip('Moderate @alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lift timeout'));
      await tester.pumpAndSettle();
      expect(api.moderation.last, 'timeout:comm_1:acct_alice:0');

      await tester.tap(find.byTooltip('Moderate @alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ban…'));
      await tester.pumpAndSettle();
      expect(find.text('Ban @alice?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Ban'));
      await tester.pumpAndSettle();
      expect(api.moderation.last, 'ban:comm_1:acct_alice');
      expect(find.byTooltip('Moderate @alice'), findsNothing);
      // The banned account leaves the channel's local roster, as for a removal.
      state.membersByConversation['conv_chan']
          ?.forEach((m) => expect(m.accountId, isNot('acct_alice')));
    });

    testWidgets('a moderator can ban but not lift bans or pause invitations',
        (tester) async {
      final api = _Api();
      final state = _state(api);
      state.channelsByCommunity = <String, List<Channel>>{};
      await tester.pumpWidget(_app(ModerationScreen(
        state: state,
        community: Community(id: 'comm_1', name: 'Club'),
      )));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Lift ban for @bob'), findsNothing);
      expect(find.text('Pause invitations'), findsNothing);
      expect(find.text('ACTIVITY LOG'), findsNothing);
      expect(find.text('BANNED ACCOUNTS'), findsOneWidget);
    });

    testWidgets('a plain member sees no moderation entry', (tester) async {
      final api = _Api()..me = 'acct_alice';
      final state = _state(api);
      state.session = const Session(
        baseUrl: _origin,
        token: 'tok',
        accountId: 'acct_alice',
        deviceId: 'dev_alice',
        username: 'alice',
      );
      await tester.pumpWidget(_app(CommunityDetailsScreen(
        state: state,
        community: Community(id: 'comm_1', name: 'Club'),
      )));
      await tester.pumpAndSettle();
      expect(find.text('Moderation'), findsNothing);
    });

    testWidgets('the moderation screen lists bans, slow mode and the log',
        (tester) async {
      final api = _Api();
      final state = _state(api);
      state.channelsByCommunity = <String, List<Channel>>{
        'comm_1': <Channel>[
          Channel(
              id: 'chan_1',
              communityId: 'comm_1',
              name: 'general',
              kind: 'open'),
        ],
      };
      await tester.pumpWidget(_app(ModerationScreen(
        state: state,
        community: Community(id: 'comm_1', name: 'Club'),
        canManageInvites: true,
      )));
      await tester.pumpAndSettle();

      expect(find.text('@bob'), findsWidgets);
      expect(find.text('One message every 30 s'), findsOneWidget);
      expect(find.text('@owner banned @bob'), findsOneWidget);
      expect(find.text('Invitation links work normally.'), findsOneWidget);

      await tester.tap(find.text('general'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 min'));
      await tester.pumpAndSettle();
      expect(api.moderation, <String>['slow:comm_1:chan_1:300']);

      await tester.tap(find.text('Pause invitations'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 d'));
      await tester.pumpAndSettle();
      expect(api.moderation.last, 'pause:comm_1:86400');

      await tester.tap(find.byTooltip('Lift ban for @bob'));
      await tester.pumpAndSettle();
      expect(api.moderation.last, 'unban:comm_1:acct_bob');
      expect(find.text('Nobody is banned.'), findsOneWidget);
    });
  });

  group('community details', () {
    testWidgets('an owner sees usernames, roles, removal, invitations',
        (tester) async {
      final api = _Api();
      final state = _state(api);
      await tester.pumpWidget(_app(CommunityDetailsScreen(
        state: state,
        community: Community(id: 'comm_1', name: 'Club'),
      )));
      await tester.pumpAndSettle();

      expect(find.text('@owner'), findsOneWidget);
      expect(find.text('@alice'), findsOneWidget);
      expect(find.byTooltip('Moderate @alice'), findsOneWidget);
      expect(find.byTooltip('Moderate @owner'), findsNothing);
      expect(find.text('INVITATION LINKS'), findsOneWidget);
      expect(find.text('JOIN REQUESTS'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Leave community'), 200);
      expect(find.text('Leave community'), findsOneWidget);
      await tester.scrollUntilVisible(find.byTooltip('Moderate @alice'), -200);

      await tester.tap(find.byTooltip('Moderate @alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Remove @alice from the community?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(api.removed, <String>['comm_1:acct_alice']);
      expect(find.byTooltip('Moderate @alice'), findsNothing);
    });

    testWidgets('a plain member can only leave', (tester) async {
      final api = _Api()..me = 'acct_alice';
      final state = _state(api);
      state.session = const Session(
        baseUrl: _origin,
        token: 'tok',
        accountId: 'acct_alice',
        deviceId: 'dev_alice',
        username: 'alice',
      );
      await tester.pumpWidget(_app(CommunityDetailsScreen(
        state: state,
        community: Community(id: 'comm_1', name: 'Club'),
      )));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Moderate @owner'), findsNothing);
      expect(find.text('INVITATION LINKS'), findsNothing);
      expect(find.text('JOIN REQUESTS'), findsNothing);
      expect(find.text('Leave community'), findsOneWidget);
    });
  });
}

Widget _app(Widget child) => MaterialApp(home: child);

AppState _state(ApiClient api) {
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _SyncService(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: _origin,
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
      username: 'owner',
    );
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: _origin);

  final List<String> createdLocators = <String>[];
  final List<({List<int> signingKey, String tag, List<int> signature})>
      createdBindings =
      <({List<int> signingKey, String tag, List<int> signature})>[];
  MembershipInviteLink? link;
  final List<String> previewed = <String>[];
  final List<String> requested = <String>[];
  final List<String> decisions = <String>[];
  final List<String> removed = <String>[];
  List<JoinRequest> pending = <JoinRequest>[];
  final List<JoinRequest> own = <JoinRequest>[];
  final List<MembershipInvite> invites = <MembershipInvite>[];
  bool previewDead = false;
  bool alreadyMember = false;
  String me = 'acct_owner';
  final Set<String> gone = <String>{};

  @override
  Future<MembershipInvite> createMembershipInvite(
    String token,
    InviteTargetKind kind,
    String targetId, {
    required String locator,
    required List<int> signingKey,
    required String bindingTag,
    required List<int> bindingSignature,
    int maxUses = 10,
    Duration lifetime = const Duration(days: 7),
  }) async {
    createdLocators.add(locator);
    createdBindings.add((
      signingKey: signingKey,
      tag: bindingTag,
      signature: bindingSignature,
    ));
    final invite = MembershipInvite(
      id: 'minv_${invites.length + 1}',
      maxUses: maxUses,
      uses: 0,
      expiresAt: DateTime.utc(2026, 11, 14),
    );
    invites.add(invite);
    return invite;
  }

  @override
  Future<List<MembershipInvite>> listMembershipInvites(
    String token,
    InviteTargetKind kind,
    String targetId,
  ) async =>
      List<MembershipInvite>.of(invites);

  @override
  Future<InvitePreview> previewMembershipInvite(
    String token,
    String locator,
  ) async {
    previewed.add(locator);
    if (previewDead) throw ApiException(404, '{"error":"not_found"}');
    return InvitePreview(
      kind: InviteTargetKind.group,
      targetName: 'Hikers',
      inviterUsername: 'alice',
      expiresAt: DateTime.utc(2026, 11, 14),
      alreadyMember: alreadyMember,
      binding: honestBinding(link!),
    );
  }

  @override
  Future<JoinRequest> requestToJoin(String token, String locator) async {
    requested.add(locator);
    final request = JoinRequest(
      id: 'jreq_${own.length + 1}',
      kind: InviteTargetKind.group,
      status: JoinRequestStatus.pending,
      createdAt: DateTime.utc(2026, 11, 7),
      targetName: 'Hikers',
      binding: honestBinding(link!),
    );
    own.add(request);
    return request;
  }

  @override
  Future<List<JoinRequest>> listOwnJoinRequests(String token) async =>
      List<JoinRequest>.of(own);

  @override
  Future<List<JoinRequest>> listJoinRequests(
    String token,
    InviteTargetKind kind,
    String targetId,
  ) async =>
      List<JoinRequest>.of(pending);

  @override
  Future<JoinRequest> decideJoinRequest(
    String token,
    String requestId, {
    required bool approve,
  }) async {
    decisions.add('$requestId:${approve ? 'approve' : 'reject'}');
    final request = pending.firstWhere((r) => r.id == requestId);
    pending = pending.where((r) => r.id != requestId).toList();
    return request;
  }

  @override
  Future<List<ConversationMember>> communityMembers(
    String token,
    String communityId,
  ) async =>
      <ConversationMember>[
        ConversationMember(
            accountId: 'acct_owner', role: 'owner', username: 'owner'),
        if (!gone.contains('acct_alice'))
          ConversationMember(
              accountId: 'acct_alice', role: 'member', username: 'alice'),
      ];

  final List<String> moderation = <String>[];
  bool bobBanned = true;

  @override
  Future<CommunityRemoval> banCommunityMember(
      String token, String communityId, String accountId) async {
    moderation.add('ban:$communityId:$accountId');
    gone.add(accountId);
    return const CommunityRemoval(<({String conversationId, int? eventId})>[
      (conversationId: 'conv_chan', eventId: 9),
    ]);
  }

  @override
  Future<CommunityRemoval> kickCommunityMember(
      String token, String communityId, String accountId) async {
    moderation.add('kick:$communityId:$accountId');
    gone.add(accountId);
    return const CommunityRemoval(<({String conversationId, int? eventId})>[]);
  }

  @override
  Future<void> unbanCommunityMember(
      String token, String communityId, String accountId) async {
    moderation.add('unban:$communityId:$accountId');
    bobBanned = false;
  }

  @override
  Future<void> setMemberTimeout(
      String token, String communityId, String accountId, int seconds) async {
    moderation.add('timeout:$communityId:$accountId:$seconds');
  }

  @override
  Future<void> setChannelSlowMode(
      String token, String communityId, String channelId, int seconds) async {
    moderation.add('slow:$communityId:$channelId:$seconds');
  }

  @override
  Future<void> setInvitesPaused(
      String token, String communityId, int seconds) async {
    moderation.add('pause:$communityId:$seconds');
  }

  @override
  Future<List<CommunityBan>> communityBans(
          String token, String communityId) async =>
      <CommunityBan>[
        if (bobBanned)
          CommunityBan(
            accountId: 'acct_bob',
            username: 'bob',
            bannedBy: 'acct_owner',
            createdAt: DateTime.utc(2026, 11, 7),
          ),
      ];

  @override
  Future<ModerationState> moderationState(
          String token, String communityId) async =>
      const ModerationState(
        invitesPausedUntil: null,
        slowModeSeconds: <String, int>{'chan_1': 30},
      );

  @override
  Future<List<ModerationEvent>> moderationEvents(
          String token, String communityId) async =>
      <ModerationEvent>[
        ModerationEvent(
          id: 'mod_1',
          actor: 'acct_owner',
          target: 'acct_bob',
          channelId: null,
          action: 'ban',
          createdAt: DateTime.utc(2026, 11, 7),
        ),
      ];

  @override
  Future<CommunityRemoval> removeCommunityMember(
    String token,
    String communityId,
    String accountId,
  ) async {
    removed.add('$communityId:$accountId');
    gone.add(accountId);
    return const CommunityRemoval(<({String conversationId, int? eventId})>[]);
  }
}

class _SyncService implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {
    _controller.close();
  }
}
