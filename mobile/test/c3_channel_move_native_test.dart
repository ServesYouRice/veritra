import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart'
    show LocalMessage;
import 'package:private_messenger/storage/local_store.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

// C3 channel conversion (C7 decision 11, owner answers 2026-11-12) through
// real OpenMLS devices: the `move` record continues the channel's chain in
// its new group, its wrap hands the old group's generation over, and a
// member who never held the channel's earlier posts imports them from the
// old conversation, checked against the old group's ids and epochs. Both
// directions, live and through a later newcomer's own import (option A).

final _community = 'comm_${'1' * 32}';
final _channel = 'chan_${'c' * 32}';
const _private = 'conv_private_c3move';
const _shared = 'conv_shared_c3move';
const _newPrivate = 'conv_new_private_c3move';

/// Where the channel lives now: the private conversation that is its own
/// group, or the shared group. The test moves it as the server would.
class _Authority
    implements
        ConversationAuthority,
        ConversationCommunitySource,
        VerifiedRoleSource,
        C7ChannelListSource {
  _Authority(this.home);
  final Map<String, String> home;

  String? get _where => home[_channel];

  @override
  String? conversationKind(String conversationId) =>
      conversationId == _shared ? 'community_shared' : 'community_channel';
  @override
  String? conversationChannel(String conversationId) =>
      conversationId != _shared && _where == conversationId ? _channel : null;
  @override
  List<String> c7Channels(String conversationId) =>
      conversationId == _shared && _where == _shared
          ? <String>[_channel]
          : const <String>[];
  @override
  Set<String> memberAccounts(String conversationId) => const {};
  @override
  String? roleOf(String conversationId, String accountId) => null;
  @override
  String? conversationCommunity(String conversationId) => _community;
  @override
  String? privateGroupChannel(String conversationId) =>
      conversationId != _shared && _where == conversationId ? _channel : null;
  @override
  GovernanceState? governanceOf(String conversationId) => GovernanceState(
        rev: 1,
        owner: 'acct_alice',
        ownerRev: 0,
        admins: {for (final admin in _admins) admin: 1},
      );
  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) =>
      false;
}

int _serverIds = 0;

