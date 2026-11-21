import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_commands.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

// C2 admin-only posting with real OpenMLS devices and a real C4 role record
// (docs/designs/C2-admin-only-posting.md): the owner restricts posting by a
// role commit, and then a post from an account below admin is dropped by
// every member's device, including the owner's other device, whatever the
// server says about the setting. An announcement channel of a community
// works the same way in the shared group.

const _group = 'conv_c2_group';
const _shared = 'conv_c2_shared';
const _community = 'comm_c2';
const _announce = 'chan_c2_announce';
const _open = 'chan_c2_open';

/// What the server tells one device: the record is read from the device's
/// own MLS state (as AppState does), and [serverRestricts] is the server's
/// `posting_restricted` (a hostile server switches it off).
class _Topology
    implements
        ConversationAuthority,
        ConversationCommunitySource,
        VerifiedRoleSource,
        C7ChannelListSource {
  bool serverRestricts = false;
  late NativeCryptoService service;

  @override
  String? conversationKind(String conversationId) =>
      conversationId == _shared ? 'community_shared' : 'group';
  @override
  String? conversationChannel(String conversationId) => null;
  @override
  Set<String> memberAccounts(String conversationId) => const {};
  @override
  String? roleOf(String conversationId, String accountId) => null;
  @override
  String? conversationCommunity(String conversationId) =>
      conversationId == _shared ? _community : null;
  @override
  String? privateGroupChannel(String conversationId) => null;
  @override
  List<String> c7Channels(String conversationId) => conversationId == _shared
      ? const <String>[_announce, _open]
      : const <String>[];
  @override
  GovernanceState? governanceOf(String conversationId) =>
      service.governanceOf(conversationId);
  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) =>
      serverRestricts;
}

int _serverIds = 0;

