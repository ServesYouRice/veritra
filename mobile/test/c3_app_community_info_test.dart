import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/community_info_codec.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'native_test_env.dart';

// C3 in the app: names fall back to the legacy server name, and the edit UI
// follows the verified role state only (D80).

const _session = Session(
    baseUrl: 'https://example.test',
    token: 'token',
    accountId: 'alice',
    deviceId: 'dev');

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _Roles implements VerifiedRoleSource {
  _Roles(this.state);
  final GovernanceState? state;
  final asked = <String>[];
  @override
  GovernanceState? governanceOf(String conversationId) {
    asked.add(conversationId);
    return state;
  }

  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) =>
      false;
}

AppState _state() {
  final state = AppState(
      apiClientFactory: (_) => ApiClient(baseUrl: 'https://example.test'),
      syncServiceFactory: (_, __) => _QuietSync(),
      localStore: MemoryLocalStore(),
      cryptoService: UnavailableCryptoService());
  state.session = _session;
  state.communities = [
    Community(id: 'comm', name: 'Club', sharedConversationId: 'conv_shared'),
    Community(id: 'legacy', name: ''),
  ];
  return state;
}

/// No MLS, but it can seal info records: a send reaches the session queue
/// and stops there, which is what the deadlock needed.
class _InfoCrypto extends UnavailableCryptoService
    implements CommunityInfoCryptoService {
  _InfoCrypto(this.bindings);
  final NativeCryptoBindings bindings;
  @override
  CommunityInfoCodec get communityInfoCodec => CommunityInfoCodec(bindings);
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');
  int puts = 0;
  final putTokens = <String>[];
  final channelKinds = <String>[];
  void Function()? onPut;

  @override
  Future<ChannelCreation> createChannel(
      String token, String communityId, String name,
      {String kind = 'private'}) async {
    channelKinds.add(kind);
    return ChannelCreation(
      channel: Channel(
          id: 'chan_${'2' * 32}',
          communityId: communityId,
          name: name,
          kind: kind,
          conversationId: kind == 'private' ? 'conv_private' : 'conv_shared',
          layoutGeneration: 1),
      conversation: Conversation(
          id: kind == 'private' ? 'conv_private' : 'conv_shared',
          kind: kind == 'private' ? 'community_channel' : 'community_shared',
          communityId: communityId,
          createdBy: 'alice'),
    );
  }

  final records = <String, ({int version, String keyId, Uint8List blob})>{};

  @override
  Future<({int version, String keyId, Uint8List blob})?> getInfoRecord(
          String token,
          {required String kind,
          required String subjectId,
          String? communityId}) async =>
      records['$kind|$subjectId'];

  @override
  Future<int> putInfoRecord(String token,
      {required String kind,
      required String subjectId,
      String? communityId,
      required String keyId,
      required List<int> blob,
      required int expectedVersion}) async {
    puts++;
    putTokens.add(token);
    final version = expectedVersion + 1;
    records['$kind|$subjectId'] =
        (version: version, keyId: keyId, blob: Uint8List.fromList(blob));
    onPut?.call();
    return version;
  }
}

class _RosterApi extends _Api {
  String role = 'member';
  int rosterReads = 0;

  @override
  Future<List<ConversationMember>> communityMembers(
      String token, String communityId) async {
    rosterReads++;
    return [ConversationMember(accountId: 'alice', role: role)];
  }

