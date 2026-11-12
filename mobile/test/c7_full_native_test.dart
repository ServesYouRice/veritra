import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/c7_channel_book.dart';
import 'package:private_messenger/crypto/c7_group_state.dart';
import 'package:private_messenger/crypto/c7_history.dart';
import 'package:private_messenger/crypto/c7_keys.dart';
import 'package:private_messenger/crypto/c7_two_part.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart'
    show LocalMessage;
import 'package:private_messenger/storage/local_store.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

// C7 full mode through real OpenMLS devices and NativeCryptoService
// (docs/designs/C7-channel-history.md, decisions 2 to 5 and Traces 1 to 4):
// records applied in sync order under C4 authority, posts sealed under the
// generation key, the rekey at a removal merge, `unsure` after a message a
// device could not apply, and the `history_sync` handover to a newcomer,
// keyless when its committer was unsure.

final _community = 'comm_${'1' * 32}';
final _channel = 'chan_${'3' * 32}';
const _conversation = 'conv_private_c7full';
const _shared = 'conv_shared_c7full';
final _channelA = 'chan_${'a' * 32}';
final _channelB = 'chan_${'b' * 32}';

/// A private channel's own group ([_conversation]) and a community's
/// shared group ([_shared], two open channels), judged by a role record in
/// which [admins] (and the owner, alice) may change the history setting.
class _Authority
    implements
        ConversationAuthority,
        ConversationCommunitySource,
        VerifiedRoleSource,
        C7ChannelListSource {
  _Authority(this.admins);
  final Set<String> admins;

  @override
  String? conversationKind(String conversationId) =>
      conversationId == _shared ? 'community_shared' : 'community_channel';
  @override
  String? conversationChannel(String conversationId) =>
      conversationId == _shared ? null : _channel;
  @override
  List<String> c7Channels(String conversationId) => conversationId == _shared
      ? <String>[_channelA, _channelB]
      : const <String>[];
  @override
  Set<String> memberAccounts(String conversationId) => const {};
  @override
  String? roleOf(String conversationId, String accountId) => null;
  @override
  String? conversationCommunity(String conversationId) => _community;
  @override
  String? privateGroupChannel(String conversationId) =>
      conversationId == _conversation ? _channel : null;
  @override
  GovernanceState? governanceOf(String conversationId) => GovernanceState(
        rev: 1,
        owner: 'acct_alice',
        ownerRev: 0,
        admins: {for (final admin in admins) admin: 1},
      );
  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) =>
      false;
}

int _serverIds = 0;

