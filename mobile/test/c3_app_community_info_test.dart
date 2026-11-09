import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

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
}