  @override
  Future<List<({String kind, String id, int version, String keyId})>>
      infoVersions(String token,
              {List<String> communityIds = const [],
              List<String> categoryIds = const [],
              List<String> channelIds = const []}) async =>
          [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('names fall back to the legacy server name, then to none', () {
    final state = _state();
    expect(state.communityDisplayName(state.communities[0]), 'Club');
    expect(state.communityDisplayName(state.communities[1]), isNull);
    final channel =
        Channel(id: 'chan', communityId: 'comm', name: ' ', kind: 'private');
    expect(state.channelDisplayName(channel), isNull);
    expect(state.channelTopic(channel), isNull);
  });

  test('the edit UI follows the verified role state of the shared group', () {
    final state = _state();
    // No verified role record: nobody edits (D80).
    expect(state.mayEditCommunityInfo('comm', 'channel'), isFalse);
    expect(state.mayEditCommunityInfo('comm', 'community'), isFalse);

    final roles = _Roles(GovernanceState(
        rev: 1, owner: 'bob', ownerRev: 1, joined: const {'alice': 1}));
    state.debugInfoRoleSource = roles;
    // A plain member edits channel info (D80) but not the community's.
    expect(state.mayEditCommunityInfo('comm', 'channel'), isTrue);
    expect(state.mayEditCommunityInfo('comm', 'community'), isFalse);
    expect(roles.asked, everyElement('conv_shared'));

    state.debugInfoRoleSource = _Roles(GovernanceState(
        rev: 1,
        owner: 'bob',
        ownerRev: 1,
        admins: const {'alice': 1},
        joined: const {'alice': 1}));
    expect(state.mayEditCommunityInfo('comm', 'community'), isTrue);
    // A community without the shared-group layout has no C3 info at all.
    expect(state.mayEditCommunityInfo('legacy', 'channel'), isFalse);
  });

  test('without the native crypto service nothing is published', () async {
    final state = _state();
    expect(await state.publishCommunityInfo('comm', name: 'Club'), isFalse);
    // A refresh is a quiet no-op.
    await state.refreshCommunityInfo();
  });

  test('promotion during a session enables a retained rotation', () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final api = _RosterApi();
    final store = MemoryLocalStore();
    final state = AppState(
        apiClientFactory: (_) => api,
        syncServiceFactory: (_, __) => _QuietSync(),
        localStore: store,
        cryptoService: _InfoCrypto(bindings));
    addTearDown(state.dispose);
    state.session = _session;
    state.api = api;
    final id = 'comm_${'1' * 32}';
    state.communities = [
      Community(id: id, name: 'Club', sharedConversationId: 'conv_shared'),
    ];
    state.communitiesLoaded = true;
    expect(
        await state.publishCommunityInfo(id, name: 'Club', mint: true), isTrue);
    await store.saveSetting(
        'c3.rotation_due.alice', '{"community|$id":{"c":"$id","t":"pending"}}');
    await state.refreshCommunityInfo();
    expect(
        (await store.loadCommunityInfoEvents(
            CommunityInfoEventKind.key, 'community', id)),
        hasLength(1));
    api.role = 'owner';
    await state.refreshCommunityInfo();
    expect(api.rosterReads, 2);
    // Rotation starts after promotion. Sending remains unavailable in this
    // fixture, so the new key and pending mark stay for a later retry.
    expect(
        (await store.loadCommunityInfoEvents(
            CommunityInfoEventKind.key, 'community', id)),
        hasLength(2));
    expect(
        await store.loadSetting('c3.rotation_due.alice'), contains('pending'));
  }, skip: nativeCryptoSkip());

