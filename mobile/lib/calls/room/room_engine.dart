import 'dart:async';

import 'package:flutter/foundation.dart';

import 'room_ports.dart';

/// B6 group calls and voice rooms: the app engine (S5). Everything lives in
/// memory: a call group is never sealed, backed up or transferred, and a
/// crash means leave and rejoin (design, "The call group").
///
/// Rules this class enforces (docs/designs/B6-group-calls.md):
///  - only devices that are a leaf of the parent conversation's group, and
///    that this device's L1 judgment approves, are ever accepted into the
///    call, checked by whoever commits, by every member that receives an
///    Add, and by the joiner on every Welcome leaf; no call starts or is
///    joined while the parent holds a leaf that is not approved, and nobody
///    is added or removed while that judgment is not loaded;
///  - this device switches to a new epoch's send key only while every call
///    member is an approved parent leaf (it keeps the old one, which the
///    others drop after 10 s, until the member is removed);
///  - the lowest leaf commits within 200 ms, the others after 2 s plus
///    500 ms per rank; every commit is staged, sent, and merged only on the
///    server's yes (a 409 discards it, so no fork);
///  - media keys are derived per epoch by the core and handed to the frame
///    cryptor at ring index `epoch mod 16`; the previous epoch's keys are
///    removed 10 s after the switch; the cryptor must be fail-closed;
///  - the roster is the call group's MLS membership, not the server's list;
///  - a failure that cannot be repaired (a commit that will not apply, an
///    Add that fails the checks) means leave and rejoin, at most twice.
enum RoomPhase { idle, joining, active, left, failed }

enum RoomFailure {
  cryptorNotFailClosed,
  unavailable,
  full,
  welcomeRefused,
  welcomeTimeout,
  commitRefused,

  /// The parent conversation holds a leaf this device's L1 judgment does
  /// not approve (or that judgment could not be loaded).
  parentNotApproved,
  other,
}

class RoomEngine extends ChangeNotifier {
  RoomEngine({
    required this.api,
    required this.crypto,
    required this.parent,
    required this.keys,
    required this.scheduler,
    required this.selfAccountId,
    required this.selfDeviceId,
  });

  final RoomApi api;
  final CallGroupCrypto crypto;
  final ParentGroupView parent;
  final FrameKeySink keys;
  final RoomScheduler scheduler;
  final String selfAccountId;
  final String selfDeviceId;

  static const firstCommitterDelay = Duration(milliseconds: 200);
  static const fallbackCommitDelay = Duration(seconds: 2);
  static const perRankDelay = Duration(milliseconds: 500);
  static const oldKeyLifetime = Duration(seconds: 10);
  static const selfUpdateEvery = Duration(hours: 1);
  static const welcomeWait = Duration(seconds: 30);
  static const maxRejoins = 2;

  /// A call group id is 32 random bytes (design, "The call group").
  static const groupIdBytes = 32;

  /// How long after its expiry a receiver still accepts an offer the
  /// committer accepted in time. The committer itself allows none.
  static const receiverOfferSlack = 120;

  /// Stream slots: voice, camera, screen, screen audio.
  static const streamSlots = 4;

  RoomPhase phase = RoomPhase.idle;
  RoomFailure? failure;
  String? conversationId;
  String? callId;
  String? sfuUrl;
  String? sfuToken;
  int maxDevices = 50;

  Uint8List? _groupId;

  /// Whether this engine created or joined the call group, so it may drop
  /// it. The group id is the server's word: a failed create or join must
  /// never delete a group of that name the device already holds (the core's
  /// `delete_group` is never called on a server's word).
  bool _held = false;
  int _rejoins = 0;
  bool _disposed = false;
  Future<void> _queue = Future.value();
  RoomTimer? _commitTimer;
  RoomTimer? _welcomeTimer;
  RoomTimer? _selfUpdateTimer;
  final Set<String> _seenOffers = {};
  final Map<int, List<String>> _installed = {};
  final List<RoomTimer> _removals = [];
  int _joinEpoch = 0;

