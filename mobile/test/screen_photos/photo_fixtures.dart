// U38: the shared fixtures of the screen photographs.
//
// Everything is deterministic and offline. An [ApiClient] built here never
// reaches a network: its HttpClient records the request and fails, so a
// screen that asks for something no fake answers shows its error or empty
// state, and the photograph's JSON lists the request under "networkCalls".
import 'dart:async';
import 'dart:io';

import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_commands.dart'
    show GovernanceCommands;
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import '../goldens/golden_harness.dart';
import '../test_crypto_service.dart';

/// Requests that reached the offline network since [PhotoNet.reset].
class PhotoNet {
  static final List<String> calls = <String>[];
  static void reset() => calls.clear();
}

/// An HttpClient that records the request and refuses it.
class PhotoHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    // Method and path only: never a query, a body or a token.
    PhotoNet.calls.add('$method ${url.path}');
    throw const SocketException('screen photographs run offline');
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A plain API client that is offline and records what it was asked.
ApiClient offlineApi([String baseUrl = 'https://chat.example.org']) =>
    ApiClient(baseUrl: baseUrl, httpClient: PhotoHttpClient());

class PhotoSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();
  @override
  Stream<Map<String, Object?>> get events => _controller.stream;
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() => _controller.close();
}

/// Answers the calls the community and membership screens make.
class PhotoApi extends FixtureApi {
  PhotoApi() : super(httpClient: PhotoHttpClient());

  /// What the conversation list endpoint answers; [richState] fills it.
  List<Conversation> conversationList = <Conversation>[];

  @override
  Future<List<Conversation>> conversations(String token) async =>
      conversationList;

  @override
  Future<List<ConversationMember>> communityMembers(
    String token,
    String id,
  ) async =>
      <ConversationMember>[
        ConversationMember(
          accountId: 'acct_owner',
          role: 'owner',
          username: 'owner',
        ),
        ConversationMember(
          accountId: 'acct_alice',
          role: 'member',
          username: 'alice',
        ),
        ConversationMember(
          accountId: 'acct_bob',
          role: 'member',
          username: 'bob',
        ),
      ];

  @override
  Future<List<ConversationMember>> conversationMembers(
    String token,
    String conversationId,
  ) async =>
      photoMembers;

  @override
  Future<ModerationState> moderationState(
    String token,
    String communityId,
  ) async =>
      const ModerationState(
        invitesPausedUntil: null,
        slowModeSeconds: <String, int>{'chan_open': 30},
      );

  @override
  Future<List<ModerationEvent>> moderationEvents(
    String token,
    String communityId,
  ) async =>
      <ModerationEvent>[
        ModerationEvent(
          id: 'ev_1',
          actor: 'acct_owner',
          target: 'acct_bob',
          channelId: null,
          action: 'timeout',
          createdAt: DateTime.utc(2025, 3, 12, 9),
        ),
      ];

  @override
  Future<List<CommunityBan>> communityBans(
    String token,
    String communityId,
  ) async =>
      <CommunityBan>[
        CommunityBan(
          accountId: 'acct_carol',
          username: 'carol',
          bannedBy: 'acct_owner',
          createdAt: DateTime.utc(2025, 3, 10, 9),
        ),
      ];

  @override
  Future<List<MembershipInvite>> listMembershipInvites(
    String token,
    InviteTargetKind kind,
    String targetId,
  ) async =>
      <MembershipInvite>[
        MembershipInvite(
          id: 'minv_1',
          maxUses: 10,
          uses: 3,
          expiresAt: DateTime.utc(2025, 3, 21),
        ),
      ];

  @override
  Future<List<DepartedTimeout>> departedTimeouts(
    String token,
    String communityId,
  ) async =>
      const <DepartedTimeout>[];

  @override
  Future<List<JoinRequest>> listJoinRequests(
    String token,
    InviteTargetKind kind,
    String targetId,
  ) async =>
      <JoinRequest>[
        JoinRequest(
          id: 'jr_1',
          kind: kind,
          status: JoinRequestStatus.pending,
          createdAt: DateTime.utc(2025, 3, 14, 8),
          accountId: 'acct_alice',
          username: 'alice',
        ),
      ];

  @override
  Future<List<JoinRequest>> listOwnJoinRequests(String token) async =>
      <JoinRequest>[
        JoinRequest(
          id: 'jr_2',
          kind: InviteTargetKind.group,
          status: JoinRequestStatus.pending,
          createdAt: DateTime.utc(2025, 3, 13, 8),
          targetName: 'Hikers',
        ),
      ];

