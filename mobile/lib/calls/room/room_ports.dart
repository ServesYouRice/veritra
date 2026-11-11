import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Listenable;

/// B6 group calls (docs/designs/B6-group-calls.md), the seams of the app
/// engine. The engine owns the rules (who may join, who commits, when keys
/// change); these ports own the platform: the server, the MLS core, the
/// parent conversation and the frame cryptor. Tests run the engine against
/// fakes of all four.

/// One device in a call group, as MLS knows it.
class CallMember {
  const CallMember(this.accountId, this.deviceId, this.signingKey);
  final String accountId;
  final String deviceId;
  final Uint8List signingKey;

  String get id => '$accountId/$deviceId';
}

/// A device the server lists in a room. The offer fields are set while it
/// waits to be added to the call group.
class RoomSeat {
  const RoomSeat({
    required this.deviceId,
    required this.accountId,
    required this.inGroup,
    this.offerKeyPackage,
    this.offerSignature,
    this.offerNonce,
    this.offerExpiresAt,
  });
  final String deviceId;
  final String accountId;
  final bool inGroup;
  final Uint8List? offerKeyPackage;
  final Uint8List? offerSignature;
  final String? offerNonce;

  /// Unix seconds.
  final int? offerExpiresAt;

  String get id => '$accountId/$deviceId';
  bool get hasOffer => offerKeyPackage != null && offerSignature != null;
}

class RoomJoinInfo {
  const RoomJoinInfo({
    required this.callId,
    required this.groupId,
    required this.epoch,
    required this.created,
    required this.seats,
    required this.sfuUrl,
    required this.sfuToken,
    required this.nonce,
    required this.maxDevices,
  });
  final String callId;
  final Uint8List groupId;
  final int epoch;
  final bool created;
  final List<RoomSeat> seats;
  final String sfuUrl;
  final String sfuToken;
  final String nonce;
  final int maxDevices;
}

class RoomState {
  const RoomState({
    required this.callId,
    required this.groupId,
    required this.epoch,
    required this.seats,
  });
  final String callId;
  final Uint8List groupId;
  final int epoch;
  final List<RoomSeat> seats;
}

class RoomCommitRecord {
  const RoomCommitRecord({
    required this.epoch,
    required this.committerDeviceId,
    required this.commit,
    this.welcome,
  });
  final int epoch;
  final String committerDeviceId;
  final Uint8List commit;
  final Uint8List? welcome;
}

/// The server answered 409: another commit won this epoch.
class RoomEpochConflict implements Exception {
  const RoomEpochConflict();
}

/// The room no longer exists or this device is not in it.
class RoomGone implements Exception {
  const RoomGone();
}

abstract interface class RoomApi {
  Future<RoomJoinInfo> join(String conversationId);
  Future<RoomState> state(String callId);
  Future<List<RoomCommitRecord>> commits(String callId, {required int after});

  /// Throws [RoomEpochConflict] on a lost race, [RoomGone] when the room
  /// ended or this device left.
  Future<int> sendCommit(
    String callId, {
    required int expectedEpoch,
    required Uint8List commit,
    Uint8List? welcome,
    List<String> addedDeviceIds = const [],
  });
  Future<void> sendOffer(
    String callId, {
    required String nonce,
    required Uint8List keyPackage,
    required Uint8List signature,
    required int expiresAt,
  });
  Future<void> leave(String callId);
}

/// What a commit this device processed did, read from MLS.
class ProcessedCommit {
  const ProcessedCommit({
    required this.epoch,
    required this.added,
    required this.removedSelf,
  });
  final int epoch;
  final List<CallMember> added;
  final bool removedSelf;
}

/// A commit staged but not merged (the server has not said yes).
class StagedCommit {
  const StagedCommit({required this.commit, this.welcome, required this.epoch});
  final Uint8List commit;
  final Uint8List? welcome;

  /// The epoch the commit was built on.
  final int epoch;
}

class JoinOffer {
  const JoinOffer({
    required this.keyPackage,
    required this.signature,
    required this.expiresAt,
  });
  final Uint8List keyPackage;
  final Uint8List signature;
  final int expiresAt;
}

/// The call group's MLS operations. One instance per device. The group lives
/// in memory only: never in sealed state, a backup or a transfer (D70).
abstract interface class CallGroupCrypto {
  void createGroup(Uint8List groupId);

  /// Joins from a Welcome. Returns every leaf of the new group, or null when
  /// the Welcome is not for this device.
  List<CallMember>? joinWithWelcome(Uint8List groupId, Uint8List welcome);

  /// A fresh KeyPackage for this call, signed with the credential key over
  /// `veritra-b6-join-v1 | lp(group_id) | lp(nonce) | u64(expires) |
  /// sha256(key_package)`.
  JoinOffer makeJoinOffer(Uint8List groupId, String nonce, int expiresAt);