  /// The call group's members, in leaf order. This is the roster the app
  /// shows; the server's list is never used for it.
  List<CallMember> get roster {
    final group = _groupId;
    if (phase != RoomPhase.active || group == null) return const [];
    return crypto.members(group);
  }

  int? get epoch {
    final group = _groupId;
    if (phase != RoomPhase.active || group == null) return null;
    return crypto.currentEpoch(group);
  }

  // ---- joining ----------------------------------------------------------

  Future<void> join(String conversation) async {
    if (phase == RoomPhase.joining || phase == RoomPhase.active) return;
    conversationId = conversation;
    failure = null;
    if (!keys.settings.failClosed) {
      _setFailed(RoomFailure.cryptorNotFailClosed);
      return;
    }
    phase = RoomPhase.joining;
    notifyListeners();
    // Review MEDIUM (round 7): a parent leaf that is removed, unapproved or
    // not judged yet could be added to the call; start or join none then.
    final bool clean;
    try {
      clean = await parent.allApproved(conversation);
    } catch (_) {
      _setFailed(RoomFailure.parentNotApproved);
      return;
    }
    if (!clean) {
      _setFailed(RoomFailure.parentNotApproved);
      return;
    }
    final RoomJoinInfo info;
    try {
      info = await api.join(conversation);
    } catch (error) {
      _setFailed(_isFull(error) ? RoomFailure.full : RoomFailure.unavailable);
      return;
    }
    callId = info.callId;
    sfuUrl = info.sfuUrl;
    sfuToken = info.sfuToken;
    maxDevices = info.maxDevices;
    _groupId = info.groupId;
    _joinEpoch = info.epoch;
    try {
      if (info.groupId.length != groupIdBytes) {
        throw StateError('call group id is not 32 bytes');
      }
      if (info.created) {
        crypto.createGroup(info.groupId);
        _held = true;
        phase = RoomPhase.active;
        _installKeys();
        _scheduleSelfUpdate();
        notifyListeners();
        _enqueue(_afterChange);
        return;
      }
      final expires = scheduler.now().millisecondsSinceEpoch ~/ 1000 + 50;
      final offer = crypto.makeJoinOffer(info.groupId, info.nonce, expires);
      await api.sendOffer(
        info.callId,
        nonce: info.nonce,
        keyPackage: offer.keyPackage,
        signature: offer.signature,
        expiresAt: offer.expiresAt,
      );
    } catch (_) {
      await _recover(RoomFailure.other);
      return;
    }
    _welcomeTimer =
        scheduler.after(welcomeWait, () => _enqueue(_welcomeTimedOut));
    notifyListeners();
  }

  bool _isFull(Object error) => error.toString().contains('room_full');

  Future<void> _welcomeTimedOut() async {
    if (phase != RoomPhase.joining) return;
    await _recover(RoomFailure.welcomeTimeout);
  }

  // ---- keeping up ---------------------------------------------------------

  /// Call on a realtime `room.updated`, on a slow poll, and after the parent
  /// conversation's roster changed (a removed parent member is removed from
  /// the call too).
  void refresh() => _enqueue(_refresh);

  void _enqueue(Future<void> Function() job) {
    _queue = _queue.then((_) async {
      if (_disposed) return;
      try {
        await job();
      } catch (_) {
        await _recover(RoomFailure.other);
      }
    });
  }

  Future<void> _refresh() async {
    final id = callId;
    final group = _groupId;
    if (id == null || group == null) return;
    if (phase == RoomPhase.joining) {
      await _tryWelcome(id, group);
      return;
    }
    if (phase != RoomPhase.active) return;
    final commits = await _fetch(id, crypto.currentEpoch(group));
    if (commits == null) return;
    for (final record in commits) {
      if (phase != RoomPhase.active) return;
      if (!await _apply(record, group, id)) return;
    }
    _switchSendKey();
    await _afterChange();
  }

  Future<List<RoomCommitRecord>?> _fetch(String id, int after) async {
    try {
      return await api.commits(id, after: after);
    } on RoomGone {
      await _leaveLocally(RoomPhase.left);
      return null;
    }
  }

