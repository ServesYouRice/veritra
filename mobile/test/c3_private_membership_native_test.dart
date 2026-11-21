import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/core/roles/private_channel_membership.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

// C3 private channel membership with real OpenMLS devices (docs/crypto.md,
// "C3 private channel membership"): the server's member list of a private
// channel only proposes. A new account joins the channel's group only by a
// commit from an owner or admin under the community's verified C4 record,
// and an honest device commits that only for an account its user picked.
// A server that lists an outsider in a private channel, and even gets one
// device to add them, cannot make the channel readable to them.

const _community = 'comm_c3_membership';
const _channel = 'chan_c3_membership';
const _shared = 'conv_shared_c3_membership';
const _private = 'conv_private_c3_membership';

/// What the server tells one device. [privateLabel] is whether it lists
/// [_private] as a private channel's group; the role record is read as
/// AppState does, the shared group's for both conversations.
class _Topology
    implements
        ConversationAuthority,
        ConversationCommunitySource,
        VerifiedRoleSource {
  _Topology({this.privateLabel = true});

  bool privateLabel;
  late NativeCryptoService service;

  @override
  String? conversationKind(String conversationId) =>
      conversationId == _shared ? 'community_shared' : 'community_channel';
  @override
  String? conversationChannel(String conversationId) => null;
  @override
  Set<String> memberAccounts(String conversationId) => const {};
  @override
  String? roleOf(String conversationId, String accountId) => null;
  @override
  String? conversationCommunity(String conversationId) => _community;
  @override
  String? privateGroupChannel(String conversationId) =>
      conversationId == _private && privateLabel ? _channel : null;
  @override
  GovernanceState? governanceOf(String conversationId) =>
      conversationId == _shared || conversationId == _private
          ? service.governanceOf(_shared)
          : null;
  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) =>
      false;
}

int _serverIds = 0;

