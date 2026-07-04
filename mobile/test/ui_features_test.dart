import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/format.dart';

void main() {
  test('conversation parses community, channel, and retention metadata', () {
    final conversation = Conversation.fromJson(<String, Object?>{
      'id': 'conv_1',
      'kind': 'community_channel',
      'title': 'general',
      'community_id': 'comm_1',
      'channel_id': 'chan_1',
      'retention_seconds': 86400,
      'created_at': '2026-06-01T10:00:00Z',
    });
    expect(conversation.isChannel, isTrue);
    expect(conversation.communityId, 'comm_1');
    expect(conversation.channelId, 'chan_1');
    expect(conversation.retentionSeconds, 86400);
    expect(conversation.createdAt, isNotNull);
  });

  test('invite parses code, uses, and expiry', () {
    final invite = Invite.fromJson(<String, Object?>{
      'id': 'inv_1',
      'code': 'JOINCODE',
      'created_by': 'acct_owner',
      'max_uses': 5,
      'uses': 1,
      'expires_at': '2026-07-09T00:00:00Z',
      'created_at': '2026-07-02T00:00:00Z',
    });
    expect(invite.code, 'JOINCODE');
    expect(invite.maxUses, 5);
    expect(invite.uses, 1);
    expect(invite.expiresAt, isNotNull);
  });

  test('shortId compacts long identifiers and keeps short ones', () {
    expect(shortId('acct_0123456789abcdef'), 'acct_012…cdef');
    expect(shortId('short'), 'short');
  });

  test('startConversation creates a titled group and selects it', () async {
    final api = FakeFeatureApiClient();
    final state = _connectedState(api);

    final created = await state.startConversation(
      kind: 'group',
      title: 'Family',
      memberAccountIds: <String>['acct_other'],
    );

    expect(created, isNotNull);
    expect(api.lastConversationBody?['kind'], 'group');
    expect(api.lastConversationBody?['title'], 'Family');
    expect(
      api.lastConversationBody?['member_account_ids'],
      <String>['acct_other'],
    );
    expect(state.selectedConversationId, created!.id);
    expect(state.conversations.first.id, created.id);
  });

  test('createInvite records the invite for this session', () async {
    final api = FakeFeatureApiClient();
    final state = _connectedState(api);

    final invite = await state.createInvite(maxUses: 5);

    expect(invite?.code, 'JOINCODE');
    expect(state.invites, hasLength(1));
  });

  test('createCommunity then createChannel opens a channel conversation',
      () async {
    final api = FakeFeatureApiClient();
    final state = _connectedState(api);

    final community = await state.createCommunity('Neighborhood');
    expect(community, isNotNull);
    expect(state.communities, hasLength(1));

    await state.createChannel(community!.id, 'general');
    expect(state.channelsByCommunity[community.id], hasLength(1));
    expect(api.lastConversationBody?['kind'], 'community_channel');
    expect(api.lastConversationBody?['community_id'], community.id);
    expect(state.conversations, isNotEmpty);
  });

  test('registerWithInvite establishes a session', () async {
    final api = FakeFeatureApiClient();
    final localStore = MemoryLocalStore();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    );

    await state.registerWithInvite(
      'http://localhost:8080',
      'JOINCODE',
      'alice',
      'correct horse battery staple',
    );

    expect(state.error, isNull);
    expect(state.session?.token, 'registered-token');
    expect((await localStore.loadSession())?.token, 'registered-token');
  });

  test('deleteAccount clears the local session entirely', () async {
    final api = FakeFeatureApiClient();
    final localStore = MemoryLocalStore();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'http://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      );
    await localStore.saveSession(state.session!);

    await state.deleteAccount();

    expect(state.session, isNull);
    expect(await localStore.loadSession(), isNull);
  });
}

AppState _connectedState(ApiClient api) {
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => FakeSyncService(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'http://localhost:8080',
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
    );
}

class FakeFeatureApiClient extends ApiClient {
  FakeFeatureApiClient() : super(baseUrl: 'http://localhost:8080');

  Map<String, Object?>? lastConversationBody;
  var _conversationCounter = 0;

  @override
  Future<Conversation> createConversationDetailed(
    String token, {
    required String kind,
    String? title,
    String? communityId,
    String? channelId,
    List<String> memberAccountIds = const <String>[],
    int? retentionSeconds,
  }) async {
    lastConversationBody = <String, Object?>{
      'kind': kind,
      if (title != null) 'title': title,
      if (communityId != null) 'community_id': communityId,
      if (channelId != null) 'channel_id': channelId,
      if (memberAccountIds.isNotEmpty) 'member_account_ids': memberAccountIds,
    };
    _conversationCounter += 1;
    return Conversation(
      id: 'conv_$_conversationCounter',
      kind: kind,
      title: title,
      communityId: communityId,
      channelId: channelId,
    );
  }

  @override
  Future<Invite> createInvite(
    String token, {
    int maxUses = 1,
    DateTime? expiresAt,
  }) async {
    return Invite(
      id: 'inv_1',
      code: 'JOINCODE',
      maxUses: maxUses,
      uses: 0,
      expiresAt: expiresAt,
    );
  }

  @override
  Future<Community> createCommunity(String token, String name) async {
    return Community(id: 'comm_1', name: name);
  }

  @override
  Future<Channel> createChannel(
    String token,
    String communityId,
    String name, {
    String kind = 'text',
  }) async {
    return Channel(
      id: 'chan_1',
      communityId: communityId,
      name: name,
      kind: kind,
    );
  }

  @override
  Future<Session> register({
    required String inviteCode,
    required String username,
    required String password,
    required String deviceName,
    required List<int> deviceKeyPackage,
  }) async {
    return const Session(
      baseUrl: 'http://localhost:8080',
      token: 'registered-token',
      accountId: 'acct_new',
      deviceId: 'dev_new',
    );
  }

  @override
  Future<void> deleteAccount(String token) async {}

  @override
  Future<List<Conversation>> conversations(String token) async {
    return <Conversation>[];
  }

  @override
  Future<List<Device>> devices(String token) async {
    return <Device>[];
  }

  @override
  Future<List<ReceivedMessageEnvelope>> listMessages(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
    String? after,
  }) async {
    return <ReceivedMessageEnvelope>[];
  }

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    return <SyncEvent>[];
  }

  @override
  Future<void> markRead(
    String token,
    String conversationId,
    String messageId,
  ) async {}
}

class FakeSyncService implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  void dispose() {
    _controller.close();
  }
}
