import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// C1 actions of [AppState]: what reaches the server, and what stays local.
void main() {
  test('an invitation link is made locally and only its locator is sent',
      () async {
    final api = _Api();
    final state = _state(api);
    final url = await state.createInviteLink(InviteTargetKind.group, 'conv_1');

    expect(url, isNotNull);
    final link = MembershipInviteLink.tryParse(
      url!,
      expectedOrigin: 'https://localhost:8080',
    );
    expect(link, isNotNull);
    expect(api.createdLocators, <String>[link!.locator]);
    expect(api.createdTargets, <String>['group:conv_1']);
    final secret = Uri.parse(url).fragment.substring(3);
    expect(api.createdLocators.single, isNot(contains(secret)));
    expect(state.errorFor(Ops.membership), isNull);
  });

  test('a link of another server is refused before any request', () async {
    final api = _Api();
    final state = _state(api);
    final foreign = MembershipInviteLink.generate(origin: 'https://evil.test');

    final result = await state.previewInviteLink(foreign.url);

    expect(result, isNull);
    expect(api.previewed, isEmpty);
    final message = state.errorFor(Ops.membership)!;
    expect(message, isNot(contains('evil.test')));
    final secret = Uri.parse(foreign.url).fragment.substring(3);
    expect(message, isNot(contains(secret)));
  });

  test('a good link is previewed with its locator; a dead one says so',
      () async {
    final api = _Api();
    final state = _state(api);
    final link =
        MembershipInviteLink.generate(origin: 'https://localhost:8080');

    final good = await state.previewInviteLink('  ${link.url}\n');
    expect(good, isNotNull);
    expect(good!.preview.inviterUsername, 'alice');
    expect(api.previewed, <String>[link.locator]);

    api.previewStatus = 404;
    final dead = await state.previewInviteLink(link.url);
    expect(dead, isNull);
    expect(state.errorFor(Ops.membership), isNotNull);
    expect(state.errorFor(Ops.membership), isNot(contains(link.locator)));
  });

  test('approving asks reconcile for the target group; declining does not',
      () async {
    final api = _Api();
    final state = _state(api);
    final request = JoinRequest(
      id: 'jreq_1',
      kind: InviteTargetKind.group,
      status: JoinRequestStatus.pending,
      createdAt: DateTime.utc(2026, 11, 7),
      targetId: 'conv_1',
      accountId: 'acct_alice',
      username: 'alice',
    );

    expect(await state.decideJoinRequest(request, approve: false), isTrue);
    expect(api.decisions, <String>['jreq_1:reject']);

    expect(await state.decideJoinRequest(request, approve: true), isTrue);
    expect(api.decisions, <String>['jreq_1:reject', 'jreq_1:approve']);
  });

  test('a refused decision reports the server error and returns false',
      () async {
    final api = _Api()..decideStatus = 409;
    final state = _state(api);
    final request = JoinRequest(
      id: 'jreq_1',
      kind: InviteTargetKind.community,
      status: JoinRequestStatus.pending,
      createdAt: DateTime.utc(2026, 11, 7),
      targetId: 'comm_1',
    );
    expect(await state.decideJoinRequest(request, approve: true), isFalse);
    expect(state.errorFor(Ops.membership), isNotNull);
  });

  test('leaving a community drops it and every one of its channels', () async {
    final api = _Api();
    final state = _state(api)
      ..communities = <Community>[
        Community(id: 'comm_1', name: 'Club'),
        Community(id: 'comm_2', name: 'Other'),
      ]
      ..channelsByCommunity = <String, List<Channel>>{
        'comm_1': <Channel>[
          Channel(
              id: 'chan_1',
              communityId: 'comm_1',
              name: 'general',
              kind: 'private'),
        ],
        'comm_2': <Channel>[],
      }
      ..conversations = <Conversation>[
        Conversation(
            id: 'conv_1', kind: 'community_channel', communityId: 'comm_1'),
        Conversation(
            id: 'conv_2', kind: 'community_channel', communityId: 'comm_1'),
        Conversation(
            id: 'conv_3', kind: 'community_channel', communityId: 'comm_2'),
        Conversation(id: 'conv_4', kind: 'group'),
      ];

    expect(await state.leaveCommunity('comm_1'), isTrue);

    expect(api.removed, <String>['comm_1:me']);
    expect(state.communities.map((c) => c.id), <String>['comm_2']);
    expect(state.channelsByCommunity.keys, <String>['comm_2']);
    expect(state.conversations.map((c) => c.id), <String>['conv_3', 'conv_4']);
  });

  test(
      'the last owner cannot leave: the server refusal is shown, nothing drops',
      () async {
    final api = _Api()..removeStatus = 409;
    final state = _state(api)
      ..communities = <Community>[Community(id: 'comm_1', name: 'Club')]
      ..conversations = <Conversation>[
        Conversation(
            id: 'conv_1', kind: 'community_channel', communityId: 'comm_1'),
      ];

    expect(await state.leaveCommunity('comm_1'), isFalse);

    expect(state.communities, hasLength(1));
    expect(state.conversations, hasLength(1));
    expect(state.errorFor(Ops.membership), isNotNull);
  });

  test('removing a member takes them off every cached channel roster',
      () async {
    final api = _Api();
    final state = _state(api)
      ..membersByConversation = <String, List<ConversationMember>>{
        'conv_1': <ConversationMember>[
          ConversationMember(accountId: 'acct_owner', role: 'owner'),
          ConversationMember(accountId: 'acct_bob', role: 'member'),
        ],
        'conv_9': <ConversationMember>[
          ConversationMember(accountId: 'acct_bob', role: 'member'),
        ],
      };

    expect(await state.removeCommunityMember('comm_1', 'acct_bob'), isTrue);

    expect(api.removed, <String>['comm_1:acct_bob']);
    expect(state.membersFor('conv_1').map((m) => m.accountId),
        <String>['acct_owner']);
    // A roster of a conversation outside the community is left alone.
    expect(state.membersFor('conv_9'), hasLength(1));
  });
}