/// Accounts besides the owner (alice) that may record and commit.
final _admins = <String>{};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;
  final home = <String, String>{};
  setUp(() {
    home.clear();
    _admins.clear();
  });

  /// [where]: this client's own view of the channel's home (default: the
  /// shared one the test moves).
  Future<_Client> client(String name, {Map<String, String>? where}) async {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final c = await _Client.enroll(bindings, 'acct_$name', 'dev_$name');
    addTearDown(c.service.dispose);
    c.service.conversationAuthority = _Authority(where ?? home);
    c.service.c7SealedBodies = true;
    return c;
  }

  Future<MessageEnvelope> syncFor(_Client alice, String conversation) async {
    final epoch = (await alice.service.groupEpoch(conversation))!.epoch;
    final due = (await alice.service.c7DueWork([conversation]))
        .whereType<C7DueSync>()
        .where((d) => d.forEpoch == epoch)
        .single;
    final sync = (await alice.service.c7Send(due))!;
    await alice.store.removePendingEnvelope(sync.idempotencyKey);
    return sync;
  }

  /// Alice's own record, received by [to] and then by her, in sync order.
  Future<MessageEnvelope> deliver(
      _Client alice, MessageEnvelope sent, List<_Client> to) async {
    await alice.store.removePendingEnvelope(sent.idempotencyKey);
    for (final member in to) {
      await member.receive(alice, sent);
    }
    await alice.receive(alice, sent);
    return sent;
  }

  /// Alice's move into [to], once it is owed.
  Future<MessageEnvelope> move(_Client alice, String to, List<_Client> members,
      {int? layoutGeneration}) async {
    final due =
        (await alice.service.c7DueWork([to])).whereType<C7DueMove>().single;
    final sent = (await alice.service
        .c7ProposeMove(due, layoutGeneration: layoutGeneration))!;
    return deliver(alice, sent, members);
  }

  test(
      'private to open: the move record wraps the private group\'s key, and '
      'a shared-group member who was never in the channel imports its '
      'earlier posts, live and as a later newcomer (option A)', () async {
    final alice = await client('alice');
    // Bob never learns of the move: he keeps posting in the old group, as
    // a server that ignored its own route check would serve.
    final bob = await client('bob', where: {_channel: _private});
    final carol = await client('carol');
    final dave = await client('dave');
    final erin = await client('erin');
    final frank = await client('frank');
    home[_channel] = _private;
    // The private channel: alice, bob and frank, `full`.
    await alice.service.initializeConversation(_private,
        <DeviceKeyPackage>[await bob.keyPackage(), await frank.keyPackage()]);
    await _accept(alice, [bob, frank], const [], conversation: _private);
    await deliver(
        alice,
        await alice.service
            .c7ProposeRecord(_private, _channel, full: true, create: true),
        [bob, frank]);
    final secret = await bob.send(_private, 'said in the private channel');
    await alice.receive(bob, secret);
    // Frank's removal rekeys the old group: the wrap names the newer
    // generation, and only the removal's stored slot leads back to the
    // one `secret` was sealed under.
    await alice.service.stageMembershipChange(_private,
        removes: [(accountId: frank.accountId, deviceId: frank.deviceId)]);
    await _accept(alice, const [], [bob, frank], conversation: _private);
    final removal = await syncFor(alice, _private);
    await bob.receive(alice, removal);
    final slots = C7HistoryPage(
        <C7HistoryRow>[_served(removal, alice, 'g1', groupLevel: true)],
        complete: true);
    final mine = await alice.send(_private, 'alice in private');
    await bob.receive(alice, mine);
    final oldEpoch = await alice.epoch(_private);
    // The shared group: alice and carol.
    await alice.service.initializeConversation(
        _shared, <DeviceKeyPackage>[await carol.keyPackage()]);
    await _accept(alice, [carol], const [], conversation: _shared);

    // The server moves the channel; alice owes the record.
    home[_channel] = _shared;
    await alice.service.c7NoteMove(
        channelId: _channel,
        fromConversationId: _private,
        toConversationId: _shared,
        own: true);
    final record = await move(alice, _shared, [carol], layoutGeneration: 1);
    // Owed once: the own echo settles it.
    expect((await alice.service.c7DueWork([_shared])).whereType<C7DueMove>(),
        isEmpty);
    expect(await alice.service.c7MovedImportsDue(), isEmpty);
    final view = await carol.service.c7ChannelView(_shared, _channel);
    expect(view!.full, isTrue);
    expect(view.status, 'ok');

    // Carol takes the wrap and imports from the old conversation.
    final due = await carol.service.c7MovedImportsDue();
    expect(due, hasLength(1));
    expect(due.single.fromConversationId, _private);
    expect(due.single.wrapClose, oldEpoch);
    // After the move's close epoch: an add keeps the old generation, so
    // this post opens under the wrapped key and its signature checks, but
    // it is past the window and never taken.
    await alice.service
        .stageMembershipChange(_private, adds: [await erin.keyPackage()]);
    await _accept(alice, [erin], [bob], conversation: _private);
    final late = await bob.send(_private, 'after the move, refused');
    expect(late.cryptoMetadata['mls_epoch'], oldEpoch + 1);
    final channel = C7HistoryPage(<C7HistoryRow>[
      // A body labelled past the move's close epoch is never taken.
      _served(late, bob, 'h4'),
      _served(mine, alice, 'h3'),
      _served(secret, bob, 'h2'),
    ], complete: true);
    final bobKey = await bob.service.currentSigningKey();
    final keys = <C7FormerKey>[
      C7FormerKey(
          deviceId: bob.deviceId,
          accountId: bob.accountId,
          signingKey: Uint8List.fromList(bobKey)),
    ];
    expect(
        await carol.service.c7ImportMoved(due.single,
            channel: channel, groupLevel: slots, keys: keys),
        2);
    final rows = await carol.store.loadMessages(_shared);
    LocalMessage row(_Client from, MessageEnvelope sent) => rows
        .where((r) => r.key == '${from.deviceId}:${sent.idempotencyKey}')
        .single;
    expect(row(bob, secret).body, 'said in the private channel');
    expect(row(bob, secret).channelId, _channel);
    expect(row(bob, secret).conversationId, _shared);
    // Bob holds no leaf in the shared group: marked as the server named.
    expect(row(bob, secret).c7Former, isNotNull);
    expect(row(alice, mine).c7Former, isNull);
    expect(rows.where((r) => r.key.endsWith(late.idempotencyKey)), isEmpty);
    expect(await carol.service.c7MovedImportsDue(), isEmpty);
    // Done once: a second import takes nothing.
    expect(
        await carol.service.c7ImportMoved(due.single,
            channel: channel,
            groupLevel: const C7HistoryPage(<C7HistoryRow>[], complete: true),
            keys: keys),
        0);

    // Dave joins the shared group later. The move message in the channel's
    // own stream hands him the wrap during his import (option A).
    await alice.service
        .stageMembershipChange(_shared, adds: [await dave.keyPackage()]);
    await _accept(alice, [dave], [carol], conversation: _shared);
    final join = await syncFor(alice, _shared);
    await dave.receive(alice, join);
    await carol.receive(alice, join);
    expect(await dave.service.c7ImportDue([_shared]), [_shared]);
    expect(await dave.service.c7MovedImportsDue(), isEmpty);
    await dave.service.c7ImportHistory(_shared,
        groupLevel: const C7HistoryPage(<C7HistoryRow>[], complete: true),
        channels: <String, C7HistoryPage>{
          _channel: C7HistoryPage(<C7HistoryRow>[_served(record, alice, 'h5')],
              complete: true),
        });
    final daveDue = await dave.service.c7MovedImportsDue();
    expect(daveDue, hasLength(1));
    expect(
        await dave.service.c7ImportMoved(daveDue.single,
            channel: channel, groupLevel: slots, keys: keys),
        2);
    expect(
        (await dave.store.loadMessages(_shared))
            .where((r) => r.body == 'said in the private channel'),
        hasLength(1));
  }, skip: skip);

  test(
      'option A trusts a move only from its actor\'s key in the current tree: '
      'once the mover has left, a newcomer takes no wrap from it, even '
      'with the server listing the mover\'s key', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    final carol = await client('carol');
    final dave = await client('dave');
    _admins.add(carol.accountId);
    home[_channel] = _private;
    await alice.service.initializeConversation(
        _private, <DeviceKeyPackage>[await bob.keyPackage()]);
    await _accept(alice, [bob], const [], conversation: _private);
    await deliver(
        alice,
        await alice.service
            .c7ProposeRecord(_private, _channel, full: true, create: true),
        [bob]);
    await alice.receive(bob, await bob.send(_private, 'private'));
    await alice.service.initializeConversation(
        _shared, <DeviceKeyPackage>[await carol.keyPackage()]);
    await _accept(alice, [carol], const [], conversation: _shared);
    home[_channel] = _shared;
    await alice.service.c7NoteMove(
        channelId: _channel,
        fromConversationId: _private,
        toConversationId: _shared,
        own: true);
    final record = await move(alice, _shared, [carol], layoutGeneration: 1);
    // Carol, an admin, removes alice and then adds dave.
    await carol.service.stageMembershipChange(_shared,
        removes: [(accountId: alice.accountId, deviceId: alice.deviceId)]);
    await _accept(carol, const [], [alice], conversation: _shared);
    await carol.service
        .stageMembershipChange(_shared, adds: [await dave.keyPackage()]);
    await _accept(carol, [dave], const [], conversation: _shared);
    await dave.receive(carol, await syncFor(carol, _shared));
    expect(await dave.service.c7ImportDue([_shared]), [_shared]);
    final aliceKey = await alice.service.currentSigningKey();
    await dave.service.c7ImportHistory(_shared,
        groupLevel: const C7HistoryPage(<C7HistoryRow>[], complete: true),
        channels: <String, C7HistoryPage>{
          _channel: C7HistoryPage(<C7HistoryRow>[_served(record, alice, 'h1')],
              complete: true),
        },
        formerKeys: <C7FormerKey>[
          C7FormerKey(
              deviceId: alice.deviceId,
              accountId: alice.accountId,
              signingKey: Uint8List.fromList(aliceKey)),
        ]);
    expect(await dave.service.c7MovedImportsDue(), isEmpty);
  }, skip: skip);

  test(
      'open to private: the move waits for the first add, then the newcomer '
      'takes its wrap live and imports the open channel\'s earlier posts, '
      'and only that channel\'s', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    final carol = await client('carol');
    home[_channel] = _shared;
    await alice.service.initializeConversation(
        _shared, <DeviceKeyPackage>[await bob.keyPackage()]);
    await _accept(alice, [bob], const [], conversation: _shared);
    await deliver(
        alice,
        await alice.service.c7ProposeRecord(_shared, _channel,
            full: true, create: true, layoutGeneration: 1),
        [bob]);
    final open = await bob.sendIn(_shared, 'said in the open channel');
    await alice.receive(bob, open);

    // The server moves it to a new conversation with alice alone.
    await alice.service
        .initializeConversation(_newPrivate, const <DeviceKeyPackage>[]);
    await _accept(alice, const [], const [], conversation: _newPrivate);
    home[_channel] = _newPrivate;
    await alice.service.c7NoteMove(
        channelId: _channel,
        fromConversationId: _shared,
        toConversationId: _newPrivate,
        own: true);
    // Epoch 0: a group of one, so the record waits.
    expect(
        (await alice.service.c7DueWork([_newPrivate])).whereType<C7DueMove>(),
        isEmpty);
    await alice.service
        .stageMembershipChange(_newPrivate, adds: [await carol.keyPackage()]);
    await _accept(alice, [carol], const [], conversation: _newPrivate);
    await carol.receive(alice, await syncFor(alice, _newPrivate));
    await move(alice, _newPrivate, [carol]);
    expect((await carol.service.c7ChannelView(_newPrivate, _channel))!.full,
        isTrue);
    final due = await carol.service.c7MovedImportsDue();
    expect(due, hasLength(1));
    expect(due.single.fromConversationId, _shared);
    final bobKey = await bob.service.currentSigningKey();
    final keys = <C7FormerKey>[
      C7FormerKey(
          deviceId: bob.deviceId,
          accountId: bob.accountId,
          signingKey: Uint8List.fromList(bobKey)),
    ];
    // A post of another channel of the old group, served in this channel's
    // stream: its body key and AAD name the other channel, so it never
    // opens.
    final elsewhere = await bob.service.encryptChannelPayload(_shared,
        AppPayloadType.text, <String, Object?>{'text': 'another channel'},
        channelId: 'chan_${'d' * 32}', layoutGeneration: 1);
    await bob.store.removePendingEnvelope(elsewhere.idempotencyKey);
    final page = C7HistoryPage(<C7HistoryRow>[
      _served(elsewhere, bob, 'o2', channelId: _channel),
      _served(open, bob, 'o1'),
    ], complete: true);
    expect(
        await carol.service.c7ImportMoved(due.single,
            channel: page,
            groupLevel: const C7HistoryPage(<C7HistoryRow>[], complete: true),
            keys: keys),
        1);
    final rows = await carol.store.loadMessages(_newPrivate);
    final imported =
        rows.where((r) => r.body == 'said in the open channel').single;
    // A private channel's own conversation names no channel on its rows.
    expect(imported.channelId, isNull);
    expect(imported.conversationId, _newPrivate);
  }, skip: skip);
}