  @override
  Future<List<BlockedAccount>> listBlocks(String token) async =>
      <BlockedAccount>[
        BlockedAccount(
          accountId: 'acct_carol',
          username: 'carol',
          createdAt: DateTime.utc(2025, 3, 1),
        ),
      ];
}

/// The people of every group in the fixtures.
final List<ConversationMember> photoMembers = <ConversationMember>[
  ConversationMember(accountId: 'acct_owner', role: 'owner', username: 'owner'),
  ConversationMember(accountId: 'acct_alice', role: 'admin', username: 'alice'),
  ConversationMember(accountId: 'acct_bob', role: 'member', username: 'bob'),
];

/// A group's verified role record, for the roles screen.
class PhotoRolesCrypto extends TestOnlyCryptoService
    implements MlsConversationCryptoService, RoleCommandCryptoService {
  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  Future<GovernanceView?> governanceView(String groupId) async =>
      GovernanceView(
        record: GovernanceState(
          rev: 2,
          owner: 'acct_owner',
          ownerRev: 1,
          admins: const {'acct_alice': 1},
        ),
        roster: const {'acct_owner', 'acct_alice', 'acct_bob'},
        observations: null,
      );

  @override
  Future<void> stageRoleChange(
    String groupId,
    GovernanceState Function(
      GovernanceCommands commands,
      GovernanceObservations? observed,
      DateTime now,
    ) build,
  ) async =>
      throw UnimplementedError('stageRoleChange');
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

/// The goldens' signed-in state (alice, bob, two groups, one chat with
/// history) plus: a community the owner runs with an open and a private
/// channel, a message request from carol, and a group with three members.
Future<AppState> richState({String role = 'owner'}) async {
  final api = PhotoApi();
  final state = await connectedState(api: api);
  final community = Community(
    id: 'comm_1',
    name: 'Hikers',
    createdBy: 'acct_owner',
    sharedConversationId: 'conv_shared',
  );
  state
    ..session = Session(
      baseUrl: 'https://chat.example.org',
      token: 'fixture-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
      username: 'owner',
      role: role,
    )
    ..communities = <Community>[community]
    ..channelsByCommunity = <String, List<Channel>>{
      community.id: <Channel>[
        Channel(
          id: 'chan_open',
          communityId: community.id,
          name: 'Trail talk',
          kind: 'open',
          conversationId: 'conv_shared',
          layoutGeneration: 1,
        ),
        Channel(
          id: 'chan_private',
          communityId: community.id,
          name: 'Leaders',
          kind: 'private',
          conversationId: 'conv_leaders',
          layoutGeneration: 1,
        ),
      ],
    }
    ..conversations = <Conversation>[
      ...state.conversations,
      Conversation(
        id: 'conv_shared',
        kind: 'community_shared',
        communityId: community.id,
        currentRole: 'owner',
        lastMessageAt: DateTime.utc(2025, 3, 12, 8),
      ),
      Conversation(
        id: 'conv_leaders',
        kind: 'community_channel',
        communityId: community.id,
        channelId: 'chan_private',
        currentRole: 'owner',
        lastMessageAt: DateTime.utc(2025, 3, 11, 8),
      ),
      Conversation(
        id: 'conv_carol',
        kind: 'dm',
        peerAccountId: 'acct_carol',
        peerUsername: 'carol',
        createdBy: 'acct_carol',
        lastMessageAt: DateTime.utc(2025, 3, 14, 7),
        unreadCount: 1,
      ),
    ]
    ..membersByConversation = <String, List<ConversationMember>>{
      'conv_design': photoMembers,
      'conv_ops': photoMembers,
      'conv_shared': photoMembers,
      'conv_leaders': photoMembers,
    }
    ..debugInfoRoleSource = _Roles(
      GovernanceState(
        rev: 1,
        owner: 'acct_owner',
        ownerRev: 1,
        joined: const {'acct_owner': 1},
      ),
    );
  api.conversationList = List<Conversation>.of(state.conversations);
  return state;
}

/// A signed-in state with no history, for screens that need only a session.
AppState plainState({
  String role = 'member',
  ApiClient? api,
  CryptoService? crypto,
}) {
  final client = api ?? offlineApi();
  return AppState(
    apiClientFactory: (_) => client,
    cryptoService: crypto ?? TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => PhotoSync(),
  )
    ..api = client
    ..session = Session(
      baseUrl: 'https://chat.example.org',
      token: 'fixture-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
      username: 'owner',
      role: role,
    );
}