  Future<void> _tryWelcome(String id, Uint8List group) async {
    // The Welcome's leaves are checked against approved parent leaves; while
    // that judgment is not loaded, wait for the next refresh.
    if (parent.members(conversationId!) == null) return;
    final commits = await _fetch(id, _joinEpoch);
    if (commits == null) return;
    for (final record in commits) {
      final welcome = record.welcome;
      if (welcome == null) continue;
      final members = crypto.joinWithWelcome(group, welcome);
      if (members == null) continue; // for someone else
      _held = true;
      // The joiner checks every leaf of its Welcome against the parent.
      for (final member in members) {
        if (!parent.hasMember(conversationId!, member)) {
          await _recover(RoomFailure.welcomeRefused);
          return;
        }
      }
      _welcomeTimer?.cancel();
      phase = RoomPhase.active;
      _installKeys();
      _scheduleSelfUpdate();
      notifyListeners();
      // Anything committed after the one that added us.
      await _refresh();
      return;
    }
  }

  /// Processes one commit by another device. False means it was refused and
  /// the call is being repaired.
  Future<bool> _apply(
      RoomCommitRecord record, Uint8List group, String id) async {
    if (record.epoch != crypto.currentEpoch(group) + 1) return true;
    // Its Adds cannot be checked while the parent's L1 judgment is not
    // loaded: stop here and apply it on the next refresh.
    if (parent.members(conversationId!) == null) return false;
    final ProcessedCommit result;
    try {
      result = crypto.processCommit(group, record.commit);
    } catch (_) {
      await _recover(RoomFailure.commitRefused);
      return false;
    }
    if (result.removedSelf) {
      await _leaveLocally(RoomPhase.left);
      return false;
    }
    // Every member checks every Add it receives.
    RoomState? state;
    for (final added in result.added) {
      if (!parent.hasMember(conversationId!, added)) {
        await _recover(RoomFailure.commitRefused);
        return false;
      }
      state ??= await api.state(id);
      final seat = state.seats.where((s) => s.id == added.id).firstOrNull;
      if (seat == null ||
          !_offerValid(group, added, seat, committing: false) ||
          !_seenOffers.add(_offerKey(seat.offerKeyPackage!))) {
        // No valid signed offer, or a KeyPackage already used in this call.
        await _recover(RoomFailure.commitRefused);
        return false;
      }
    }
    _installKeys();
    notifyListeners();
    return true;
  }

  String _offerKey(Uint8List keyPackage) => keyPackage.join(',');

  bool _offerValid(Uint8List group, CallMember member, RoomSeat seat,
      {required bool committing}) {
    final nonce = seat.offerNonce;
    final expires = seat.offerExpiresAt;
    final kp = seat.offerKeyPackage;
    final signature = seat.offerSignature;
    if (nonce == null || expires == null || kp == null || signature == null) {
      return false;
    }
    // The committer refuses an expired offer. A receiver allows some slack,
    // because it may process the commit a little after the committer did.
    final now = scheduler.now().millisecondsSinceEpoch ~/ 1000;
    if (now > expires + (committing ? 0 : receiverOfferSlack)) return false;
    return crypto.verifyJoinOffer(
      groupId: group,
      member: member,
      nonce: nonce,
      expiresAt: expires,
      keyPackage: kp,
      signature: signature,
    );
  }

  // ---- track announcements ------------------------------------------------

  /// This device's id in the call group, `account/device`.
  String get selfId => '$selfAccountId/$selfDeviceId';