C7HistoryRow _served(MessageEnvelope sent, _Client from, String id,
    {int? epoch, String? channelId, bool groupLevel = false}) {
  final metadata = sent.cryptoMetadata as Map;
  return C7HistoryRow(
    messageId: 'hist_$id',
    senderDeviceId: from.deviceId,
    actionId: sent.idempotencyKey,
    channelId: groupLevel
        ? null
        : channelId ?? metadata['channel_id'] as String? ?? _channel,
    createdAt: DateTime.now().toUtc(),
    epoch: epoch ?? metadata['mls_epoch'] as int,
    body: Uint8List.fromList(sent.sealedBody!),
  );
}

Future<void> _accept(_Client from, List<_Client> joiners, List<_Client> members,
    {required String conversation}) async {
  final item = (await from.store.pendingMlsMessages()).single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await from.service.completeCommitBundle(item);
  for (final member in members) {
    await member.service.processMlsMessage(MlsMessage(
      id: 'mls_${++_serverIds}',
      conversationId: conversation,
      senderAccountId: from.accountId,
      senderDeviceId: from.deviceId,
      kind: 'commit',
      payload: bundle.commit,
      idempotencyKey: item.idempotencyKey,
      syncEventId: member.nextEvent(),
      createdAt: DateTime.now().toUtc(),
    ));
  }
  for (final joiner in joiners) {
    await joiner.service.processMlsMessage(MlsMessage(
      id: 'mls_${++_serverIds}',
      conversationId: conversation,
      senderAccountId: from.accountId,
      senderDeviceId: from.deviceId,
      kind: 'welcome',
      payload: bundle.welcome,
      idempotencyKey: '${item.idempotencyKey}:welcome:${joiner.deviceId}',
      syncEventId: joiner.nextEvent(),
      createdAt: DateTime.now().toUtc(),
      recipientDeviceId: joiner.deviceId,
    ));
  }
}