void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  Future<_Client> client(
    String name, {
    String? account,
    bool privateLabel = true,
  }) async {
    final c = await _Client.enroll(
      bindings,
      account ?? 'acct_$name',
      'dev_$name',
      _Topology(privateLabel: privateLabel),
    );
    addTearDown(c.service.dispose);
    return c;
  }

  /// Alice (the owner) creates the community's shared group with [members]
  /// and the private channel's group with [readers], whom she picked.
  Future<void> community(
    _Client alice, {
    required List<_Client> members,
    required List<_Client> readers,
  }) async {
    await alice.service.initializeConversation(_shared, [
      for (final m in members) await m.keyPackage(),
    ]);
    await _deliver(alice, _shared, joiners: members);
    for (final reader in readers) {
      await alice.pick(reader);
    }
    await alice.service.initializeConversation(_private, [
      for (final r in readers) await r.keyPackage(),
    ]);
    await _deliver(alice, _private, joiners: readers);
  }

  test(
    'a member never adds an account nobody picked; an admin only its picks',
    () async {
      final alice = await client('alice');
      final bob = await client('bob');
      final mallory = await client('mallory');
      final bob2 = await client('bob2', account: 'acct_bob');
      await community(alice, members: [bob, mallory], readers: [bob]);

      // Bob is a plain member: the server listing Mallory changes nothing.
      expect(
        await bob.service.privateChannelAddable(_private, {mallory.account}),
        isEmpty,
      );
      await bob.pick(mallory);
      expect(
        await bob.service.privateChannelAddable(_private, {mallory.account}),
        isEmpty,
      );
      await expectLater(
        bob.service.stageMembershipChange(
          _private,
          adds: [await mallory.keyPackage()],
        ),
        throwsA(isA<PrivateChannelAddRefusedException>()),
      );
      expect(await bob.store.pendingMlsMessages(), isEmpty);

      // The owner adds only an account she picked.
      expect(
        await alice.service.privateChannelAddable(_private, {mallory.account}),
        isEmpty,
      );
      await alice.pick(mallory);
      expect(
        await alice.service.privateChannelAddable(_private, {mallory.account}),
        {mallory.account},
      );

      // A new device of a reader joins by anyone's commit.
      expect(
        await bob.service.privateChannelAddable(_private, {bob2.account}),
        {bob2.account},
      );

      // Outside a private channel nothing changes.
      expect(
        await bob.service.privateChannelAddable(_shared, {mallory.account}),
        {mallory.account},
      );
    },
    skip: skip,
  );

  test(
    'an outsider a member was made to add reads nothing; members hold it',
    () async {
      final alice = await client('alice');
      final carol = await client('carol');
      // Bob's device was told the channel is not private and never pinned
      // it (or runs a modified app): it commits the server's add.
      final bob = await client('bob', privateLabel: false);
      final mallory = await client('mallory');
      await community(
        alice,
        members: [bob, carol, mallory],
        readers: [bob, carol],
      );
      // Carol has seen it as private (refresh pins it).
      await carol.store.saveSetting(privateChannelPinSetting(_private), '1');
      final aliceEpoch = await alice.epoch(_private);

      await bob.service.stageMembershipChange(
        _private,
        adds: [await mallory.keyPackage()],
      );
      final add = await _complete(bob, _private);
      for (final member in [alice, carol]) {
        await expectLater(
          member.applyCommit(bob, _private, add.commit, add.key),
          throwsA(
            isA<GovernanceHeldException>().having(
              (e) => e.reason,
              'reason',
              'private_add_unauthorized',
            ),
          ),
        );
        expect(await member.epoch(_private), aliceEpoch);
        expect(await member.store.pendingMlsMessages(), isEmpty);
      }
      // Held again on a retry: nothing new arrived to change the verdict.
      await expectLater(
        carol.applyCommit(bob, _private, add.commit, add.key),
        throwsA(isA<GovernanceHeldException>()),
      );

      // Mallory joined Bob's fork, but the honest readers never moved to
      // it: what they post stays unreadable to her.
      await mallory.welcome(bob, _private, add.welcome, add.key);
      final post = await carol.send(_private, 'only for the readers');
      await alice.receive(carol, post);
      expect(
        (await alice.store.loadMessages(_private))
            .where((m) => m.body == 'only for the readers'),
        hasLength(1),
      );
      try {
        await mallory.receive(carol, post);
      } on Object {
        // Refused outright is as good as unreadable.
      }
      expect(
        (await mallory.store.loadMessages(_private))
            .where((m) => m.body?.contains('only for the readers') ?? false),
        isEmpty,
      );
    },
    skip: skip,
  );

  test(
    'a server label switched off later does not switch the rule off',
    () async {
      final alice = await client('alice');
      final carol = await client('carol');
      final bob = await client('bob', privateLabel: false);
      final dave = await client('dave');
      final mallory = await client('mallory');
      await community(
        alice,
        members: [bob, carol, dave, mallory],
        readers: [bob, carol],
      );
      // Carol pins the group herself by judging Alice's add of Dave,
      // which she accepts (the owner picked him).
      await alice.pick(dave);
      await alice.service.stageMembershipChange(
        _private,
        adds: [await dave.keyPackage()],
      );
      final daveAdd = await _complete(alice, _private);
      await carol.applyCommit(alice, _private, daveAdd.commit, daveAdd.key);
      await bob.applyCommit(alice, _private, daveAdd.commit, daveAdd.key);
      expect(
        await carol.store.loadSetting(privateChannelPinSetting(_private)),
        '1',
      );
      // Alice's pick is spent with her own accepted add.
      expect(
        decodePrivateChannelPicks(
          await alice.store.loadSetting(privateChannelPicksSetting(_private)),
          DateTime.now(),
        ),
        isNot(contains(dave.account)),
      );

      // The server now tells Carol the group is something else.
      carol.topology.privateLabel = false;
      final before = await carol.epoch(_private);
      await bob.service.stageMembershipChange(
        _private,
        adds: [await mallory.keyPackage()],
      );
      final add = await _complete(bob, _private);
      await expectLater(
        carol.applyCommit(bob, _private, add.commit, add.key),
        throwsA(isA<GovernanceHeldException>()),
      );
      expect(await carol.epoch(_private), before);
    },
    skip: skip,
  );

  test(
    "an admin's add is held until its promotion arrives, then merges",
    () async {
      final alice = await client('alice');
      final bob = await client('bob');
      final carol = await client('carol');
      final dave = await client('dave');
      await community(
        alice,
        members: [bob, carol, dave],
        readers: [bob, carol],
      );
      // Alice makes Bob an admin in the shared group; Carol has not
      // processed that commit yet (the two groups have no common order).
      await alice.service.stageRoleChange(
        _shared,
        (c, _, __) => c.setRole(bob.account, BuiltInRole.admin),
      );
      final promotion = await _complete(alice, _shared);
      await bob.applyCommit(alice, _shared, promotion.commit, promotion.key);

      await bob.pick(dave);
      await bob.service.stageMembershipChange(
        _private,
        adds: [await dave.keyPackage()],
      );
      final add = await _complete(bob, _private);
      await alice.applyCommit(bob, _private, add.commit, add.key);
      await expectLater(
        carol.applyCommit(bob, _private, add.commit, add.key),
        throwsA(isA<GovernanceHeldException>()),
      );

      // Once the promotion arrives, the retry merges.
      await carol.applyCommit(alice, _shared, promotion.commit, promotion.key);
      await carol.applyCommit(bob, _private, add.commit, add.key);
      expect(await carol.epoch(_private), await alice.epoch(_private));
    },
    skip: skip,
  );

  test('a new device of a reader joins by a plain member\'s commit', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    final carol = await client('carol');
    final bob2 = await client('bob2', account: 'acct_bob');
    await community(alice, members: [bob, carol], readers: [bob, carol]);
    await carol.service.stageMembershipChange(
      _private,
      adds: [await bob2.keyPackage()],
    );
    final add = await _complete(carol, _private);
    await alice.applyCommit(carol, _private, add.commit, add.key);
    await bob.applyCommit(carol, _private, add.commit, add.key);
    expect(await alice.epoch(_private), await carol.epoch(_private));
  }, skip: skip);
}