  /// Seals [plaintext] as an MLS application message of the current epoch,
  /// in the engine's queue so it never races a commit. The envelope names
  /// the epoch and the sender's place in the roster, never an account or
  /// device id (the SFU carries it). Null when the call is not active.
  Future<Uint8List?> sealSignal(Uint8List plaintext) => _run(() async {
        final group = _groupId;
        if (phase != RoomPhase.active || group == null) return null;
        final members = crypto.members(group);
        final position = members.indexWhere((m) => m.id == selfId);
        if (position < 0) return null;
        final sealed = crypto.encryptApplication(group, plaintext);
        return Uint8List.fromList([
          ...signalMagic,
          ...(ByteData(10)
                ..setUint64(0, crypto.currentEpoch(group))
                ..setUint16(8, position))
              .buffer
              .asUint8List(),
          ...sealed,
        ]);
      });

  /// Opens a signal from [sealSignal]: its MLS sender must be the roster
  /// member the envelope names. Null for anything that does not open (an
  /// old epoch, a forgery, a call that is not active).
  Future<({CallMember sender, Uint8List plaintext})?> openSignal(
          Uint8List envelope) =>
      _run(() async {
        final group = _groupId;
        if (phase != RoomPhase.active || group == null) return null;
        if (envelope.length <= signalMagic.length + 10) return null;
        for (var i = 0; i < signalMagic.length; i++) {
          if (envelope[i] != signalMagic[i]) return null;
        }
        final header = ByteData.sublistView(
            envelope, signalMagic.length, signalMagic.length + 10);
        if (header.getUint64(0) != crypto.currentEpoch(group)) return null;
        final members = crypto.members(group);
        final position = header.getUint16(8);
        if (position >= members.length) return null;
        final sender = members[position];
        if (sender.id == selfId) return null;
        try {
          final plaintext = crypto.decryptApplication(
              group, envelope.sublist(signalMagic.length + 10), sender);
          return (sender: sender, plaintext: plaintext);
        } catch (_) {
          return null;
        }
      });

  /// `VB6S`, version 1 of the signal envelope.
  static final signalMagic = Uint8List.fromList([0x56, 0x42, 0x36, 0x53, 1]);

  Future<T?> _run<T>(Future<T?> Function() job) {
    final done = Completer<T?>();
    _queue = _queue.then((_) async {
      if (_disposed) {
        done.complete(null);
        return;
      }
      try {
        done.complete(await job());
      } catch (_) {
        done.complete(null);
      }
    });
    return done.future;
  }

  // ---- committing ---------------------------------------------------------

  Future<void> _afterChange() async {
    final group = _groupId;
    final id = callId;
    if (phase != RoomPhase.active || group == null || id == null) return;
    final plan = await _plan(group, id);
    _commitTimer?.cancel();
    _commitTimer = null;
    if (plan == null) return;
    final members = crypto.members(group);
    final rank =
        members.indexWhere((m) => m.id == '$selfAccountId/$selfDeviceId');
    if (rank < 0) return;
    final delay = rank == 0
        ? firstCommitterDelay
        : fallbackCommitDelay + perRankDelay * (rank - 1);
    _commitTimer = scheduler.after(delay, () => _enqueue(_commitNow));
  }

  Future<
      ({
        List<({Uint8List keyPackage, CallMember member})> adds,
        List<CallMember> removes,
        List<String> addedDeviceIds
      })?> _plan(Uint8List group, String id) async {
    final RoomState state;
    try {
      state = await api.state(id);
    } on RoomGone {
      await _leaveLocally(RoomPhase.left);
      return null;
    }
    final members = crypto.members(group);
    final inCall = {for (final m in members) m.id};
    // Nobody is added or removed while the parent's L1 judgment is not
    // loaded: an empty roster would remove everyone.
    final approved = parent.members(conversationId!);
    if (approved == null) return null;
    final parentMembers = {for (final m in approved) m.id: m};
    final self = '$selfAccountId/$selfDeviceId';
    final adds = <({Uint8List keyPackage, CallMember member})>[];
    // Devices that left and joined again: the server gave them a new seat
    // that waits with a fresh offer while their old leaf is still in the
    // group. The old leaf goes in the same commit that adds the new one.
    final rejoined = <String>{};
    for (final seat in state.seats) {
      if (seat.id == self || !seat.hasOffer) continue;
      if (inCall.contains(seat.id) && seat.inGroup) continue;
      final known = parentMembers[seat.id];
      if (known == null) continue; // never a stranger
      final member =
          CallMember(seat.accountId, seat.deviceId, known.signingKey);
      if (!parent.hasMember(conversationId!, member)) continue;
      if (!_offerValid(group, member, seat, committing: true)) continue;
      if (_seenOffers.contains(_offerKey(seat.offerKeyPackage!))) continue;
      adds.add((keyPackage: seat.offerKeyPackage!, member: member));
      if (inCall.contains(seat.id)) rejoined.add(seat.id);
    }
    final present = {for (final s in state.seats) s.id};
    final removes = [
      for (final m in members)
        if (m.id != self &&
            (!present.contains(m.id) ||
                !parentMembers.containsKey(m.id) ||
                rejoined.contains(m.id)))
          m,
    ];
    if (adds.isEmpty && removes.isEmpty) return null;
    return (
      adds: adds,
      removes: removes,
      addedDeviceIds: [for (final a in adds) a.member.deviceId],
    );
  }

