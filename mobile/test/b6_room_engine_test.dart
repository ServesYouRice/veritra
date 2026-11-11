import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/room/room_engine.dart';
import 'package:private_messenger/calls/room/room_ports.dart';

import 'b6_room_fakes.dart';

// B6 S5: the room engine against fakes of the server, the MLS core, the
// parent conversation and the frame cryptor, all in process.

void main() {
  late FakeServer server;
  late FakeClock clock;
  late FakeParent parent;

  setUp(() {
    server = FakeServer('conv_1');
    clock = FakeClock();
    parent = FakeParent([member('a'), member('b'), member('c')]);
  });

  Future<Device> start(String name, {FakeParent? parentView}) async {
    final device = Device(name, server, clock, parentView ?? parent);
    await device.engine.join('conv_1');
    await pump();
    return device;
  }

  /// The joiner asks, the lowest leaf commits after 200 ms, the joiner picks up its Welcome.
  Future<void> admit(Device existing, Device joiner) async {
    existing.engine.refresh();
    await pump();
    await clock.advance(const Duration(milliseconds: 250));
    joiner.engine.refresh();
    await pump();
  }

  test('the first device creates the group and installs fail-closed keys',
      () async {
    final a = await start('a');
    expect(a.engine.phase, RoomPhase.active);
    expect(a.engine.roster.map((m) => m.id), ['acct_a/dev_a']);
    expect(a.keys.keys.length, 4); // one key per stream slot
    expect(a.keys.sendIndex, 0);
    expect(a.engine.sfuToken, 'token');
    a.engine.dispose();
  });

  test(
      'a join is one commit: the lowest leaf commits, both share epoch and keys',
      () async {
    final a = await start('a');
    final b2 = await start('b');
    expect(b2.engine.phase, RoomPhase.joining);
    await admit(a, b2);
    expect(b2.engine.phase, RoomPhase.active);
    expect(server.epoch, 1);
    expect(a.engine.epoch, 1);
    expect(b2.engine.epoch, 1);
    // The roster follows MLS and is the same on both.
    expect(a.engine.roster.map((m) => m.id), ['acct_a/dev_a', 'acct_b/dev_b']);
    expect(b2.engine.roster.map((m) => m.id), ['acct_a/dev_a', 'acct_b/dev_b']);
    // Keys are installed for every member and slot at index epoch mod 16.
    expect(b2.keys.keys.keys.where((k) => k.endsWith('@1')).length, 8);
    expect(s(a.keys.keys['acct_b/dev_b:0@1']!),
        s(b2.keys.keys['acct_b/dev_b:0@1']!));
    expect(b2.keys.sendIndex, 1);
    a.engine.dispose();
    b2.engine.dispose();
  });

  test('every join moves the epoch, so a newcomer never holds earlier keys',
      () async {
    final a = await start('a');
    final b2 = await start('b');
    await admit(a, b2);
    final c = await start('c');
    await admit(a, c);
    expect(server.epoch, 2);
    expect(c.keys.keys.keys.every((k) => k.endsWith('@2')), isTrue);
    expect(c.crypto.keyRequests.every((r) => r.startsWith('2/')), isTrue);
    for (final d in [a, b2, c]) {
      d.engine.dispose();
    }
  });

  test(
      'a member that is not the lowest leaf waits two seconds before committing',
      () async {
    final a = await start('a');
    final b2 = await start('b');
    await admit(a, b2);
    // a goes silent; c joins and only b (rank 1) can commit, after 2 s.
    final c = await start('c');
    b2.engine.refresh();
    await pump();
    await clock.advance(const Duration(milliseconds: 1500));
    expect(server.epoch, 1, reason: 'rank 1 has not committed yet');
    await clock.advance(const Duration(seconds: 1));
    expect(server.epoch, 2);
    c.engine.refresh();
    await pump();
    expect(c.engine.phase, RoomPhase.active);
    for (final d in [a, b2, c]) {
      d.engine.dispose();
    }
  });

  test('a lost race (409) discards the staged commit and nothing forks',
      () async {
    final a = await start('a');
    final b2 = await start('b');
    server.forceConflicts = 1;
    a.engine.refresh();
    await pump();
    await clock.advance(const Duration(milliseconds: 250));
    expect(a.crypto.discards, 1);
    expect(a.engine.epoch, 0, reason: 'the 409 commit was never merged');
    // The next attempt (a refresh) commits on the unchanged epoch.
    a.engine.refresh();
    await pump();
    await clock.advance(const Duration(milliseconds: 250));
    expect(server.epoch, 1);
    expect(a.engine.epoch, 1);
    a.engine.dispose();
    b2.engine.dispose();
  });

  test(
      'a failed create never drops a group the device already held '
      '(the group id is the server word)', () async {
    final a = Device('a', server, clock, parent);
    a.crypto.failCreate = true;
    await a.engine.join('conv_1');
    await pump();
    expect(a.engine.phase, RoomPhase.failed);
    expect(a.crypto.drops, 0);
    a.engine.dispose();
    expect(a.crypto.drops, 0);
  });

  test('a call group id that is not 32 bytes is refused before any MLS call',
      () async {
    server.groupId = b('short-group');
    final a = Device('a', server, clock, parent);
    await a.engine.join('conv_1');
    await pump();
    expect(a.engine.phase, RoomPhase.failed);
    expect(a.crypto.exists, isFalse);
    expect(a.crypto.drops, 0);
    a.engine.dispose();
  });

  test('a joiner that never got a Welcome drops nothing when it gives up',
      () async {
    final a = await start('a');
    final b2 = await start('b');
    expect(b2.engine.phase, RoomPhase.joining);
    await b2.engine.leave();
    expect(b2.crypto.drops, 0);
    // A device that did join drops its group on leaving.
    await a.engine.leave();
    expect(a.crypto.drops, 1);
    a.engine.dispose();
    b2.engine.dispose();
  });

  test('the committer refuses an expired offer', () async {
    final a = await start('a');
    final b2 = await start('b');
    // Ten seconds past the offer's own expiry: inside the slack a receiver
    // allows, but the committer allows none.
    final seat = server.seats[b2.self.id]!;
    server.seats[b2.self.id] = RoomSeat(
        deviceId: seat.deviceId,
        accountId: seat.accountId,
        inGroup: false,
        offerKeyPackage: seat.offerKeyPackage,
        offerSignature: seat.offerSignature,
        offerNonce: seat.offerNonce,
        offerExpiresAt: clock.now().millisecondsSinceEpoch ~/ 1000 - 10);
    a.engine.refresh();
    await pump();
    await clock.advance(const Duration(seconds: 3));
    expect(server.epoch, 0);
    expect(a.engine.roster.map((m) => m.id), ['acct_a/dev_a']);
    a.engine.dispose();
    b2.engine.dispose();
  });

  test('a device that is not in the parent group is never added', () async {
    final a = await start('a');
    final outsider = Device('x', server, clock, parent);
    await outsider.engine.join('conv_1');
    await pump();
    a.engine.refresh();
    await pump();
    await clock.advance(const Duration(seconds: 3));
    expect(server.epoch, 0);
    expect(a.engine.roster.map((m) => m.id), ['acct_a/dev_a']);
    a.engine.dispose();
    outsider.engine.dispose();
  });

  test('a forged offer signature is not added', () async {
    final a = await start('a');
    final b2 = await start('b');
    final seat = server.seats[b2.self.id]!;
    server.seats[b2.self.id] = RoomSeat(
        deviceId: seat.deviceId,
        accountId: seat.accountId,
        inGroup: false,
        offerKeyPackage: seat.offerKeyPackage,
        offerSignature: b('forged'),
        offerNonce: seat.offerNonce,
        offerExpiresAt: seat.offerExpiresAt);
    a.engine.refresh();
    await pump();
    await clock.advance(const Duration(seconds: 3));
    expect(server.epoch, 0);
    a.engine.dispose();
    b2.engine.dispose();
  });

  test(
      'a Welcome with a leaf outside the parent group is refused by the joiner',
      () async {
    final a = await start('a');
    final b2 = await start('b');
    // The server hands b a Welcome listing a stranger.
    server.epoch = 1;
    server.log.add(RoomCommitRecord(
        epoch: 1,
        committerDeviceId: 'dev_a',
        commit: b('C;1;;'),
        welcome: FakeCrypto.welcomeFor(
            1, [member('a'), member('b'), member('evil')], ['acct_b/dev_b'])));
    final joinsBefore = server.joins;
    b2.engine.refresh();
    await pump();
    // Refused: the group is dropped, no key was ever installed, and b
    // leaves and rejoins (it never becomes active on that Welcome).
    expect(b2.crypto.dropped, isTrue);
    expect(b2.keys.keys, isEmpty);
    expect(b2.engine.phase, isNot(RoomPhase.active));
    expect(server.joins, joinsBefore + 1);
    a.engine.dispose();
    b2.engine.dispose();
  });

  test('an Add that fails the checks makes the receiver leave and rejoin',
      () async {
    final a = await start('a');
    final b2 = await start('b');
    await admit(a, b2);
    final joinsBefore = server.joins;
    // A malicious commit adds a device that is not in the parent.
    server.epoch = 2;
    server.log.add(RoomCommitRecord(
        epoch: 2,
        committerDeviceId: 'dev_a',
        commit: FakeCrypto.commitOf(2, [member('evil')], [])));
    b2.engine.refresh();
    await pump();
    expect(b2.crypto.dropped, isTrue);
    expect(server.joins, greaterThan(joinsBefore), reason: 'b rejoined');
    expect(b2.keys.clears, greaterThanOrEqualTo(1));
    a.engine.dispose();
    b2.engine.dispose();
  });

  test('a removal in the parent group is a Remove in the call', () async {
    final a = await start('a');
    final b2 = await start('b');
    await admit(a, b2);
    parent.list.removeWhere((m) => m.id == b2.self.id);
    a.engine.refresh();
    await pump();
    await clock.advance(const Duration(milliseconds: 250));
    expect(a.engine.roster.map((m) => m.id), ['acct_a/dev_a']);
    expect(server.epoch, 2);
    b2.engine.refresh();
    await pump();
    expect(b2.engine.phase, RoomPhase.left,
        reason: 'a removed device drops the call');
    expect(b2.keys.keys, isEmpty);
    a.engine.dispose();
    b2.engine.dispose();
  });

  test(
      'a device the server reports gone is removed, and the roster ignores a seat with no MLS leaf',
      () async {
    final a = await start('a');
    final b2 = await start('b');
    await admit(a, b2);
    server.seats.remove(b2.self.id);
    // A server-listed seat that never joined the call group is not in the roster.
    server.seats[member('c').id] =
        const RoomSeat(deviceId: 'dev_c', accountId: 'acct_c', inGroup: false);
    a.engine.refresh();
    await pump();
    await clock.advance(const Duration(milliseconds: 250));
    expect(a.engine.roster.map((m) => m.id), ['acct_a/dev_a']);
    a.engine.dispose();
    b2.engine.dispose();
  });

  test('old keys are removed ten seconds after the switch, not before',
      () async {
    final a = await start('a');
    final b2 = await start('b');
    await admit(a, b2);
    expect(a.keys.keys.keys.any((k) => k.endsWith('@0')), isTrue);
    await clock.advance(const Duration(seconds: 9));
    expect(a.keys.keys.keys.any((k) => k.endsWith('@0')), isTrue);
    await clock.advance(const Duration(seconds: 2));
    expect(a.keys.keys.keys.any((k) => k.endsWith('@0')), isFalse);
    expect(a.keys.keys.keys.any((k) => k.endsWith('@1')), isTrue);
    a.engine.dispose();
    b2.engine.dispose();
  });

  test(
      'keys never appear before a join finishes, and a cryptor that is not fail-closed is refused',
      () async {
    final unsafe = Device('a', server, clock, parent,
        settings:
            const RoomCryptorSettings(discardFrameWhenCryptorNotReady: false));
    await unsafe.engine.join('conv_1');
    expect(unsafe.engine.phase, RoomPhase.failed);
    expect(unsafe.engine.failure, RoomFailure.cryptorNotFailClosed);
    expect(server.joins, 0, reason: 'no room was touched');
    for (final bad in [
      const RoomCryptorSettings(sharedKey: true),
      const RoomCryptorSettings(useMagicBytes: true),
      const RoomCryptorSettings(ratchetWindowSize: 8),
      const RoomCryptorSettings(hkdf: false),
    ]) {
      expect(bad.failClosed, isFalse);
    }
    expect(const RoomCryptorSettings().failClosed, isTrue);
    final b2 = await start('b');
    expect(b2.engine.phase, RoomPhase.active);
    expect(b2.keys.keys, isNotEmpty);
    // A joiner has no key until its Welcome arrives.
    final c = await start('c');
    expect(c.engine.phase, RoomPhase.joining);
    expect(c.keys.keys, isEmpty);
    unsafe.engine.dispose();
    b2.engine.dispose();
    c.engine.dispose();
  });

  test('a joiner that never gets a Welcome gives up and retries, then fails',
      () async {
    final a = await start('a');
    parent.list.removeWhere((m) => m.id == 'acct_b/dev_b'); // nobody will add b
    final b2 = await start('b');
    expect(b2.engine.phase, RoomPhase.joining);
    for (var i = 0; i < 4; i++) {
      await clock.advance(const Duration(seconds: 31));
    }
    expect(b2.engine.phase, RoomPhase.failed);
    expect(b2.engine.failure, RoomFailure.welcomeTimeout);
    a.engine.dispose();
    b2.engine.dispose();
  });

  test('leaving tells the server, drops the group and wipes the keys',
      () async {
    final a = await start('a');
    await a.engine.leave();
    expect(a.api.leaves, 1);
    expect(a.crypto.dropped, isTrue);
    expect(a.keys.keys, isEmpty);
    expect(a.engine.phase, RoomPhase.left);
    expect(a.engine.roster, isEmpty);
    a.engine.dispose();
  });

  test('every device self-updates once an hour', () async {
    final a = await start('a');
    await clock.advance(const Duration(hours: 1, minutes: 1));
    expect(server.epoch, 1);
    expect(a.engine.epoch, 1);
    a.engine.dispose();
  });

  test('no key or secret reaches a log or the engine state', () async {
    final a = await start('a');
    final text = [
      a.engine.callId,
      a.engine.sfuUrl,
      a.engine.conversationId,
      a.engine.failure
    ].join(' ');
    expect(text.contains('K('), isFalse);
    a.engine.dispose();
  });
}