class _Client {
  _Client(this.service, this.store, this.account, this.device, this.topology);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String account;
  final String device;
  final _Topology topology;
  int _events = 0;

  static Future<_Client> enroll(
    NativeCryptoBindings bindings,
    String account,
    String device,
    _Topology topology,
  ) async {
    final local = MemoryLocalStore();
    final service = TestNativeCryptoService(
      bindings: bindings,
      localStore: local,
    );
    topology.service = service;
    service.conversationAuthority = topology;
    await service.createEnrollmentCredential(
      EnrollmentReservation(
        id: 'res_$device',
        accountId: account,
        deviceId: device,
        challenge: const <int>[1, 2, 3],
      ),
    );
    await service.activateSession(
      Session(
        baseUrl: 'https://localhost:8443',
        token: 'token',
        accountId: account,
        deviceId: device,
      ),
    );
    return _Client(service, local, account, device, topology);
  }

  /// This device's user picks [other] for the private channel, as AppState
  /// does before it asks the server to add them.
  Future<void> pick(_Client other) async {
    final key = privateChannelPicksSetting(_private);
    final picks = decodePrivateChannelPicks(
      await store.loadSetting(key),
      DateTime.now(),
    );
    picks[other.account] =
        DateTime.now().add(privateChannelPickLifetime).millisecondsSinceEpoch;
    await store.saveSetting(key, encodePrivateChannelPicks(picks));
  }

  int nextEvent() => ++_events;

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$device${++_serverIds}',
        deviceId: device,
        accountId: account,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  Future<int> epoch(String conversation) async =>
      (await service.groupEpoch(conversation))!.epoch;

  Future<void> applyCommit(
    _Client from,
    String conversation,
    List<int> commit,
    String key,
  ) =>
      service.processMlsMessage(
        MlsMessage(
          id: 'mls_$key',
          conversationId: conversation,
          senderAccountId: from.account,
          senderDeviceId: from.device,
          kind: 'commit',
          payload: commit,
          idempotencyKey: key,
          syncEventId: nextEvent(),
          createdAt: DateTime.now().toUtc(),
        ),
      );

  Future<void> welcome(
    _Client from,
    String conversation,
    List<int> welcome,
    String key,
  ) =>
      service.processMlsMessage(
        MlsMessage(
          id: 'mls_${++_serverIds}',
          conversationId: conversation,
          senderAccountId: from.account,
          senderDeviceId: from.device,
          kind: 'welcome',
          payload: welcome,
          idempotencyKey: '$key:welcome:$device',
          syncEventId: nextEvent(),
          createdAt: DateTime.now().toUtc(),
          recipientDeviceId: device,
        ),
      );

  Future<MessageEnvelope> send(String conversation, String text) async {
    final envelope = await service.encryptPayload(
      conversation,
      AppPayloadType.text,
      <String, Object?>{'text': text},
    );
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  Future<List<int>?> receive(_Client from, MessageEnvelope sent) =>
      service.processApplicationMessage(
        ReceivedMessageEnvelope(
          id: 'srv_${++_serverIds}',
          conversationId: sent.conversationId,
          senderAccountId: from.account,
          senderDeviceId: from.device,
          idempotencyKey: sent.idempotencyKey,
          ciphertext: sent.ciphertext,
          cryptoProtocol: sent.cryptoProtocol,
          cryptoMetadata: sent.cryptoMetadata,
          frankCommit: sent.frankCommit,
          createdAt: DateTime.now().toUtc(),
        ),
        nextEvent(),
      );
}

/// Completes [from]'s one pending bundle in [conversation] as the server
/// accepting it.
Future<({String key, List<int> commit, List<int> welcome})> _complete(
  _Client from,
  String conversation,
) async {
  final item = (await from.store.pendingMlsMessages())
      .where((m) => m.conversationId == conversation)
      .single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await from.service.completeCommitBundle(item);
  return (
    key: item.idempotencyKey,
    commit: bundle.commit,
    welcome: bundle.welcome
  );
}

/// Completes [from]'s pending bundle in [conversation]: the Welcome to
/// [joiners].
Future<void> _deliver(
  _Client from,
  String conversation, {
  List<_Client> joiners = const [],
}) async {
  final done = await _complete(from, conversation);
  for (final joiner in joiners) {
    await joiner.welcome(from, conversation, done.welcome, done.key);
  }
}
