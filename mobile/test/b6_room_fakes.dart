import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/room/room_engine.dart';
import 'package:private_messenger/calls/room/room_ports.dart';

// Fakes of the server, the MLS core, the parent conversation and the frame
// cryptor, all in process, for the B6 room engine and its screen.

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