  test('explicit private creation uses its own conversation and info key',
      () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final api = _Api();
    final store = MemoryLocalStore();
    final state = AppState(
        apiClientFactory: (_) => api,
        syncServiceFactory: (_, __) => _QuietSync(),
        localStore: store,
        cryptoService: _InfoCrypto(bindings));
    addTearDown(state.dispose);
    state.session = _session;
    state.api = api;
    final id = 'comm_${'1' * 32}';
    state.communities = [
      Community(id: id, name: 'Club', sharedConversationId: 'conv_shared'),
    ];
    // C2's client guard: the creator holds the owner role.
    state.conversations = [
      Conversation(
          id: 'conv_shared',
          kind: 'community_shared',
          communityId: id,
          createdBy: 'alice',
          currentRole: 'owner'),
    ];
    expect(
        await state.publishCommunityInfo(id, name: 'Club', mint: true), isTrue);
    final channel = await state.createChannel(id, 'secret', kind: 'private');
    expect(channel?.kind, 'private');
    expect(channel?.conversationId, 'conv_private');
    expect(api.channelKinds, ['private']);
    // Wait for the outside-session-queue publish, then inspect the sealed
    // record: private info must not reuse the community's shared key.
    for (var i = 0; i < 100 && api.puts < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final communityRecord = api.records['community|$id']!;
    final channelRecord = api.records['channel|${channel!.id}']!;
    expect(channelRecord.keyId, isNot(communityRecord.keyId));
    final events = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, 'channel', channel.id);
    expect(events.single.conversationId, 'conv_private');
  }, skip: nativeCryptoSkip());

  test('the info service uses a rotated session token', () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final api = _Api();
    final state = AppState(
        apiClientFactory: (_) => api,
        syncServiceFactory: (_, __) => _QuietSync(),
        localStore: MemoryLocalStore(),
        cryptoService: _InfoCrypto(bindings));
    state.session = _session;
    state.api = api;
    final id = 'comm_${'1' * 32}';
    state.communities = [
      Community(id: id, name: 'Club', sharedConversationId: 'conv_shared'),
    ];
    expect(
        await state.publishCommunityInfo(id, name: 'Club', mint: true), isTrue);
    state.session = const Session(
        baseUrl: 'https://example.test',
        token: 'rotated-token',
        accountId: 'alice',
        deviceId: 'dev');
    expect(await state.publishCommunityInfo(id, name: 'Renamed'), isTrue);
    expect(api.putTokens, ['token', 'rotated-token']);
    expect(state.communityDisplayName(state.communities.single), 'Renamed');
  }, skip: nativeCryptoSkip());

  test('an upload finishing after sign-out is not cached or announced',
      () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final api = _Api();
    final store = MemoryLocalStore();
    final state = AppState(
        apiClientFactory: (_) => api,
        syncServiceFactory: (_, __) => _QuietSync(),
        localStore: store,
        cryptoService: _InfoCrypto(bindings));
    state.session = _session;
    state.api = api;
    final id = 'comm_${'1' * 32}';
    state.communities = [
      Community(id: id, name: 'Club', sharedConversationId: 'conv_shared'),
    ];
    api.onPut = () => state.session = null;
    expect(await state.publishCommunityInfo(id, name: 'Club', mint: true),
        isFalse);
    expect(api.puts, 1);
    expect(await store.loadAcceptedCommunityInfo('community', id), isNull);
    expect(state.errorFor(Ops.communityInfo), isNull);
  }, skip: nativeCryptoSkip());

  test('an editor never promotes an unseen server revision over its snapshot',
      () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final api = _Api();
    final state = AppState(
        apiClientFactory: (_) => api,
        syncServiceFactory: (_, __) => _QuietSync(),
        localStore: MemoryLocalStore(),
        cryptoService: _InfoCrypto(bindings));
    state.session = _session;
    state.api = api;
    final id = 'comm_${'1' * 32}';
    state.communities = [
      Community(id: id, name: 'Club', sharedConversationId: 'conv_shared'),
    ];
    expect(
        await state.publishCommunityInfo(id, name: 'Club', mint: true), isTrue);
    final first = api.records['community|$id']!;
    api.records['community|$id'] =
        (version: 2, keyId: first.keyId, blob: first.blob);
    expect(await state.publishCommunityInfo(id, name: 'My edit'), isFalse);
    expect(api.puts, 1);
    expect(state.communityDisplayName(state.communities.single), 'Club');
  }, skip: nativeCryptoSkip());

  test('creating a channel never waits on its own info sends (no deadlock)',
      () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final api = _Api();
    final state = AppState(
        apiClientFactory: (_) => api,
        syncServiceFactory: (_, __) => _QuietSync(),
        localStore: MemoryLocalStore(),
        cryptoService: _InfoCrypto(bindings));
    state.session = _session;
    state.api = api;
    state.communities = [
      Community(
          id: 'comm_${'1' * 32}',
          name: 'Club',
          sharedConversationId: 'conv_shared'),
    ];
    state.communitiesLoaded = true;
    state.conversations = [
      Conversation(
          id: 'conv_shared',
          kind: 'community_shared',
          communityId: 'comm_${'1' * 32}',
          createdBy: 'alice',
          currentRole: 'owner'),
    ];
    // As the creator would at creation: the community record, under a new
    // community key.
    expect(
        await state
            .publishCommunityInfo('comm_${'1' * 32}', name: 'Club', mint: true)
            .timeout(const Duration(seconds: 10)),
        isTrue);
    expect(api.puts, 1);
    await state
        .createChannel('comm_${'1' * 32}', 'general')
        .timeout(const Duration(seconds: 10));
    // The record publish runs after, outside the queue, and a later queued
    // operation still completes.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(api.puts, greaterThanOrEqualTo(3));
    await state
        .createChannel('comm_${'1' * 32}', 'second')
        .timeout(const Duration(seconds: 10));
  }, skip: nativeCryptoSkip());
}
