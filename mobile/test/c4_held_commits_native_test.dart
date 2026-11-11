import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

/// C4 review fixes with real OpenMLS devices (docs/crypto.md, "C4 app
/// wiring", held commits): a newcomer that cannot prove a governing
/// member's leave holds the removal instead of refusing it for good; a
/// commit from a leaf its list does not approve yet is held and merges once
/// the list approves it; and the C4 leave-notice mark carries nothing but a
/// member_leave.
void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  Future<List<_Client>> clients(List<String> names) async {
    final all = <_Client>[
      for (final name in names) await _Client.enroll(bindings, name),
    ];
    for (final a in all) {
      for (final b in all) {
        if (!identical(a, b)) await a.trust(b);
      }
    }
    return all;
  }

  test('a newcomer holds an honest leave it cannot prove, never refuses it',
      () async {
    final [alice, bob, carol, dave] =
        await clients(['alice', 'bob', 'carol', 'dave']);
    await alice.service.initializeConversation(
        'conv_1', [await bob.keyPackage(), await carol.keyPackage()]);
    await _deliver(alice, joiners: [bob, carol]);
    // Bob becomes an admin: his leave then needs a proof.
    await alice.service.stageRoleChange(
        'conv_1', (c, _, __) => c.setRole(bob.account, BuiltInRole.admin));
    await _deliver(alice, members: [bob, carol]);
    expect((await carol.service.governanceView('conv_1'))!.record.admins,
        contains(bob.account));

    // Bob's own leave reaches the members of today.
    final leave = await bob.service
        .encryptPayload('conv_1', AppPayloadType.memberLeave, const {});
    await bob.store.removePendingEnvelope(leave.idempotencyKey);
    expect((leave.cryptoMetadata as Map)[leaveNoticeMetadataKey], isTrue);
    for (final member in [alice, carol]) {
      await member.receive(bob, leave);
      expect(
          await member.store
              .loadSetting(governanceLeaveSetting('conv_1', bob.account)),
          isNotNull);
    }
    // Dave joins after it: his Welcome carries no proof.
    await alice.service
        .stageMembershipChange('conv_1', adds: [await dave.keyPackage()]);
    await _deliver(alice, joiners: [dave], members: [bob, carol]);
    expect(
        await dave.store
            .loadSetting(governanceLeaveSetting('conv_1', bob.account)),
        isNull);

    // Carol (a plain member) commits Bob's removal with her proof.
    await carol.service.stageMembershipChange('conv_1',
        removes: [(accountId: bob.account, deviceId: bob.device)]);
    final removal = await _complete(carol);
    await alice.applyCommit(carol, removal);
    expect((await alice.service.governanceView('conv_1'))!.record.admins,
        isNot(contains(bob.account)));

    // Dave holds it (retried by sync), and again on every retry; nothing
    // merges, and his group stays at the epoch before it.
    final before = (await dave.service.governanceView('conv_1'))!.record;
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
          dave.applyCommit(carol, removal),
          throwsA(isA<GovernanceHeldException>()
              .having((e) => e.reason, 'reason', 'removal_unproven')));
      expect((await dave.service.governanceView('conv_1'))!.record, before);
    }
  }, skip: skip);

  test('a role commit from a leaf not approved yet is held, then merges',
      () async {
    final [alice, bob, carol] = await clients(['alice', 'bob', 'carol']);
    await alice.service.initializeConversation(
        'conv_1', [await bob.keyPackage(), await carol.keyPackage()]);
    await _deliver(alice, joiners: [bob, carol]);
    // Bob's pin of Alice's list is stale: her leaf is unknown to it.
    bob.lists.remove(alice.account, alice.device);
    await alice.service.stageRoleChange('conv_1',
        (c, _, __) => c.setRole(carol.account, BuiltInRole.moderator));
    final commit = await _complete(alice);
    await carol.applyCommit(alice, commit);
    await expectLater(
        bob.applyCommit(alice, commit),
        throwsA(isA<GovernanceHeldException>()
            .having((e) => e.reason, 'reason', 'committer_unapproved')));
    expect((await bob.service.governanceView('conv_1'))!.record.moderators,
        isEmpty);
    // A later read of the list approves the leaf: the retry merges.
    await bob.trust(alice);
    await bob.applyCommit(alice, commit);
    expect((await bob.service.governanceView('conv_1'))!.record.moderators,
        {carol.account});
  }, skip: skip);

  test('the leave-notice mark carries only a member_leave', () async {
    final [alice, bob] = await clients(['alice', 'bob']);
    await alice.service
        .initializeConversation('conv_1', [await bob.keyPackage()]);
    await _deliver(alice, joiners: [bob]);
    final text = await alice.service.encryptPayload(
        'conv_1', AppPayloadType.text, const {'text': 'past the rules'});
    await alice.store.removePendingEnvelope(text.idempotencyKey);
    expect((text.cryptoMetadata as Map).containsKey(leaveNoticeMetadataKey),
        isFalse);
    // A server (or a sender) that marks a post to get it past the posting
    // rules gets an invalid row, never the text.
    await bob.receive(alice, text, metadata: <String, Object?>{
      ...text.cryptoMetadata,
      leaveNoticeMetadataKey: true,
    });
    final rows = await bob.store.loadMessages('conv_1');
    expect(rows.single.kind, LocalMessageKind.invalid);
    expect(rows.single.body, isNull);
  }, skip: skip);
}