/// How far every test client's clock runs ahead of the real one.
Duration _skew = Duration.zero;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;
  setUp(() => _skew = Duration.zero);

  /// A device of account `acct_[name]`; [device] names a second device of
  /// the same account.
  Future<_Client> client(String name,
      {Set<String>? admins, String? device}) async {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final c =
        await _Client.enroll(bindings, 'acct_$name', 'dev_${device ?? name}');
    addTearDown(c.service.dispose);
    c.service.conversationAuthority = _Authority(admins ?? const {'acct_bob'});
    c.service.c7SealedBodies = true;
    return c;
  }

  /// Alice makes the group with [members] and every one of them joins.
  Future<void> group(_Client alice, List<_Client> members) async {
    await alice.service
        .initializeConversation(_conversation, <DeviceKeyPackage>[
      for (final member in members) await member.keyPackage(),
    ]);
    await _accept(alice, members, const []);
    // The creating commit is a membership commit too: Alice owes its
    // history_sync at once, and it settles everyone's duty for it.
    final due = await alice.service.c7DueWork([_conversation]);
    final sync = (await alice.service.c7Send(due.single))!;
    await alice.store.removePendingEnvelope(sync.idempotencyKey);
    for (final member in members) {
      await member.receive(alice, sync);
      expect(await member.service.c7DueWork([_conversation]), isEmpty);
    }
    expect(await alice.service.c7DueWork([_conversation]), isEmpty);
  }

  /// [actor] proposes a record and every client in [to] receives it; the
  /// actor's own copy comes back last, in sync order.
  Future<MessageEnvelope> propose(_Client actor, List<_Client> to,
      {required bool full, bool create = false}) async {
    final sent = await actor.service
        .c7ProposeRecord(_conversation, _channel, full: full, create: create);
    await actor.store.removePendingEnvelope(sent.idempotencyKey);
    for (final member in to) {
      await member.receive(actor, sent);
    }
    await actor.receive(actor, sent);
    return sent;
  }

  test(
      'a full create applies everywhere in sync order and posts seal under '
      'the generation key', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    await group(alice, [bob]);
    expect((await alice.view())!.full, isFalse);
    final sent = await alice.service
        .c7ProposeRecord(_conversation, _channel, full: true, create: true);
    await alice.store.removePendingEnvelope(sent.idempotencyKey);
    // Applied only when it comes back: pending until then.
    expect((await alice.view())!.pending, isTrue);
    expect((await alice.view())!.full, isFalse);
    await bob.receive(alice, sent);
    await alice.receive(alice, sent);
    for (final c in [alice, bob]) {
      final view = (await c.view())!;
      expect(view.full, isTrue, reason: c.deviceId);
      expect(view.status, 'ok');
      expect(view.pending, isFalse);
    }
    // Both hold the same generation; a post seals under it and opens on
    // the other side, which stays `ok` (the `gen` matches).
    final aliceKey = (await alice.book()).sealGenAt(await alice.epoch())!.key;
    expect((await bob.book()).sealGenAt(await bob.epoch())!.key, aliceKey);
    final post = await alice.send('in the period');
    expect(await alice.sealedUnderChannelKey(post), isTrue);
    // Generation keys never ride a history snapshot (K1 backups, K2).
    await alice.store.saveSession(Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: alice.accountId,
      deviceId: alice.deviceId,
    ));
    for (final omit in <bool>[false, true]) {
      final snapshot = utf8.decode(
          await alice.store.exportHistorySnapshot(omitDisappearing: omit));
      expect(snapshot, isNot(contains(c7SettingPrefix)));
      expect(snapshot, isNot(contains(base64Encode(aliceKey!))));
    }
    await bob.receive(alice, post);
    expect((await bob.rows()).where((r) => r.kind == 'text'), hasLength(1));
    expect((await bob.view())!.status, 'ok');
    // A switch back to members_from_join ends the period: keys gone.
    await propose(bob, [alice], full: false);
    for (final c in [alice, bob]) {
      final book = await c.book();
      expect(book.mode, c7ModeMembersFromJoin);
      expect(book.gens, isEmpty);
    }
    final after = await alice.send('after the period');
    expect(await alice.sealedUnderChannelKey(after), isFalse);
  }, skip: skip);

  test('a record from an account without authority changes nothing', () async {
    final alice = await client('alice');
    // Carol believes she is an admin; nobody else does.
    final carol = await client('carol', admins: const {'acct_carol'});
    await group(alice, [carol]);
    final sent = await carol.service
        .c7ProposeRecord(_conversation, _channel, full: true, create: true);
    await carol.store.removePendingEnvelope(sent.idempotencyKey);
    await alice.receive(carol, sent);
    final book = await alice.book();
    expect(book.hasHead, isFalse);
    expect(book.mode, c7ModeMembersFromJoin);
    // The record left a hidden action row and nothing else.
    final fromCarol = (await alice.rows())
        .where((row) => row.senderAccountId == 'acct_carol')
        .single;
    expect(fromCarol.kind, 'action');
    expect(fromCarol.senderHidden, isTrue);
  }, skip: skip);

  test('a removal rekeys every full channel at merge (Trace 1)', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    final carol = await client('carol');
    await group(alice, [bob, carol]);
    await propose(alice, [bob, carol], full: true, create: true);
    final opened = await alice.epoch();
    final firstKey = (await alice.book()).sealGenAt(opened)!.key!;
    await alice.service.stageMembershipChange(_conversation,
        removes: [(accountId: 'acct_carol', deviceId: 'dev_carol')]);
    await _accept(alice, const [], [bob, carol]);
    final removal = await alice.epoch();
    expect(removal, opened + 1);
    final aliceBook = await alice.book();
    final bobBook = await bob.book();
    expect(aliceBook.gens.map((gen) => (gen.epoch, gen.close)),
        [(opened, removal), (removal, null)]);
    expect(bobBook.gens.map((gen) => gen.epoch), [opened, removal]);
    final secondKey = aliceBook.sealGenAt(removal)!.key!;
    expect(secondKey, isNot(firstKey));
    expect(bobBook.sealGenAt(removal)!.key, secondKey);
    // The removed device keeps nothing (the re-add wipe).
    expect(
        await carol.store.loadSetting(c7GroupSetting(_conversation)), isNull);
    expect(
        await carol.store
            .loadSetting(c7ChannelSetting(_conversation, _channel)),
        isNull);
    // A post after the removal seals under the new generation.
    final post = await bob.send('after carol left');
    expect(await bob.sealedUnderChannelKey(post, key: secondKey), isTrue);
    await alice.receive(bob, post);
    expect((await alice.view())!.status, 'ok');
  }, skip: skip);

  test(
      'a stripped body makes the group unsure; a later history_sync for the '
      "device's own head and key clears it; the newcomer takes the key",
      () async {
    final alice = await client('alice');
    final bob = await client('bob');
    final dave = await client('dave');
    await group(alice, [bob]);
    await propose(alice, [bob], full: true, create: true);
    final stripped = await alice.send('stripped');
    await bob.receive(alice, stripped, body: const <int>[]);
    expect((await bob.view())!.status, 'unsure');
    // An unsure device seals under random keys (I3).
    final random = await bob.send('while unsure');
    expect(await bob.sealedUnderChannelKey(random), isFalse);
    expect(await alice.sealedUnderChannelKey(random), isFalse);
    await alice.receive(bob, random);
    // Alice adds Dave; as the committer her history_sync is due at once.
    await alice.service
        .stageMembershipChange(_conversation, adds: [await dave.keyPackage()]);
    await _accept(alice, [dave], [bob]);
    final forEpoch = await alice.epoch();
    final due = await alice.service.c7DueWork([_conversation]);
    expect(due.whereType<C7DueSync>().single.forEpoch, forEpoch);
    // Bob's own duty waits for its jittered delay.
    expect(
        (await bob.service.c7DueWork([_conversation])).whereType<C7DueSync>(),
        isEmpty);
    final sync = (await alice.service.c7Send(due.single))!;
    await alice.store.removePendingEnvelope(sync.idempotencyKey);
    expect(sync.sealedBody!.length, c7HistorySyncBodyLength(1));
    expect((sync.cryptoMetadata as Map).containsKey('channel_id'), isFalse);
    expect(await alice.service.c7DueWork([_conversation]), isEmpty);
    await bob.receive(alice, sync);
    await dave.receive(alice, sync);
    // Bob: own head and key, for an epoch above the miss: `ok` again, and
    // his duty for that commit is settled by Alice's matching slots.
    expect((await bob.view())!.status, 'ok');
    expect((await bob.group()).duties[forEpoch]!.settled, isTrue);
    // Dave: head and key from the slot; seals under the same key.
    final daveView = (await dave.view())!;
    expect(daveView.full, isTrue);
    expect(daveView.status, 'ok');
    final key = (await alice.book()).sealGenAt(forEpoch)!.key;
    expect((await dave.book()).sealGenAt(forEpoch)!.key, key);
    final fromDave = await dave.send('hello from the newcomer');
    expect(await alice.sealedUnderChannelKey(fromDave), isTrue);
    expect((await dave.group()).joinSynced, isTrue);
    expect(await dave.service.c7DueWork([_conversation]), isEmpty);
  }, skip: skip);

  test(
      'a history_sync for an epoch no membership commit produced clears '
      'nothing', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    await group(alice, [bob]);
    await propose(alice, [bob], full: true, create: true);
    await bob.receive(alice, await alice.send('lost'), body: const <int>[]);
    expect((await bob.view())!.status, 'unsure');
    // A member (here Alice's device, tampered with) sends her own head and
    // key in a history_sync claiming a later commit that never happened.
    final now = await alice.epoch();
    final forged = (await alice.group()).withSnapshot(
        now + 5, {_channel: (await alice.book()).snapshot(now)}, 0);
    await alice.store
        .saveSetting(c7GroupSetting(_conversation), forged.encode());
    final sync =
        (await alice.service.c7Send(C7DueSync(_conversation, now + 5)))!;
    await alice.store.removePendingEnvelope(sync.idempotencyKey);
    await bob.receive(alice, sync);
    expect((await bob.view())!.status, 'unsure');
    // The same slots for the real commit epoch do not clear it either: the
    // miss happened in that epoch, so only a later commit can (I3).
    final real = (await alice.group())
        .withSnapshot(now, {_channel: (await alice.book()).snapshot(now)}, 0);
    await alice.store.saveSetting(c7GroupSetting(_conversation), real.encode());
    final again = (await alice.service.c7Send(C7DueSync(_conversation, now)))!;
    await alice.store.removePendingEnvelope(again.idempotencyKey);
    await bob.receive(alice, again);
    expect((await bob.view())!.status, 'unsure');
  }, skip: skip);

  test(
      'a newcomer added by an unsure committer is keyless and seals under '
      'random keys', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    final dave = await client('dave');
    await group(alice, [bob]);
    await propose(alice, [bob], full: true, create: true);
    // Bob misses one of Alice's messages, then adds Dave.
    await bob.receive(alice, await alice.send('lost'), body: const <int>[]);
    expect((await bob.view())!.status, 'unsure');
    await bob.service
        .stageMembershipChange(_conversation, adds: [await dave.keyPackage()]);
    await _accept(bob, [dave], [alice]);
    final due = await bob.service.c7DueWork([_conversation]);
    final sync = (await bob.service.c7Send(due.single))!;
    await bob.store.removePendingEnvelope(sync.idempotencyKey);
    await dave.receive(bob, sync);
    final view = (await dave.view())!;
    expect(view.full, isTrue);
    expect(view.status, 'keyless');
    final post = await dave.send('keyless');
    expect(await alice.sealedUnderChannelKey(post), isFalse);
    // Alice's duty is not settled by slots without her key.
    await alice.receive(bob, sync);
    expect((await alice.group()).duties[await alice.epoch()]!.settled, isFalse);
  }, skip: skip);

  test(
      'an own record sequenced after a membership commit is stale and is '
      'proposed again', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    final dave = await client('dave');
    await group(alice, [bob]);
    final sent = await alice.service
        .c7ProposeRecord(_conversation, _channel, full: true, create: true);
    await alice.store.removePendingEnvelope(sent.idempotencyKey);
    // Bob's add is sequenced before Alice's record.
    await bob.service
        .stageMembershipChange(_conversation, adds: [await dave.keyPackage()]);
    await _accept(bob, [dave], [alice]);
    await bob.receive(alice, sent);
    await alice.receive(alice, sent);
    expect((await bob.book()).hasHead, isFalse, reason: 'below the floor');
    final view = (await alice.view())!;
    expect(view.ownNotice, 'stale');
    expect(view.full, isFalse);
    final again = (await alice.service.c7DueWork([_conversation]))
        .whereType<C7DueRepropose>()
        .single;
    expect(again.full, isTrue);
    await propose(alice, [bob, dave], full: again.full, create: true);
    for (final c in [alice, bob, dave]) {
      expect((await c.view())!.full, isTrue, reason: c.deviceId);
    }
    expect((await alice.view())!.ownNotice, isNull);
  }, skip: skip);
  test(
      'a message passed over as expired makes the group unsure in the same '
      'commit as its tombstone', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    await group(alice, [bob]);
    await propose(alice, [bob], full: true, create: true);
    expect((await bob.view())!.status, 'ok');
    final cursor = await bob.store.loadSyncCursor();
    final event = bob.nextEvent();
    await bob.service.c7CommitExpiredSkip(SyncEventCommit(
      eventKey: 'expired:$event:srv_gone',
      conversationId: _conversation,
      expectedCursor: cursor,
      cursor: event,
    ));
    expect(await bob.store.loadSyncCursor(), event);
    expect((await bob.view())!.status, 'unsure');
    final random = await bob.send('after the gap');
    expect(await alice.sealedUnderChannelKey(random), isFalse);
    // Alice met no gap: she still seals under the generation key.
    final keyed = await alice.send('no gap here');
    expect(await bob.sealedUnderChannelKey(keyed), isTrue);
  }, skip: skip);

  test(
      "a second device of the same account applies the first's record as a "
      'live record, and its own proposal for the same seq loses', () async {
    final alice = await client('alice');
    final phone = await client('alice', device: 'alice_phone');
    final bob = await client('bob');
    await group(alice, [phone, bob]);
    // The phone creates the channel full: Alice's desktop takes it live.
    await propose(phone, [alice, bob], full: true, create: true);
    for (final device in [alice, phone, bob]) {
      final view = (await device.view())!;
      expect(view.full, isTrue);
      expect(view.status, 'ok');
      expect(view.pending, isFalse);
    }
    final post = await alice.send('from the desktop');
    expect(await phone.sealedUnderChannelKey(post), isTrue);
    await phone.receive(alice, post);
    await bob.receive(alice, post);
    // Both devices switch the setting off at once; the phone's record is
    // sequenced first. On the desktop it is a live record from another
    // device (not an own echo): it applies, and the desktop's own proposal
    // for the same seq is lost at once; its echo later changes nothing.
    final fromDesktop = await alice.service
        .c7ProposeRecord(_conversation, _channel, full: false);
    await alice.store.removePendingEnvelope(fromDesktop.idempotencyKey);
    final fromPhone = await phone.service
        .c7ProposeRecord(_conversation, _channel, full: false);
    await phone.store.removePendingEnvelope(fromPhone.idempotencyKey);
    expect((await alice.view())!.pending, isTrue);
    await alice.receive(phone, fromPhone);
    final taken = (await alice.view())!;
    expect(taken.full, isFalse);
    expect(taken.pending, isFalse);
    expect(taken.ownNotice, 'lost');
    await phone.receive(phone, fromPhone);
    await bob.receive(phone, fromPhone);
    await alice.receive(alice, fromDesktop);
    await phone.receive(alice, fromDesktop);
    await bob.receive(alice, fromDesktop);
    final desktop = (await alice.view())!;
    expect(desktop.pending, isFalse);
    expect(desktop.ownNotice, 'lost');
    final head = (await phone.book()).headBytes;
    for (final device in [alice, phone, bob]) {
      expect((await device.view())!.full, isFalse);
      expect((await device.book()).headBytes, head);
    }
    expect((await phone.view())!.ownNotice, isNull);
  }, skip: skip);

  test(
      'an own proposal that never comes back times out, and the device may '
      'propose again', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    await group(alice, [bob]);
    await propose(alice, [bob], full: true, create: true);
    final lost = await alice.service
        .c7ProposeRecord(_conversation, _channel, full: false);
    await alice.store.removePendingEnvelope(lost.idempotencyKey);
    expect((await alice.view())!.pending, isTrue);
    await expectLater(
        alice.service.c7ProposeRecord(_conversation, _channel, full: false),
        throwsStateError);
    _skew = c7ProposalTimeout + const Duration(seconds: 1);
    final timedOut = (await alice.view())!;
    expect(timedOut.pending, isFalse);
    expect(timedOut.ownNotice, 'timeout');
    // The first never reaches anyone; the second applies everywhere.
    await propose(alice, [bob], full: false);
    for (final device in [alice, bob]) {
      expect((await device.view())!.full, isFalse);
    }
    expect((await alice.view())!.ownNotice, isNull);
    expect((await alice.book()).late, hasLength(1));
  }, skip: skip);

  test(
      'a timed-out proposal that comes back late applies here too, and the '
      'newer one for the same seq is lost', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    await group(alice, [bob]);
    await propose(alice, [bob], full: true, create: true);
    // The switch off is slow to come back; Alice proposes a new period.
    final slow = await alice.service
        .c7ProposeRecord(_conversation, _channel, full: false);
    await alice.store.removePendingEnvelope(slow.idempotencyKey);
    _skew = c7ProposalTimeout + const Duration(seconds: 1);
    final newer = await alice.service
        .c7ProposeRecord(_conversation, _channel, full: true);
    await alice.store.removePendingEnvelope(newer.idempotencyKey);
    // The server sequenced the slow one first: Bob switches off, and so
    // must Alice, or she would keep sealing under a key Bob dropped.
    await bob.receive(alice, slow);
    await alice.receive(alice, slow);
    await bob.receive(alice, newer);
    await alice.receive(alice, newer);
    final view = (await alice.view())!;
    expect(view.full, isFalse);
    expect(view.pending, isFalse);
    expect(view.ownNotice, 'lost');
    expect((await alice.book()).late, isEmpty);
    expect((await bob.view())!.full, isFalse);
    expect((await alice.book()).headBytes, (await bob.book()).headBytes);
    final after = await alice.send('after the switch off');
    expect(await bob.sealedUnderChannelKey(after), isFalse);
  }, skip: skip);

  test(
      'a record that changes the setting is a system line on every device; '
      'a create in the default mode is none', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    await group(alice, [bob]);
    final create = await propose(alice, [bob], full: true, create: true);
    final createKey = '${alice.deviceId}:${create.idempotencyKey}';
    for (final device in [alice, bob]) {
      expect(await device.service.c7HistoryLines(_conversation),
          <String, bool>{createKey: true});
    }
    final off = await propose(alice, [bob], full: false);
    final offKey = '${alice.deviceId}:${off.idempotencyKey}';
    for (final device in [alice, bob]) {
      expect(await device.service.c7HistoryLines(_conversation),
          <String, bool>{createKey: true, offKey: false});
    }
    // Off again changes nothing but the chain: no line.
    await propose(alice, [bob], full: false);
    expect(await bob.service.c7HistoryLines(_conversation), hasLength(2));
  }, skip: skip);

  test(
      "a member's duty reports when it falls due, and nothing once the "
      'committer\'s history_sync settles it', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    final dave = await client('dave');
    await group(alice, [bob]);
    expect(await bob.service.c7NextDueAt([_conversation]), isNull);
    await alice.service
        .stageMembershipChange(_conversation, adds: [await dave.keyPackage()]);
    await _accept(alice, [dave], [bob]);
    final due = (await bob.service.c7NextDueAt([_conversation]))!;
    final wait = due.difference(DateTime.now().toUtc());
    expect(wait, greaterThan(c7FallbackBase - const Duration(seconds: 2)));
    expect(wait, lessThanOrEqualTo(c7FallbackCap));
    // Dave asks after a minute if nothing comes.
    expect(await dave.service.c7NextDueAt([_conversation]), isNotNull);
    final sync = (await alice.service
        .c7Send((await alice.service.c7DueWork([_conversation])).single))!;
    await alice.store.removePendingEnvelope(sync.idempotencyKey);
    await bob.receive(alice, sync);
    await dave.receive(alice, sync);
    expect(await bob.service.c7NextDueAt([_conversation]), isNull);
    expect(await dave.service.c7NextDueAt([_conversation]), isNull);
  }, skip: skip);

  test(
      'in a shared group, records name their channel, one history_sync '
      'covers every channel, and a newcomer adopts each', () async {
    final alice = await client('alice');
    final bob = await client('bob');
    final dave = await client('dave');
    await alice.service.initializeConversation(
        _shared, <DeviceKeyPackage>[await bob.keyPackage()]);
    await _accept(alice, [bob], const [], conversation: _shared);
    // Channel A goes full; channel B stays members_from_join.
    final record = await alice.service.c7ProposeRecord(_shared, _channelA,
        full: true, create: true, layoutGeneration: 1);
    await alice.store.removePendingEnvelope(record.idempotencyKey);
    expect((record.cryptoMetadata as Map)['channel_id'], _channelA);
    expect((record.cryptoMetadata as Map)['community_layout_generation'], 1);
    await bob.receive(alice, record);
    await alice.receive(alice, record);
    expect((await bob.view(_channelA, _shared))!.full, isTrue);
    expect((await bob.view(_channelB, _shared))!.full, isFalse);
    // A shared-group channel needs its layout generation.
    await expectLater(
        alice.service.c7ProposeRecord(_shared, _channelB, full: true),
        throwsStateError);
    // A post in channel A seals under its generation and opens for Bob.
    final post = await alice.service.encryptChannelPayload(
        _shared, AppPayloadType.text, <String, Object?>{'text': 'in A'},
        channelId: _channelA, layoutGeneration: 1);
    await alice.store.removePendingEnvelope(post.idempotencyKey);
    _Client.senders[post.idempotencyKey] = alice.deviceId;
    expect(
        await bob.sealedUnderChannelKey(post,
            channelId: _channelA, conversationId: _shared),
        isTrue);
    await bob.receive(alice, post);
    expect((await bob.view(_channelA, _shared))!.status, 'ok');
    // Dave joins; Alice's history_sync names both channels.
    await alice.service
        .stageMembershipChange(_shared, adds: [await dave.keyPackage()]);
    await _accept(alice, [dave], [bob], conversation: _shared);
    final due = (await alice.service.c7DueWork([_shared]))
        .whereType<C7DueSync>()
        .where((d) => d.forEpoch == 2)
        .single;
    final sync = (await alice.service.c7Send(due))!;
    await alice.store.removePendingEnvelope(sync.idempotencyKey);
    expect(sync.sealedBody!.length, c7HistorySyncBodyLength(2));
    expect((sync.cryptoMetadata as Map).containsKey('channel_id'), isFalse);
    await dave.receive(alice, sync);
    await bob.receive(alice, sync);
    final daveA = (await dave.view(_channelA, _shared))!;
    expect(daveA.full, isTrue);
    expect(daveA.status, 'ok');
    expect((await dave.view(_channelB, _shared))!.full, isFalse);
    expect((await dave.group(_shared)).channels, contains(_channelA));
    // Dave's post in A seals under the key he was handed.
    final fromDave = await dave.service.encryptChannelPayload(
        _shared, AppPayloadType.text, <String, Object?>{'text': 'new here'},
        channelId: _channelA, layoutGeneration: 1);
    await dave.store.removePendingEnvelope(fromDave.idempotencyKey);
    _Client.senders[fromDave.idempotencyKey] = dave.deviceId;
    expect(
        await alice.sealedUnderChannelKey(fromDave,
            channelId: _channelA, conversationId: _shared),
        isTrue);
  }, skip: skip);
}

