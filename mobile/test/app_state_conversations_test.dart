// Conversation-facing AppState state: refresh ownership across session
// changes (TASK-027).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const _alice = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token-alice',
  accountId: 'acct_alice',
  deviceId: 'dev_alice',
);
const _bob = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token-bob',
  accountId: 'acct_bob',
  deviceId: 'dev_bob',
);

String _owner(String token) => token == _bob.token ? 'bob' : 'alice';

/// Answers per token. A gate set for a token holds that call until it is
/// completed, so a response can land after the session changed.
class _RefreshApi extends ApiClient {
  _RefreshApi() : super(baseUrl: 'https://localhost:8080');

  final Map<String, Completer<void>> conversationGate = {};
  final Map<String, Completer<void>> communityGate = {};
  final Map<String, Completer<void>> channelGate = {};
  final Map<String, Completer<void>> inviteGate = {};
  final Set<String> held = <String>{};
  bool failInvites = false;

  Future<void> _wait(Map<String, Completer<void>> gates, String key) async {
    final gate = gates.remove(key);
    if (gate == null) return;
    held.add(key);
    await gate.future;
  }

  @override
  Future<List<Conversation>> conversations(String token) async {
    await _wait(conversationGate, token);
    return <Conversation>[
      Conversation(
        id: 'conv_${_owner(token)}',
        kind: 'group',
        createdBy: 'acct_${_owner(token)}',
      ),
    ];
  }

  @override
  Future<List<Community>> listCommunities(String token) async {
    await _wait(communityGate, token);
    return <Community>[
      Community(id: 'comm_${_owner(token)}', name: _owner(token)),
    ];
  }

  @override
  Future<List<Channel>> listChannels(String token, String communityId) async {
    await _wait(channelGate, token);
    return <Channel>[
      Channel(
        id: 'chan_${_owner(token)}',
        communityId: communityId,
        name: 'general',
        kind: 'text',
      ),
    ];
  }

  @override
  Future<List<Invite>> listInvites(String token) async {
    await _wait(inviteGate, token);
    if (failInvites) throw ApiException(500, '{"error":"internal"}');
    return <Invite>[
      Invite(id: 'inv_${_owner(token)}', code: 'code', maxUses: 1, uses: 0),
    ];
  }

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      const <SyncEvent>[];

  @override
  Future<List<BlockedAccount>> listBlocks(String token) async =>
      const <BlockedAccount>[];

  @override
  Future<bool> readReceiptsEnabled(String token) async => true;

  @override
  Future<void> logout(String token) async {}
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}

