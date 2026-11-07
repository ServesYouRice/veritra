import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/communities/membership_screens.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const _origin = 'https://localhost:8080';

void main() {
  group('join by link', () {
    testWidgets('a link of another server is refused without echoing it',
        (tester) async {
      final api = _Api();
      final state = _state(api);
      final foreign =
          MembershipInviteLink.generate(origin: 'https://evil.test');
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
      final link = MembershipInviteLink.generate(origin: _origin);
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
      final link = MembershipInviteLink.generate(origin: _origin);
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
      expect(shown, startsWith('$_origin/join#v1.'));
      expect(
          MembershipInviteLink.tryParse(shown, expectedOrigin: _origin)!
              .locator,
          url);

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
      expect(find.byTooltip('Remove @alice'), findsOneWidget);
      expect(find.byTooltip('Remove @owner'), findsNothing);
      expect(find.text('INVITATION LINKS'), findsOneWidget);
      expect(find.text('JOIN REQUESTS'), findsOneWidget);
      expect(find.text('Leave community'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove @alice'));
      await tester.pumpAndSettle();
      expect(find.text('Remove @alice from the community?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(api.removed, <String>['comm_1:acct_alice']);
      expect(find.byTooltip('Remove @alice'), findsNothing);
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

      expect(find.byTooltip('Remove @owner'), findsNothing);
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
    int maxUses = 10,
    Duration lifetime = const Duration(days: 7),
  }) async {
    createdLocators.add(locator);
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