  /// Whether [signature] is [member]'s valid join signature over the offer.
  bool verifyJoinOffer({
    required Uint8List groupId,
    required CallMember member,
    required String nonce,
    required int expiresAt,
    required Uint8List keyPackage,
    required Uint8List signature,
  });

  List<CallMember> members(Uint8List groupId);

  /// Stages (does not merge) a commit that adds [adds] and removes
  /// [removes], or a bare self-update when both are empty. Every add names
  /// the signing key its KeyPackage must hold.
  StagedCommit stageCommit(
    Uint8List groupId, {
    List<({Uint8List keyPackage, CallMember member})> adds = const [],
    List<CallMember> removes = const [],
  });
  void mergeStaged(Uint8List groupId);
  void discardStaged(Uint8List groupId);

  /// Processes and merges another device's commit.
  ProcessedCommit processCommit(Uint8List groupId, Uint8List commit);

  int currentEpoch(Uint8List groupId);

  /// An MLS application message in the call group (the track announcement).
  Uint8List encryptApplication(Uint8List groupId, Uint8List plaintext);

  /// Opens an application message that claims to come from [sender]; throws
  /// when it does not decrypt or its MLS sender is someone else.
  Uint8List decryptApplication(
      Uint8List groupId, Uint8List ciphertext, CallMember sender);

  /// `K(s,t)` of the current epoch for [sender]'s stream slot.
  Uint8List mediaKey(
      Uint8List groupId, String callId, CallMember sender, int stream);

  /// Forgets the group.
  void drop(Uint8List groupId);
}

/// The parent conversation's MLS group: the only source of who may be in a
/// call. A device whose credential and signing key are not a leaf there is
/// never accepted.
abstract interface class ParentGroupView {
  /// Whether this exact device and signing key are a leaf of the parent.
  bool hasMember(String conversationId, CallMember member);

  /// Parent members, to find devices that left it.
  List<CallMember> members(String conversationId);
}

/// The frame cryptor settings B6 requires (fail closed).
class RoomCryptorSettings {
  const RoomCryptorSettings({
    this.discardFrameWhenCryptorNotReady = true,
    this.sharedKey = false,
    this.hkdf = true,
    this.ratchetWindowSize = 0,
    this.useMagicBytes = false,
    this.keyRingSize = 16,
  });

  /// A frame with no key is dropped, never sent or played in clear.
  final bool discardFrameWhenCryptorNotReady;

  /// Per-participant keys, not one shared key.
  final bool sharedKey;
  final bool hkdf;

  /// MLS epochs are the only rekey.
  final int ratchetWindowSize;

  /// No magic bytes, so no frame can skip decryption.
  final bool useMagicBytes;
  final int keyRingSize;

  bool get failClosed =>
      discardFrameWhenCryptorNotReady &&
      !sharedKey &&
      hkdf &&
      ratchetWindowSize == 0 &&
      !useMagicBytes;
}

/// The frame cryptor's key provider. Keys are per participant and stream
/// slot (`<leaf identity>:<slot>`) at a key-ring index.
abstract interface class FrameKeySink {
  RoomCryptorSettings get settings;
  void setKey(String participant, int index, Uint8List key);
  void removeKey(String participant, int index);

  /// This device sends with the key at [index] from now on.
  void useSendKey(int index);

  /// Wipes everything (leaving the call).
  void clear();
}

/// Timers, injectable so tests run without real time.
abstract interface class RoomScheduler {
  DateTime now();
  RoomTimer after(Duration delay, void Function() action);
}

abstract interface class RoomTimer {
  void cancel();
}

/// What the room screen may ask of the media transport (the SFU connection).
/// Null means the build has none, and the screen hides those controls.
abstract interface class RoomMediaControls implements Listenable {
  bool get micMuted;
  Future<void> setMicMuted(bool muted);

  /// Desktop and Android only. iOS can watch a screen share but not send one
  /// (O6).
  bool get canShareScreen;
  bool get sharingScreen;
  Future<void> setSharingScreen(bool on);
}

/// A call group's MLS state, held apart from the messaging device so that it
/// is never sealed, backed up or transferred (D70). [close] forgets it.
abstract interface class CallGroupHandle {
  CallGroupCrypto get crypto;
  void close();
}

/// What a crypto service offers for B6: a call-group handle per call and
/// the parent conversations' current MLS rosters.
abstract interface class RoomCryptoSource {
  /// Opens a call-group handle on a copy of this device's committed MLS
  /// state that is never sealed. Throws when no device is active.
  Future<CallGroupHandle> openCallGroup();

  /// Reads the active device's parent groups at each call, never a cached
  /// handle; an unknown conversation or no active device lists nobody.
  ParentGroupView get parentGroups;
}