AppState _stateFor(LocalStore store, _RefreshApi api) => AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
    );

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('condition not reached');
}

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('TASK-027: a refresh started under one session', () {
    late MemoryLocalStore store;
    late _RefreshApi api;
    late AppState state;

    setUp(() async {
      store = MemoryLocalStore();
      api = _RefreshApi();
      await store.saveSession(_alice);
      state = _stateFor(store, api);
      await state.tryRestoreSession();
      await _settle();
      expect(state.session?.accountId, _alice.accountId);
    });

    tearDown(() => state.dispose());

    /// Signs Alice out; with [asBob], Bob then signs in on the device.
    Future<void> switchAway({required bool asBob}) async {
      await state.logout();
      expect(state.session, isNull);
      if (!asBob) return;
      await store.saveSession(_bob);
      await state.tryRestoreSession();
      await _settle();
      expect(state.session?.accountId, _bob.accountId);
      expect(state.conversations.map((c) => c.id), <String>['conv_bob']);
    }

    for (final asBob in <bool>[false, true]) {
      final after = asBob ? 'after Bob signs in' : 'after logout';

      test('conversations: publishes nothing $after', () async {
        final gate = api.conversationGate[_alice.token] = Completer<void>();
        final refresh = state.refreshConversations();
        await _waitFor(() => api.held.contains(_alice.token));
        await switchAway(asBob: asBob);
        if (asBob) state.composerDrafts.setText('conv_bob', 'hello bob');
        final conversations = state.conversations;
        final loaded = state.conversationsLoaded;
        final snapshot = await store.loadSnapshot();
        var notified = 0;
        state.addListener(() => notified++);

        gate.complete();
        await refresh;
        await _settle();

        expect(state.conversations, same(conversations));
        expect(state.conversationsLoaded, loaded);
        expect(state.errorFor(Ops.conversations), isNull);
        expect(
            (await store.loadSnapshot())
                ?.conversations
                .map((c) => c.id)
                .toList(),
            snapshot?.conversations.map((c) => c.id).toList());
        if (asBob) {
          expect(state.composerDrafts.textFor('conv_bob'), 'hello bob');
        }
        expect(notified, 0, reason: 'a stale refresh notified listeners');
      });

      test('communities: publishes nothing $after', () async {
        await _waitFor(() => state.communitiesLoaded);
        final gate = api.communityGate[_alice.token] = Completer<void>();
        final refresh = state.refreshCommunities();
        await _waitFor(() => api.held.contains(_alice.token));
        await switchAway(asBob: asBob);
        await _waitFor(() => !asBob || state.communitiesLoaded);
        final communities = state.communities;
        final channels = state.channelsByCommunity;
        final loaded = state.communitiesLoaded;
        var notified = 0;
        state.addListener(() => notified++);

        gate.complete();
        await refresh;
        await _settle();

        expect(state.communities, same(communities));
        expect(state.channelsByCommunity, same(channels));
        expect(state.communitiesLoaded, loaded);
        expect(notified, 0, reason: 'a stale refresh notified listeners');
      });

      test('channels: publishes nothing $after', () async {
        await _waitFor(() => state.communitiesLoaded);
        final gate = api.channelGate[_alice.token] = Completer<void>();
        final refresh = state.refreshCommunities();
        await _waitFor(() => api.held.contains(_alice.token));
        await switchAway(asBob: asBob);
        await _waitFor(() => !asBob || state.communitiesLoaded);
        final communities = state.communities;
        final channels = state.channelsByCommunity;
        final loaded = state.communitiesLoaded;
        var notified = 0;
        state.addListener(() => notified++);

        gate.complete();
        await refresh;
        await _settle();

        expect(state.communities, same(communities));
        expect(state.channelsByCommunity, same(channels));
        expect(state.communitiesLoaded, loaded);
        expect(notified, 0, reason: 'a stale refresh notified listeners');
      });

      test('invites: publishes nothing $after', () async {
        await _waitFor(() => state.invitesLoaded);
        final gate = api.inviteGate[_alice.token] = Completer<void>();
        final refresh = state.refreshInvites();
        await _waitFor(() => api.held.contains(_alice.token));
        await switchAway(asBob: asBob);
        await _waitFor(() => !asBob || state.invitesLoaded);
        final invites = state.invites;
        final loaded = state.invitesLoaded;
        final failed = state.invitesLoadFailed;
        var notified = 0;
        state.addListener(() => notified++);

        gate.complete();
        await refresh;
        await _settle();

        expect(state.invites, same(invites));
        expect(state.invitesLoaded, loaded);
        expect(state.invitesLoadFailed, failed);
        expect(notified, 0, reason: 'a stale refresh notified listeners');
      });

      test('invites: a stale failure is not recorded $after', () async {
        await _waitFor(() => state.invitesLoaded);
        final gate = api.inviteGate[_alice.token] = Completer<void>();
        final refresh = state.refreshInvites();
        await _waitFor(() => api.held.contains(_alice.token));
        await switchAway(asBob: asBob);
        await _waitFor(() => !asBob || state.invitesLoaded);
        final failed = state.invitesLoadFailed;
        api.failInvites = true;

        gate.complete();
        await refresh;
        await _settle();

        expect(state.invitesLoadFailed, failed);
      });
    }

    test('a refresh for the still-current session publishes as before',
        () async {
      final gate = api.conversationGate[_alice.token] = Completer<void>();
      final refresh = state.refreshConversations();
      await _waitFor(() => api.held.contains(_alice.token));
      var notified = 0;
      state.addListener(() => notified++);
      gate.complete();
      await refresh;
      expect(state.conversations.map((c) => c.id), <String>['conv_alice']);
      expect(state.conversationsLoaded, isTrue);
      expect(notified, greaterThan(0));
      expect((await store.loadSnapshot())?.conversations.map((c) => c.id),
          <String>['conv_alice']);

      await state.refreshCommunities();
      expect(state.communities.map((c) => c.id), <String>['comm_alice']);
      expect(state.channelsByCommunity['comm_alice']?.map((c) => c.id),
          <String>['chan_alice']);
      await state.refreshInvites();
      expect(state.invites.map((i) => i.id), <String>['inv_alice']);
    });
  });
}