  Future<void> _commitNow() async {
    final group = _groupId;
    final id = callId;
    if (phase != RoomPhase.active || group == null || id == null) return;
    final plan = await _plan(group, id);
    if (plan == null) return;
    await _stageAndSend(group, id,
        adds: plan.adds,
        removes: plan.removes,
        addedDeviceIds: plan.addedDeviceIds);
  }

  Future<void> _stageAndSend(
    Uint8List group,
    String id, {
    List<({Uint8List keyPackage, CallMember member})> adds = const [],
    List<CallMember> removes = const [],
    List<String> addedDeviceIds = const [],
  }) async {
    final staged = crypto.stageCommit(group, adds: adds, removes: removes);
    try {
      await api.sendCommit(
        id,
        expectedEpoch: staged.epoch,
        commit: staged.commit,
        welcome: staged.welcome,
        addedDeviceIds: addedDeviceIds,
      );
    } on RoomEpochConflict {
      // Someone else won this epoch: nothing of ours was merged.
      crypto.discardStaged(group);
      _enqueue(_refresh);
      return;
    } on RoomGone {
      crypto.discardStaged(group);
      await _leaveLocally(RoomPhase.left);
      return;
    } catch (_) {
      crypto.discardStaged(group);
      rethrow;
    }
    crypto.mergeStaged(group);
    for (final add in adds) {
      _seenOffers.add(_offerKey(add.keyPackage));
    }
    _installKeys();
    notifyListeners();
    await _afterChange();
  }

  void _scheduleSelfUpdate() {
    _selfUpdateTimer?.cancel();
    _selfUpdateTimer = scheduler.after(selfUpdateEvery, () {
      _enqueue(() async {
        final group = _groupId;
        final id = callId;
        if (phase != RoomPhase.active || group == null || id == null) return;
        await _stageAndSend(group, id);
        _scheduleSelfUpdate();
      });
    });
  }

  // ---- keys ---------------------------------------------------------------

  void _installKeys() {
    final group = _groupId;
    final id = callId;
    if (group == null || id == null) return;
    final epochNow = crypto.currentEpoch(group);
    final index = epochNow % keys.settings.keyRingSize;
    final participants = <String>[];
    for (final member in crypto.members(group)) {
      for (var slot = 0; slot < streamSlots; slot++) {
        final participant = '${member.id}:$slot';
        keys.setKey(
            participant, index, crypto.mediaKey(group, id, member, slot));
        participants.add(participant);
      }
    }
    // A sender switches only after it has merged the commit, and only while
    // every member is an approved parent leaf ([_switchSendKey]).
    _pendingSendIndex = index;
    _switchSendKey();
    final previous = _installed.keys.where((e) => e != epochNow).toList();
    _installed[epochNow] = participants;
    for (final old in previous) {
      final oldParticipants = _installed.remove(old)!;
      final oldIndex = old % keys.settings.keyRingSize;
      if (oldIndex == index) continue; // the ring slot was just overwritten
      _removals.add(scheduler.after(oldKeyLifetime, () {
        for (final participant in oldParticipants) {
          keys.removeKey(participant, oldIndex);
        }
      }));
    }
  }