Future<void> _accept(_Client from, List<_Client> joiners, List<_Client> members,
    {String conversation = _conversation}) async {
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
    final service = TestNativeCryptoService(
        bindings: bindings,
        localStore: local,
        clock: () => DateTime.now().add(_skew));
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

  Future<MessageEnvelope> send(String text) async {
    final envelope = await service.encryptPayload(
        _conversation, AppPayloadType.text, <String, Object?>{'text': text});
    senders[envelope.idempotencyKey] = deviceId;
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  Future<void> receive(_Client from, MessageEnvelope sent,
      {List<int>? body}) async {
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
        sealedBody: body ?? sent.sealedBody,
        createdAt: DateTime.now().toUtc(),
      ),
      nextEvent(),
    );
  }

  Future<int> epoch() async => (await service.groupEpoch(_conversation))!.epoch;

  Future<C7ChannelView?> view(
          [String? channelId, String conversation = _conversation]) =>
      service.c7ChannelView(conversation, channelId ?? _channel);

  Future<C7ChannelBook> book() async => C7ChannelBook.decode(
      await store.loadSetting(c7ChannelSetting(_conversation, _channel)),
      _channel,
      _conversation);

  Future<C7GroupState> group([String conversation = _conversation]) async =>
      C7GroupState.decode(
          await store.loadSetting(c7GroupSetting(conversation)));

  Future<List<LocalMessage>> rows() => store.loadMessages(_conversation);

  /// Whether [sent]'s body opens under the post key of [key], or of any
  /// generation this device holds.
  Future<bool> sealedUnderChannelKey(MessageEnvelope sent,
      {Uint8List? key,
      String? channelId,
      String conversationId = _conversation}) async {
    final channel = channelId ?? _channel;
    final keys = C7Keys(bindings);
    final candidates = key != null
        ? <Uint8List>[key]
        : <Uint8List>[
            for (final gen in C7ChannelBook.decode(
                    await store
                        .loadSetting(c7ChannelSetting(conversationId, channel)),
                    channel,
                    conversationId)
                .gens)
              if (gen.key != null) gen.key!,
          ];
    final aad = C7Keys.bodyAad(
      conversationId: conversationId,
      channelId: channel,
      senderDeviceId: _senderOf(sent),
      actionId: sent.idempotencyKey,
    );
    for (final chk in candidates) {
      final bodyKey = keys.postBodyKey(
        chk: chk,
        communityId: _community,
        channelId: channel,
        senderDeviceId: _senderOf(sent),
        actionId: sent.idempotencyKey,
      );
      if (keys.openBody(
              bodyKey: bodyKey,
              aad: aad,
              sealed: Uint8List.fromList(sent.sealedBody!)) !=
          null) {
        return true;
      }
    }
    return false;
  }

  static final Map<String, String> senders = <String, String>{};
  String _senderOf(MessageEnvelope sent) => senders[sent.idempotencyKey]!;
}