int _serverIds = 0;

class _Group implements ConversationAuthority {
  @override
  Set<String> memberAccounts(String conversationId) => const {};
  @override
  String? roleOf(String conversationId, String accountId) => null;
  @override
  String? conversationKind(String conversationId) => 'group';
  @override
  String? conversationChannel(String conversationId) => null;
}

class _Client {
  _Client(this.service, this.store, this.account, this.device, this.lists);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String account;
  final String device;
  final TestDeviceLists lists;
  int _events = 0;

  static Future<_Client> enroll(
      NativeCryptoBindings bindings, String name) async {
    final account = 'acct_$name';
    final device = 'dev_$name';
    final local = MemoryLocalStore();
    final service = NativeCryptoService(bindings: bindings, localStore: local);
    final lists = TestDeviceLists();
    service.deviceListPins = lists;
    service.conversationAuthority = _Group();
    await service.createEnrollmentCredential(EnrollmentReservation(
      id: 'res_$device',
      accountId: account,
      deviceId: device,
      challenge: const <int>[1, 2, 3],
    ));
    await service.activateSession(Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: account,
      deviceId: device,
    ));
    final client = _Client(service, local, account, device, lists);
    lists.approve(account, device, await service.currentSigningKey());
    return client;
  }

  Future<void> trust(_Client other) async => lists.approve(
      other.account, other.device, await other.service.currentSigningKey());

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

  Future<void> applyCommit(
          _Client from, ({String key, List<int> commit}) staged) =>
      service.processMlsMessage(MlsMessage(
        id: 'mls_${staged.key}',
        conversationId: 'conv_1',
        senderAccountId: from.account,
        senderDeviceId: from.device,
        kind: 'commit',
        payload: staged.commit,
        idempotencyKey: staged.key,
        syncEventId: nextEvent(),
        createdAt: DateTime.now().toUtc(),
      ));

  Future<List<int>?> receive(_Client from, MessageEnvelope sent,
          {Map<String, Object?>? metadata}) =>
      service.processApplicationMessage(
          ReceivedMessageEnvelope(
            id: 'srv_${++_serverIds}',
            conversationId: sent.conversationId,
            senderAccountId: from.account,
            senderDeviceId: from.device,
            idempotencyKey: sent.idempotencyKey,
            ciphertext: sent.ciphertext,
            cryptoProtocol: sent.cryptoProtocol,
            cryptoMetadata: metadata ?? sent.cryptoMetadata,
            createdAt: DateTime.now().toUtc(),
            frankCommit: sent.frankCommit,
          ),
          nextEvent());
}

/// Completes [from]'s one pending commit bundle as the server accepting it.
Future<({String key, List<int> commit})> _complete(_Client from) async {
  final item = (await from.store.pendingMlsMessages()).single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await from.service.completeCommitBundle(item);
  return (key: item.idempotencyKey, commit: bundle.commit);
}

/// Completes [from]'s pending bundle and delivers it: the commit to
/// [members], the Welcome to [joiners].
Future<void> _deliver(_Client from,
    {List<_Client> joiners = const [],
    List<_Client> members = const []}) async {
  final item = (await from.store.pendingMlsMessages()).single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await from.service.completeCommitBundle(item);
  for (final member in members) {
    await member
        .applyCommit(from, (key: item.idempotencyKey, commit: bundle.commit));
  }
  for (final joiner in joiners) {
    await joiner.service.processMlsMessage(MlsMessage(
      id: 'mls_${++_serverIds}',
      conversationId: 'conv_1',
      senderAccountId: from.account,
      senderDeviceId: from.device,
      kind: 'welcome',
      payload: bundle.welcome,
      idempotencyKey: '${item.idempotencyKey}:welcome:${joiner.device}',
      syncEventId: joiner.nextEvent(),
      createdAt: DateTime.now().toUtc(),
      recipientDeviceId: joiner.device,
    ));
  }
}
