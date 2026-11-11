import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/room/room_engine.dart';
import 'package:private_messenger/calls/room/room_ports.dart';

// B6 S5: the room engine against fakes of the server, the MLS core, the
// parent conversation and the frame cryptor, all in process.

Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
String s(List<int> bytes) => utf8.decode(bytes);

CallMember member(String name) =>
    CallMember('acct_$name', 'dev_$name', b('key_$name'));

class FakeClock implements RoomScheduler {
  DateTime current = DateTime.utc(2026, 11, 11, 12);
  final List<_FakeTimer> timers = [];

  @override
  DateTime now() => current;

  @override
  RoomTimer after(Duration delay, void Function() action) {
    final timer = _FakeTimer(current.add(delay), action);
    timers.add(timer);
    return timer;
  }

  /// Moves time forward, running every timer that falls due in order.
  Future<void> advance(Duration by) async {
    final target = current.add(by);
    while (true) {
      final due = timers
          .where((t) => !t.cancelled && !t.fired && !t.at.isAfter(target))
          .toList()
        ..sort((a, c) => a.at.compareTo(c.at));
      if (due.isEmpty) break;
      final next = due.first;
      current = next.at;
      next.fired = true;
      next.action();
      await pump();
    }
    current = target;
    await pump();
  }
}

class _FakeTimer implements RoomTimer {
  _FakeTimer(this.at, this.action);
  final DateTime at;
  final void Function() action;
  bool cancelled = false;
  bool fired = false;
  @override
  void cancel() => cancelled = true;
}

Future<void> pump() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FakeServer {
  FakeServer(this.conversation);
  final String conversation;
  String callId = 'room_1';
  final Uint8List groupId = b('group-bytes-1');
  int epoch = 0;
  final Map<String, RoomSeat> seats = {};
  final List<RoomCommitRecord> log = [];
  final Set<String> ended = {};
  int forceConflicts = 0;
  int joins = 0;
  int sentCommits = 0;
}

class FakeApi implements RoomApi {
  FakeApi(this.server, this.self);
  final FakeServer server;
  final CallMember self;
  int leaves = 0;
  String? lastNonce;

  @override
  Future<RoomJoinInfo> join(String conversationId) async {
    final created = server.seats.isEmpty;
    server.joins++;
    final nonce = 'nonce_${self.deviceId}_${server.joins}';
    lastNonce = nonce;
    server.seats[self.id] = RoomSeat(
        deviceId: self.deviceId,
        accountId: self.accountId,
        inGroup: created,
        offerNonce: nonce);
    return RoomJoinInfo(
      callId: server.callId,
      groupId: server.groupId,
      epoch: server.epoch,
      created: created,
      seats: server.seats.values.toList(),
      sfuUrl: 'wss://sfu.test',
      sfuToken: 'token',
      nonce: nonce,
      maxDevices: 50,
    );
  }

  @override
  Future<RoomState> state(String callId) async => RoomState(
      callId: callId,
      groupId: server.groupId,
      epoch: server.epoch,
      seats: server.seats.values.toList());

  @override
  Future<List<RoomCommitRecord>> commits(String callId,
      {required int after}) async {
    if (!server.seats.containsKey(self.id)) throw const RoomGone();
    return server.log.where((c) => c.epoch > after).toList();
  }

  @override
  Future<int> sendCommit(String callId,
      {required int expectedEpoch,
      required Uint8List commit,
      Uint8List? welcome,
      List<String> addedDeviceIds = const []}) async {
    server.sentCommits++;
    if (server.forceConflicts > 0) {
      server.forceConflicts--;
      throw const RoomEpochConflict();
    }
    if (expectedEpoch != server.epoch) throw const RoomEpochConflict();
    server.epoch++;
    server.log.add(RoomCommitRecord(
        epoch: server.epoch,
        committerDeviceId: self.deviceId,
        commit: commit,
        welcome: welcome));
    for (final id in addedDeviceIds) {
      final key = server.seats.keys.firstWhere((k) => k.endsWith('/$id'));
      final seat = server.seats[key]!;
      server.seats[key] = RoomSeat(
          deviceId: seat.deviceId,
          accountId: seat.accountId,
          inGroup: true,
          offerKeyPackage: seat.offerKeyPackage,
          offerSignature: seat.offerSignature,
          offerNonce: seat.offerNonce,
          offerExpiresAt: seat.offerExpiresAt);
    }
    return server.epoch;
  }

  @override
  Future<void> sendOffer(String callId,
      {required String nonce,
      required Uint8List keyPackage,
      required Uint8List signature,
      required int expiresAt}) async {
    final seat = server.seats[self.id]!;
    server.seats[self.id] = RoomSeat(
        deviceId: seat.deviceId,
        accountId: seat.accountId,
        inGroup: false,
        offerKeyPackage: keyPackage,
        offerSignature: signature,
        offerNonce: nonce,
        offerExpiresAt: expiresAt);
  }

  @override
  Future<void> leave(String callId) async {
    leaves++;
    server.seats.remove(self.id);
  }
}

/// A group of fake MLS state per device. Commits and Welcomes are text so a
/// test can read and forge them.
class FakeCrypto implements CallGroupCrypto {
  FakeCrypto(this.self);
  final CallMember self;
  List<CallMember> _members = [];
  int _epoch = 0;
  bool exists = false;
  String? staged;
  int discards = 0;
  bool dropped = false;
  final List<String> keyRequests = [];