  /// The send key index waiting for [_switchSendKey], if any.
  int? _pendingSendIndex;

  /// Review LOW (round 7): this device's media moves to a new epoch's key
  /// only while every call member is a leaf of the parent that the L1
  /// judgment approves. A member that lost approval (or whose parent leaf
  /// is gone) never gets media under a key this device switched to after
  /// that; the committer removes it, and the switch follows. Until then
  /// this device keeps sending under the previous key, which the others
  /// drop after [oldKeyLifetime] (fail closed: silence, never a leak).
  void _switchSendKey() {
    final index = _pendingSendIndex;
    final group = _groupId;
    final conversation = conversationId;
    if (index == null || group == null || conversation == null) return;
    for (final member in crypto.members(group)) {
      if (!parent.hasMember(conversation, member)) return;
    }
    keys.useSendKey(index);
    _pendingSendIndex = null;
  }

  // ---- leaving and failing ------------------------------------------------

  Future<void> leave() async {
    if (phase == RoomPhase.idle || phase == RoomPhase.left) return;
    final id = callId;
    if (id != null) {
      try {
        await api.leave(id);
      } catch (_) {
        // The server drops a silent device after its SFU connection ends.
      }
    }
    await _leaveLocally(RoomPhase.left);
  }

  Future<void> _leaveLocally(RoomPhase next) async {
    _commitTimer?.cancel();
    _welcomeTimer?.cancel();
    _selfUpdateTimer?.cancel();
    _commitTimer = _welcomeTimer = _selfUpdateTimer = null;
    final group = _groupId;
    if (group != null && _held) crypto.drop(group);
    _held = false;
    for (final timer in _removals) {
      timer.cancel();
    }
    _removals.clear();
    _installed.clear();
    _seenOffers.clear();
    _pendingSendIndex = null;
    keys.clear();
    _groupId = null;
    phase = next;
    notifyListeners();
  }

  /// The media transport could not keep frame encryption fail closed: the
  /// call is left and not rejoined.
  Future<void> failClosed() async {
    if (phase == RoomPhase.failed) return;
    await leave();
    _setFailed(RoomFailure.cryptorNotFailClosed);
  }

  /// A failure that leave-and-rejoin may repair.
  Future<void> _recover(RoomFailure why) async {
    final conversation = conversationId;
    final id = callId;
    if (id != null) {
      try {
        await api.leave(id);
      } catch (_) {}
    }
    await _leaveLocally(RoomPhase.left);
    if (conversation != null && _rejoins < maxRejoins && !_disposed) {
      _rejoins++;
      phase = RoomPhase.idle;
      await join(conversation);
      return;
    }
    _setFailed(why);
  }

  void _setFailed(RoomFailure why) {
    failure = why;
    phase = RoomPhase.failed;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final group = _groupId;
    if (group != null && _held) crypto.drop(group);
    _held = false;
    keys.clear();
    _commitTimer?.cancel();
    _welcomeTimer?.cancel();
    _selfUpdateTimer?.cancel();
    for (final timer in _removals) {
      timer.cancel();
    }
    super.dispose();
  }
}

/// One open call: the engine, the media controls (null when the build has
/// no media transport) and [close], which leaves, ends the media and
/// forgets the call group.
class RoomCall {
  RoomCall({required this.engine, this.controls, required this.close});
  final RoomEngine engine;
  final RoomMediaControls? controls;
  final Future<void> Function() close;
}

/// What the app needs to offer group calls: a way to open a call for one
/// conversation and contact names. Set on the app state only by the demo
/// host, like the one-to-one call controller (B5).
class RoomSession {
  const RoomSession({required this.openCall, required this.nameFor});

  /// Throws when a call cannot be opened fail closed (no frame encryption,
  /// no active MLS device).
  final Future<RoomCall> Function(String conversationId) openCall;
  final String Function(String accountId) nameFor;
}
