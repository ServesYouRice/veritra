import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_commands.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

// C2 (docs/designs/C2-admin-only-posting.md): the admins-only switch is a
// server setting and a C4 record commit. A record commit that fails is kept
// and retried on later sync passes until the record says so, so a server
// that later reports posting as open cannot let members' posts through. The
// server's word only stops a retry; it never writes the record.

const _group = 'conv_c2_retry';
const _shared = 'conv_c2_shared';
const _community = 'comm_c2';
const _news = 'chan_news';

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');

  @override
  Future<Conversation> setPostingPolicy(
    String token,
    String conversationId,
    String policy,
  ) async =>
      Conversation(
        id: conversationId,
        kind: 'group',
        postingRestricted: policy == 'admins',
      );
}

/// A native service whose role record is a fake: [failures] role commits
/// fail as if another commit were pending, the rest apply at once.
class _Roles extends TestNativeCryptoService {
  _Roles({required super.bindings, required super.localStore});

  GovernanceState record = GovernanceState.genesis('acct_me');
  int failures = 0;
  int staged = 0;

  @override
  Future<GovernanceView?> governanceView(String groupId) async =>
      GovernanceView(
        record: record,
        roster: const {'acct_me', 'acct_bob'},
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
  ) async {
    staged++;
    if (failures > 0) {
      failures--;
      throw const GovernanceCommandException('commit_pending');
    }
    record = build(
      GovernanceCommands(
        state: record,
        actor: 'acct_me',
        members: const {'acct_me', 'acct_bob'},
        epoch: 1,
      ),
      null,
      DateTime.now().toUtc(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(AppState, _Roles, MemoryLocalStore)> app() async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final store = MemoryLocalStore();
    final crypto = _Roles(bindings: bindings, localStore: store);
    final api = _Api();
    final state = AppState(
      apiClientFactory: (_) => api,
      syncServiceFactory: (_, __) => _QuietSync(),
      localStore: store,
      cryptoService: crypto,
    );
    addTearDown(state.dispose);
    state
      ..session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: 'acct_me',
        deviceId: 'dev_me',
      )
      ..api = api
      ..conversations = [Conversation(id: _group, kind: 'group')];
    return (state, crypto, store);
  }

  String setting() => PostingRecordRetry.postingSetting(_group);
  String announced() => PostingRecordRetry.announceSetting(_shared);

  Channel channel(String kind) => Channel(
        id: _news,
        communityId: _community,
        name: '',
        kind: kind,
        conversationId: _shared,
        layoutGeneration: 1,
      );

  /// A shared group that owes [_news] to its record; the community's
  /// channel list is loaded when [listed] is given.
  Future<(AppState, _Roles, MemoryLocalStore)> community({
    Channel? listed,
  }) async {
    final (state, crypto, store) = await app();
    state
      ..conversations = [Conversation(id: _shared, kind: 'community_shared')]
      ..communities = [
        Community(id: _community, name: '', sharedConversationId: _shared),
      ];
    if (listed != null) {
      state
        ..channelsByCommunity = {
          _community: [listed],
        }
        ..communitiesLoaded = true;
    }
    await store.saveSetting(announced(), '["$_news"]');
    return (state, crypto, store);
  }

  test(
    'a failed record write is kept and lands on a later sync pass',
    () async {
      final (state, crypto, store) = await app();
      crypto.failures = 1;
      await state.setPostingPolicy(_group, 'admins');
      expect(crypto.staged, 1);
      expect(crypto.record.adminsOnlyPosting, isFalse);
      expect(await store.loadSetting(setting()), 'admins');

      await state.retryPostingRecordsForTesting();
      expect(crypto.record.adminsOnlyPosting, isTrue);
      // Found written on the next pass: nothing more is owed.
      await state.retryPostingRecordsForTesting();
      expect(await store.loadSetting(setting()), isEmpty);
      expect(crypto.staged, 2);
    },
    skip: nativeCryptoSkip(),
  );

  test(
    'a setting changed on the server since is not written back',
    () async {
      final (state, crypto, store) = await app();
      crypto.failures = 1;
      await state.setPostingPolicy(_group, 'admins');
      // Another admin opened posting again meanwhile.
      state.conversations = [
        Conversation(id: _group, kind: 'group', postingRestricted: false),
      ];
      await state.retryPostingRecordsForTesting();
      expect(crypto.record.adminsOnlyPosting, isFalse);
      expect(crypto.staged, 1);
      expect(await store.loadSetting(setting()), isEmpty);
    },
    skip: nativeCryptoSkip(),
  );

  test(
    'a device no longer an admin under the record stops trying',
    () async {
      final (state, crypto, store) = await app();
      crypto.failures = 1;
      await state.setPostingPolicy(_group, 'admins');
      crypto.record = GovernanceState(
        rev: 2,
        owner: 'acct_bob',
        ownerRev: 1,
      );
      await state.retryPostingRecordsForTesting();
      expect(crypto.staged, 1);
      expect(await store.loadSetting(setting()), isEmpty);
    },
    skip: nativeCryptoSkip(),
  );

  test(
    'an owed announcement channel lands on a later sync pass',
    () async {
      final (state, crypto, store) = await community(
        listed: channel('announcement'),
      );
      crypto.failures = 1;
      await state.retryPostingRecordsForTesting();
      expect(crypto.record.announcementChannels, isEmpty);
      expect(await store.loadSetting(announced()), '["$_news"]');
      await state.retryPostingRecordsForTesting();
      expect(crypto.record.announcementChannels, {_news});
      await state.retryPostingRecordsForTesting();
      expect(await store.loadSetting(announced()), isEmpty);
      expect(crypto.staged, 2);
    },
    skip: nativeCryptoSkip(),
  );

  test(
    'a channel the server no longer lists as announcement is not written',
    () async {
      final (state, crypto, store) = await community(listed: channel('open'));
      await state.retryPostingRecordsForTesting();
      expect(crypto.record.announcementChannels, isEmpty);
      expect(crypto.staged, 0);
      expect(await store.loadSetting(announced()), isEmpty);
    },
    skip: nativeCryptoSkip(),
  );

  test(
    'an owed announcement channel is kept while the channel list is unloaded',
    () async {
      final (state, crypto, store) = await community();
      await state.retryPostingRecordsForTesting();
      expect(crypto.staged, 0);
      expect(await store.loadSetting(announced()), '["$_news"]');
      // Loaded later: written then.
      state
        ..channelsByCommunity = {
          _community: [channel('announcement')],
        }
        ..communitiesLoaded = true;
      await state.retryPostingRecordsForTesting();
      expect(crypto.record.announcementChannels, {_news});
    },
    skip: nativeCryptoSkip(),
  );
}