  static String _enc(CallMember m) =>
      '${m.accountId}|${m.deviceId}|${s(m.signingKey)}';
  static CallMember _dec(String t) {
    final p = t.split('|');
    return CallMember(p[0], p[1], b(p[2]));
  }

  static Uint8List welcomeFor(
          int epoch, List<CallMember> members, List<String> targets) =>
      b('W;$epoch;${members.map(_enc).join(',')};${targets.join(',')}');

  static Uint8List commitOf(
          int newEpoch, List<CallMember> adds, List<CallMember> removes) =>
      b('C;$newEpoch;${adds.map(_enc).join(',')};${removes.map(_enc).join(',')}');

  @override
  void createGroup(Uint8List groupId) {
    exists = true;
    _members = [self];
    _epoch = 0;
  }

  @override
  List<CallMember>? joinWithWelcome(Uint8List groupId, Uint8List welcome) {
    final p = s(welcome).split(';');
    if (!p[3].split(',').contains(self.id)) return null;
    exists = true;
    _epoch = int.parse(p[1]);
    _members = [for (final e in p[2].split(',')) _dec(e)];
    return _members;
  }

  @override
  JoinOffer makeJoinOffer(Uint8List groupId, String nonce, int expiresAt) =>
      JoinOffer(
          keyPackage: b('kp_${self.id}_$nonce'),
          signature: b('sig:${self.id}:$nonce'),
          expiresAt: expiresAt);

  @override
  bool verifyJoinOffer({
    required Uint8List groupId,
    required CallMember member,
    required String nonce,
    required int expiresAt,
    required Uint8List keyPackage,
    required Uint8List signature,
  }) =>
      s(signature) == 'sig:${member.id}:$nonce';

  @override
  List<CallMember> members(Uint8List groupId) => List.of(_members);

  @override
  int currentEpoch(Uint8List groupId) => _epoch;

  @override
  StagedCommit stageCommit(Uint8List groupId,
      {List<({Uint8List keyPackage, CallMember member})> adds = const [],
      List<CallMember> removes = const []}) {
    final addMembers = [for (final a in adds) a.member];
    staged = s(commitOf(_epoch + 1, addMembers, removes));
    final after = [
      for (final m in _members)
        if (!removes.any((r) => r.id == m.id)) m,
      ...addMembers,
    ];
    return StagedCommit(
      commit: b(staged!),
      welcome: addMembers.isEmpty
          ? null
          : welcomeFor(_epoch + 1, after, [for (final a in addMembers) a.id]),
      epoch: _epoch,
    );
  }

  @override
  void mergeStaged(Uint8List groupId) {
    _apply(staged!);
    staged = null;
  }

  @override
  void discardStaged(Uint8List groupId) {
    discards++;
    staged = null;
  }

  ProcessedCommit _apply(String commit) {
    final p = commit.split(';');
    final adds = p[2].isEmpty
        ? <CallMember>[]
        : [for (final e in p[2].split(',')) _dec(e)];
    final removes = p[3].isEmpty
        ? <CallMember>[]
        : [for (final e in p[3].split(',')) _dec(e)];
    _epoch = int.parse(p[1]);
    _members = [
      for (final m in _members)
        if (!removes.any((r) => r.id == m.id)) m,
      ...adds,
    ];
    return ProcessedCommit(
        epoch: _epoch,
        added: adds,
        removedSelf: removes.any((r) => r.id == self.id));
  }

  @override
  ProcessedCommit processCommit(Uint8List groupId, Uint8List commit) =>
      _apply(s(commit));

  @override
  Uint8List mediaKey(
      Uint8List groupId, String callId, CallMember sender, int stream) {
    keyRequests.add('$_epoch/${sender.id}/$stream');
    return b('K($callId,$_epoch,${sender.id},$stream)');
  }

  @override
  void drop(Uint8List groupId) {
    dropped = true;
    exists = false;
    _members = [];
  }
}

class FakeParent implements ParentGroupView {
  FakeParent(List<CallMember> members) : list = List.of(members);
  final List<CallMember> list;
  @override
  bool hasMember(String conversationId, CallMember member) => list
      .any((m) => m.id == member.id && s(m.signingKey) == s(member.signingKey));
  @override
  List<CallMember> members(String conversationId) => List.of(list);
}

class FakeKeys implements FrameKeySink {
  FakeKeys({this.settings = const RoomCryptorSettings()});
  @override
  final RoomCryptorSettings settings;
  final Map<String, Uint8List> keys = {};
  int? sendIndex;
  int clears = 0;
  final List<String> removed = [];

  @override
  void setKey(String participant, int index, Uint8List key) =>
      keys['$participant@$index'] = key;
  @override
  void removeKey(String participant, int index) {
    keys.remove('$participant@$index');
    removed.add('$participant@$index');
  }

  @override
  void useSendKey(int index) => sendIndex = index;
  @override
  void clear() {
    keys.clear();
    clears++;
  }
}

class Device {
  Device(String name, FakeServer server, FakeClock clock, FakeParent parent,
      {RoomCryptorSettings? settings})
      : self = member(name),
        crypto = FakeCrypto(member(name)),
        keys = FakeKeys(settings: settings ?? const RoomCryptorSettings()) {
    api = FakeApi(server, self);
    engine = RoomEngine(
      api: api,
      crypto: crypto,
      parent: parent,
      keys: keys,
      scheduler: clock,
      selfAccountId: self.accountId,
      selfDeviceId: self.deviceId,
    );
  }
  final CallMember self;
  final FakeCrypto crypto;
  final FakeKeys keys;
  late final FakeApi api;
  late final RoomEngine engine;
}

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