void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  Future<_Client> client(String name, {String? account}) async {
    final c = await _Client.enroll(
      bindings,
      account ?? 'acct_$name',
      'dev_$name',
    );
    addTearDown(c.service.dispose);
    return c;
  }

  /// Alice creates [conversation] with [members]; then her role commits.
  Future<void> start(
    _Client alice,
    String conversation,
    List<_Client> members,
  ) async {
    await alice.service.initializeConversation(conversation, [
      for (final m in members) await m.keyPackage(),
    ]);
    final done = await _complete(alice, conversation);
    for (final m in members) {
      await m.welcome(alice, conversation, done.welcome, done.key);
    }
  }

  Future<void> roleCommit(
    _Client alice,
    String conversation,
    List<_Client> members,
    GovernanceState Function(GovernanceCommands commands) build,
  ) async {
    await alice.service.stageRoleChange(
      conversation,
      (commands, _, __) => build(commands),
    );
    final done = await _complete(alice, conversation);
    for (final m in members) {
      await m.applyCommit(alice, conversation, done.commit, done.key);
    }
  }

  /// No row of [c] in [conversation] shows [text].
  Future<void> expectHidden(
    _Client c,
    String conversation,
    String key,
    String text,
  ) async {
    final rows = await c.store.loadMessages(conversation);
    expect(
      rows.where((m) => m.body?.contains(text) ?? false),
      isEmpty,
      reason: '${c.device} shows "$text"',
    );
    final row = await c.store.loadMessage(key);
    expect(row, isNotNull, reason: '${c.device} keeps a row for the drop');
    expect(row!.kind, LocalMessageKind.action, reason: c.device);
  }

  Future<void> expectShown(_Client c, String conversation, String text) async {
    final rows = await c.store.loadMessages(conversation);
    expect(
      rows.where((m) => m.body == text && m.kind == LocalMessageKind.text),
      hasLength(1),
      reason: '${c.device} hides "$text"',
    );
  }

  test(
    'a member post in an admins-only group is dropped on every device, '
    'even when the server says posting is open',
    () async {
      final alice = await client('alice');
      final alice2 = await client('alice2', account: 'acct_alice');
      final bob = await client('bob');
      final carol = await client('carol');
      final mod = await client('mod');
      final everyone = [alice2, bob, carol, mod];
      await start(alice, _group, everyone);
      await roleCommit(
        alice,
        _group,
        everyone,
        (c) => c.setRole(mod.account, BuiltInRole.moderator),
      );
      await roleCommit(
        alice,
        _group,
        everyone,
        (c) => c.setPosting(
          adminsOnly: true,
          announcementChannels: c.state.announcementChannels,
        ),
      );
      for (final c in [alice, ...everyone]) {
        // The hostile server's word: nothing is restricted.
        c.topology.serverRestricts = false;
        expect(
          (await c.service.governanceView(_group))!.record.adminsOnlyPosting,
          isTrue,
          reason: c.device,
        );
      }

      // Bob (a member) and a moderator post, reply and attach: dropped.
      final post = await bob.send(_group, 'member post');
      final reply = await bob.sendPayload(_group, AppPayloadType.reply, {
        'text': 'member reply',
        'reply_to_id': 'dev_alice:nothing',
      });
      final modPost = await mod.send(_group, 'moderator post');
      for (final c in [alice, alice2, carol]) {
        await c.receive(bob, post);
        await c.receive(bob, reply);
        await c.receive(mod, modPost);
        await expectHidden(c, _group, bob.keyOf(post), 'member post');
        await expectHidden(c, _group, bob.keyOf(reply), 'member reply');
        await expectHidden(c, _group, mod.keyOf(modPost), 'moderator post');
      }

      // Bob's edit of his dropped post cannot bring its text back.
      final edit = await bob.sendPayload(_group, AppPayloadType.edit, {
        'message_id': bob.keyOf(post),
        'text': 'member post, edited',
      });
      for (final c in [alice, alice2, carol]) {
        await c.receive(bob, edit);
        await expectHidden(c, _group, bob.keyOf(post), 'member post');
      }

      // The owner posts: every member shows it.
      final owner = await alice.send(_group, 'owner post');
      for (final c in [alice2, bob, carol, mod]) {
        await c.receive(alice, owner);
        await expectShown(c, _group, 'owner post');
      }

      // Bob made admin by the record posts and is shown.
      await roleCommit(
        alice,
        _group,
        everyone,
        (c) => c.setRole(bob.account, BuiltInRole.admin),
      );
      final adminPost = await bob.send(_group, 'admin post');
      for (final c in [alice, alice2, carol]) {
        await c.receive(bob, adminPost);
        await expectShown(c, _group, 'admin post');
      }
    },
    skip: skip,
  );

  test(
    'a member post in an announcement channel is dropped in the shared '
    'group; the same member posts in an open channel',
    () async {
      final alice = await client('alice');
      final bob = await client('bob');
      final carol = await client('carol');
      final members = [bob, carol];
      await start(alice, _shared, members);
      await roleCommit(
        alice,
        _shared,
        members,
        (c) => c.setPosting(
          adminsOnly: c.state.adminsOnlyPosting,
          announcementChannels: {_announce},
        ),
      );
      final news = await bob.sendIn(_shared, _announce, 'member news');
      final chat = await bob.sendIn(_shared, _open, 'member chat');
      final owner = await alice.sendIn(_shared, _announce, 'owner news');
      for (final c in [alice, carol]) {
        await c.receive(bob, news);
        await c.receive(bob, chat);
        await expectHidden(c, _shared, bob.keyOf(news), 'member news');
        await expectShown(c, _shared, 'member chat');
      }
      await carol.receive(alice, owner);
      await expectShown(carol, _shared, 'owner news');
    },
    skip: skip,
  );
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
  ) async {
    final local = MemoryLocalStore();
    final service = TestNativeCryptoService(
      bindings: bindings,
      localStore: local,
    );
    final topology = _Topology()..service = service;
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

  int nextEvent() => ++_events;

  String keyOf(MessageEnvelope sent) => '$device:${sent.idempotencyKey}';

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

  Future<MessageEnvelope> sendPayload(
    String conversation,
    AppPayloadType type,
    Map<String, Object?> body,
  ) async {
    final envelope = await service.encryptPayload(conversation, type, body);
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  Future<MessageEnvelope> send(String conversation, String text) =>
      sendPayload(conversation, AppPayloadType.text, {'text': text});

  Future<MessageEnvelope> sendIn(
    String conversation,
    String channel,
    String text,
  ) async {
    final envelope = await service.encryptChannelPayload(
      conversation,
      AppPayloadType.text,
      <String, Object?>{'text': text},
      channelId: channel,
      layoutGeneration: 1,
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
    welcome: bundle.welcome,
  );
}
