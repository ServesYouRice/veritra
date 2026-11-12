import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

// C6 owner decision (2026-11-11): a report about a post in a private channel
// goes only to the verified moderators (owner and admins included) who are
// in that channel's MLS group. The shared conversation is unchanged.

const _community = 'comm_1';
const _shared = 'conv_shared';
const _private = 'conv_private';

class _RosterCrypto extends TestOnlyCryptoService
    implements MlsRosterCryptoService {
  final rosters = <String, Set<String>>{};
  final asked = <String>[];

  @override
  Set<String>? mlsAccountsOf(String conversationId) {
    asked.add(conversationId);
    return rosters[conversationId];
  }
}

class _Sync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

GovernanceState _record() => GovernanceState(
      rev: 1,
      owner: 'acct_owner',
      ownerRev: 0,
      admins: {'acct_admin': 1},
      moderators: {'acct_mod', 'acct_mod2'},
      joined: {
        'acct_owner': 0,
        'acct_admin': 1,
        'acct_mod': 2,
        'acct_mod2': 3,
        'acct_member': 4,
      },
    );

void main() {
  late _RosterCrypto crypto;
  late AppState state;

  setUp(() {
    crypto = _RosterCrypto();
    final api = ApiClient(baseUrl: 'https://localhost:8080');
    state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: crypto,
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _Sync(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'token_member',
        accountId: 'acct_member',
        deviceId: 'dev_member',
        username: 'acct_member',
      )
      ..communities = <Community>[
        Community(id: _community, name: 'c', sharedConversationId: _shared),
      ]
      ..conversations = <Conversation>[
        Conversation(
            id: _shared, kind: 'community_shared', communityId: _community),
        Conversation(
            id: _private, kind: 'community_channel', communityId: _community),
      ]
      // AppState judges a channel by its shared group's record.
      ..governanceOverrideForTesting =
          (id) => id == _shared || id == _private ? _record() : null;
  });

  test('the shared conversation reports to every verified moderator', () {
    crypto.rosters[_shared] = {'acct_member'};
    final moderators = state.reportModeratorsFor(_shared)!;
    expect(moderators.communityId, _community);
    expect(moderators.recordGroupId, _shared);
    expect(moderators.accounts,
        {'acct_owner', 'acct_admin', 'acct_mod', 'acct_mod2'});
    expect(crypto.asked, isEmpty,
        reason: 'the record group is not narrowed by any roster');
  });

  test('a private channel reports only to the moderators in its MLS group', () {
    // The admin and the second moderator are not in the channel; a member of
    // the channel without a role is no moderator.
    crypto.rosters[_private] = {'acct_owner', 'acct_mod', 'acct_member'};
    final moderators = state.reportModeratorsFor(_private)!;
    expect(moderators.accounts, {'acct_owner', 'acct_mod'});
    expect(moderators.recordGroupId, _shared,
        reason: 'keys are still trusted from the shared group');
    expect(crypto.asked, [_private]);
  });

  test('a private channel with no moderator in it reports to nobody', () {
    crypto.rosters[_private] = {'acct_member'};
    expect(state.reportModeratorsFor(_private)!.accounts, isEmpty);
  });

  test('an unreadable channel roster gives no recipients at all', () {
    expect(state.reportModeratorsFor(_private), isNull);
  });

  test('a service without rosters fails closed for a private channel', () {
    final plain = AppState(
      apiClientFactory: (_) => state.api!,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _Sync(),
    )
      ..communities = state.communities
      ..conversations = state.conversations
      ..governanceOverrideForTesting = state.governanceOverrideForTesting;
    expect(plain.reportModeratorsFor(_private), isNull);
    expect(plain.reportModeratorsFor(_shared)!.accounts, hasLength(4));
  });
}