class _Client {
  _Client(
      this.bindings, this.service, this.store, this.accountId, this.deviceId);

  final NativeCryptoBindings bindings;
  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  int events = 0;

  static Future<_Client> enroll(
      NativeCryptoBindings bindings, String accountId, String deviceId) async {
    final local = MemoryLocalStore();
    final service =
        TestNativeCryptoService(bindings: bindings, localStore: local);
    await service.createEnrollmentCredential(EnrollmentReservation(
      id: 'res_$deviceId',
      accountId: accountId,
      deviceId: deviceId,
      challenge: const <int>[1, 2, 3],
    ));
    await service.activateSession(Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    ));
    return _Client(bindings, service, local, accountId, deviceId);
  }

  int nextEvent() => ++events;

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$deviceId${++_serverIds}',
        deviceId: deviceId,
        accountId: accountId,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  /// A post in a private channel's own group.
  Future<MessageEnvelope> send(String conversation, String text) async {
    final envelope = await service.encryptPayload(
        conversation, AppPayloadType.text, <String, Object?>{'text': text});
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  /// A post in the shared group's channel.
  Future<MessageEnvelope> sendIn(String conversation, String text) async {
    final envelope = await service.encryptChannelPayload(
        conversation, AppPayloadType.text, <String, Object?>{'text': text},
        channelId: _channel, layoutGeneration: 1);
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  Future<void> receive(_Client from, MessageEnvelope sent) async {
    await service.processApplicationMessage(
      ReceivedMessageEnvelope(
        id: 'srv_${++_serverIds}',
        conversationId: sent.conversationId,
        senderAccountId: from.accountId,
        senderDeviceId: from.deviceId,
        idempotencyKey: sent.idempotencyKey,
        ciphertext: sent.ciphertext,
        cryptoProtocol: sent.cryptoProtocol,
        cryptoMetadata: sent.cryptoMetadata,
        frankCommit: sent.frankCommit,
        sealedBody: sent.sealedBody,
        createdAt: DateTime.now().toUtc(),
      ),
      nextEvent(),
    );
  }

  Future<int> epoch(String conversation) async =>
      (await service.groupEpoch(conversation))!.epoch;
}
