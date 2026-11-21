import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/ban_verdict.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_commands.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

// C5 bans in the C4 record (record format 3; docs/crypto.md, "C4 record
// format 3"): a ban this device makes is owed to the community's record
// until a commit carries it; a lift leaves the record before the server.
// The commit-level rules and the removal commit itself are in
// c4_record_v3_test.dart and c4_adversarial_native_test.dart.

const _shared = 'conv_c5_shared';
const _community = 'comm_c5';
const _me = 'acct_me';
const _bob = 'acct_bob';

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

  final log = <String>[];
  bool unbanMissing = false;

  @override
  Future<CommunityRemoval> banCommunityMember(
    String token,
    String communityId,
    String accountId,
  ) async {
    log.add('ban $accountId');
    return const CommunityRemoval([]);
  }

  @override
  Future<void> unbanCommunityMember(
    String token,
    String communityId,
    String accountId,
  ) async {
    log.add('unban $accountId');
    if (unbanMissing) throw ApiException(404, '{"error":"not_found"}');
  }
}

/// A native service whose record and roster are fakes; role commits apply
/// at once as [_me], unless [failures] says the commit fails.
class _Roles extends TestNativeCryptoService {
  _Roles({required super.bindings, required super.localStore, this.log});

  final List<String>? log;
  GovernanceState record = GovernanceState(
    rev: 2,
    owner: _me,
    ownerRev: 0,
    joined: const {_me: 0, _bob: 1},
  );
  Set<String> roster = {_me, _bob};
  int failures = 0;
  int staged = 0;

  @override
  GovernanceState? governanceOf(String conversationId) =>
      conversationId == _shared ? record : null;

  @override
  Future<GovernanceView?> governanceView(String groupId) async =>
      GovernanceView(record: record, roster: roster, observations: null);

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
    log?.add('record');
    if (failures > 0) {
      failures--;
      throw const GovernanceCommandException('commit_pending');
    }
    record = build(
      GovernanceCommands(state: record, actor: _me, members: roster),
      null,
      DateTime.now().toUtc(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(AppState, _Roles, MemoryLocalStore, _Api)> app() async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final store = MemoryLocalStore();
    final api = _Api();
    final crypto = _Roles(bindings: bindings, localStore: store, log: api.log);
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
        accountId: _me,
        deviceId: 'dev_me',
      )
      ..api = api
      ..conversations = [
        Conversation(
          id: _shared,
          kind: 'community_shared',
          communityId: _community,
        ),
      ]
      ..communities = [
        Community(id: _community, name: '', sharedConversationId: _shared),
      ];
    return (state, crypto, store, api);
  }

  String owed() => banRecordOwedSetting(_shared);

  test(
    'a ban is owed to the record until a commit carries it',
    () async {
      final (state, crypto, store, api) = await app();
      expect(await state.banCommunityMember(_community, _bob), isTrue);
      expect(api.log, ['ban $_bob']);
      expect(
        decodeOwedBans(await store.loadSetting(owed()), DateTime.now()).keys,
        [_bob],
      );
      // Still in the MLS roster (its removal commit is pending): kept.
      await state.retryBanRecordsForTesting();
      expect(crypto.staged, 0);
      expect(
        decodeOwedBans(await store.loadSetting(owed()), DateTime.now()).keys,
        [_bob],
      );
      // Removed by a commit that did not carry the ban: this owner writes
      // it with a role-only commit, and the entry goes.
      crypto
        ..roster = {_me}
        ..record = crypto.record.removeAccount(_bob)
        ..failures = 1;
      await state.retryBanRecordsForTesting();
      expect(crypto.record.bans, isEmpty);
      expect(
        decodeOwedBans(await store.loadSetting(owed()), DateTime.now()).keys,
        [_bob],
      );
      await state.retryBanRecordsForTesting();
      expect(crypto.record.bans, {_bob});
      expect(await store.loadSetting(owed()), isEmpty);
      expect(state.recordBans(_community, _bob), isTrue);
    },
    skip: nativeCryptoSkip(),
  );

  test(
    'a moderator that cannot write the ban drops it once the account is '
    'gone',
    () async {
      final (state, crypto, store, _) = await app();
      crypto.record = GovernanceState(
        rev: 2,
        owner: 'acct_owner',
        ownerRev: 0,
        moderators: const {_me},
        joined: const {'acct_owner': 0, _me: 0},
      );
      crypto.roster = {'acct_owner', _me};
      await store.saveSetting(
        owed(),
        encodeOwedBans({
          _bob:
              DateTime.now().add(banRecordOwedLifetime).millisecondsSinceEpoch,
        }),
      );
      await state.retryBanRecordsForTesting();
      expect(crypto.staged, 0);
      expect(crypto.record.bans, isEmpty);
      expect(await store.loadSetting(owed()), isEmpty);
      expect(state.mayManageRecordBans(_community), isFalse);
    },
    skip: nativeCryptoSkip(),
  );

  test(
    'a lift leaves the record first, then the server',
    () async {
      final (state, crypto, _, api) = await app();
      crypto
        ..roster = {_me}
        ..record = crypto.record.removeAccount(_bob).copyWith(bans: {_bob});
      expect(await state.unbanCommunityMember(_community, _bob), isTrue);
      expect(api.log, ['record', 'unban $_bob']);
      expect(crypto.record.bans, isEmpty);
    },
    skip: nativeCryptoSkip(),
  );

  test(
    'a lift the record refuses never reaches the server',
    () async {
      final (state, crypto, _, api) = await app();
      crypto
        ..roster = {_me}
        ..record = crypto.record.removeAccount(_bob).copyWith(bans: {_bob})
        ..failures = 1;
      expect(await state.unbanCommunityMember(_community, _bob), isFalse);
      expect(api.log, ['record']);
      expect(crypto.record.bans, {_bob});
    },
    skip: nativeCryptoSkip(),
  );

  test(
    'a ban only the record holds is lifted there alone',
    () async {
      final (state, crypto, _, api) = await app();
      crypto
        ..roster = {_me}
        ..record = crypto.record.removeAccount(_bob).copyWith(bans: {_bob});
      api.unbanMissing = true;
      expect(await state.unbanCommunityMember(_community, _bob), isTrue);
      expect(crypto.record.bans, isEmpty);
      expect(state.recordBansOf(_community), isEmpty);
    },
    skip: nativeCryptoSkip(),
  );

  test(
    'an admin applies a server ban to the record',
    () async {
      final (state, crypto, _, _) = await app();
      crypto.roster = {_me};
      crypto.record = crypto.record.removeAccount(_bob);
      expect(state.recordBans(_community, _bob), isFalse);
      expect(state.mayManageRecordBans(_community), isTrue);
      expect(await state.applyBanToRecord(_community, _bob), isTrue);
      expect(crypto.record.bans, {_bob});
    },
    skip: nativeCryptoSkip(),
  );
}