AppState _state(ApiClient api) {
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _SyncService(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'https://localhost:8080',
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
      username: 'owner',
    );
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  final List<String> createdLocators = <String>[];
  final List<String> createdTargets = <String>[];
  final List<String> previewed = <String>[];
  final List<String> decisions = <String>[];
  final List<String> removed = <String>[];
  int previewStatus = 200;
  int decideStatus = 200;
  int removeStatus = 200;

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
    createdTargets.add('${kind.wire}:$targetId');
    return MembershipInvite(
      id: 'minv_1',
      maxUses: maxUses,
      uses: 0,
      expiresAt: DateTime.utc(2026, 11, 14),
    );
  }

  @override
  Future<InvitePreview> previewMembershipInvite(
    String token,
    String locator,
  ) async {
    previewed.add(locator);
    if (previewStatus != 200) throw ApiException(previewStatus);
    return InvitePreview(
      kind: InviteTargetKind.group,
      targetName: 'Hikers',
      inviterUsername: 'alice',
      expiresAt: DateTime.utc(2026, 11, 14),
      alreadyMember: false,
    );
  }

  @override
  Future<JoinRequest> decideJoinRequest(
    String token,
    String requestId, {
    required bool approve,
  }) async {
    if (decideStatus != 200) {
      throw ApiException(decideStatus, '{"error":"join_request_resolved"}');
    }
    decisions.add('$requestId:${approve ? 'approve' : 'reject'}');
    return JoinRequest(
      id: requestId,
      kind: InviteTargetKind.group,
      status: approve ? JoinRequestStatus.approved : JoinRequestStatus.rejected,
      createdAt: DateTime.utc(2026, 11, 7),
    );
  }

  @override
  Future<CommunityRemoval> removeCommunityMember(
    String token,
    String communityId,
    String accountId,
  ) async {
    if (removeStatus != 200) {
      throw ApiException(removeStatus, '{"error":"last_owner_required"}');
    }
    removed.add('$communityId:$accountId');
    return const CommunityRemoval(<({String conversationId, int? eventId})>[
      (conversationId: 'conv_1', eventId: 7),
      (conversationId: 'conv_2', eventId: 8),
    ]);
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
