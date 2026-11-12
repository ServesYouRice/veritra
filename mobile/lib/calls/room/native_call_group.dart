import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/native_crypto_bindings.dart';
import '../../crypto/sha256.dart';
import '../../storage/device_list_records.dart';
import 'room_ports.dart';

/// B6 (ABI 22) join signature domain; Rust prepends it to the message.
const b6JoinDomain = 'veritra-b6-join-v1';

List<int> _lp(List<int> value) =>
    [(value.length >> 8) & 0xff, value.length & 0xff, ...value];

List<int> _u64(int value) {
  final out = ByteData(8)..setUint64(0, value);
  return out.buffer.asUint8List();
}

/// The signed message of a join (without the domain):
/// `lp(group_id) | lp(nonce) | u64(expires_at) | sha256(key_package)`.
Uint8List b6JoinMessage({
  required List<int> groupId,
  required List<int> nonce,
  required int expiresAt,
  required List<int> keyPackage,
}) =>
    Uint8List.fromList([
      ..._lp(groupId),
      ..._lp(nonce),
      ..._u64(expiresAt),
      ...sha256(keyPackage),
    ]);

String _groupName(Uint8List groupId) =>
    groupId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

CallMember _member(LeafPair pair) => CallMember(
      utf8.decode(pair.accountId),
      utf8.decode(pair.deviceId),
      pair.signingKey,
    );

/// [CallGroupCrypto] on the native MLS core. The call group is created,
/// joined and dropped through [device], and [drop] deletes it. The core
/// does not keep a call group out of [device]'s seals, so [device] must never
/// be the messaging device: it is a scratch copy of the committed state that
/// is never sealed ([ScratchCallGroupHandle]; D70).
///
/// Known limits, tracked in the design's build status: the call-only
/// KeyPackage lives in the device's provider storage until the next
/// [NativeCryptoDevice.pruneKeyPackages]; a receiver of an Add checks the
/// added device's identity and signing key against the parent group and the
/// signed offer on the server, but only the committer checks the signature
/// against the KeyPackage hash (the core does not yet return it); the
/// call-group context extension binding `call_id` is not enforced.
class NativeCallGroupCrypto implements CallGroupCrypto {
  NativeCallGroupCrypto(this.device, this.bindings);
  final NativeCryptoDevice device;
  final NativeCryptoBindings bindings;

  @override
  void createGroup(Uint8List groupId) =>
      device.createGroup(_groupName(groupId));

  @override
  List<CallMember>? joinWithWelcome(Uint8List groupId, Uint8List welcome) {
    try {
      device.joinGroup(_groupName(groupId), welcome);
    } on NativeCryptoException {
      return null;
    }
    return members(groupId);
  }

  @override
  JoinOffer makeJoinOffer(Uint8List groupId, String nonce, int expiresAt) {
    final keyPackage = Uint8List.fromList(device.createKeyPackage());
    final signature = device.c7Sign(
      domain: b6JoinDomain,
      message: b6JoinMessage(
        groupId: groupId,
        nonce: utf8.encode(nonce),
        expiresAt: expiresAt,
        keyPackage: keyPackage,
      ),
    );
    return JoinOffer(
        keyPackage: keyPackage, signature: signature, expiresAt: expiresAt);
  }

  @override
  bool verifyJoinOffer({
    required Uint8List groupId,
    required CallMember member,
    required String nonce,
    required int expiresAt,
    required Uint8List keyPackage,
    required Uint8List signature,
  }) {
    try {
      return bindings.c7Verify(
        domain: b6JoinDomain,
        publicKey: member.signingKey,
        message: b6JoinMessage(
          groupId: groupId,
          nonce: utf8.encode(nonce),
          expiresAt: expiresAt,
          keyPackage: keyPackage,
        ),
        signature: signature,
      );
    } on NativeCryptoException {
      return false;
    }
  }

  @override
  List<CallMember> members(Uint8List groupId) =>
      device.groupMembers(_groupName(groupId)).map(_member).toList();

  @override
  StagedCommit stageCommit(
    Uint8List groupId, {
    List<({Uint8List keyPackage, CallMember member})> adds = const [],
    List<CallMember> removes = const [],
  }) {
    final name = _groupName(groupId);
    if (adds.isEmpty && removes.isEmpty) {
      final staged = device.stageSelfUpdate(name);
      return StagedCommit(
          commit: Uint8List.fromList(staged.commit), epoch: staged.epoch);
    }
    final staged = device.stageCommitKeyed(
      name,
      adds: [
        for (final add in adds)
          (
            keyPackage: add.keyPackage,
            accountId: utf8.encode(add.member.accountId),
            deviceId: utf8.encode(add.member.deviceId),
            signingKey: add.member.signingKey,
          ),
      ],
      removes: [
        for (final remove in removes)
          (
            accountId: utf8.encode(remove.accountId),
            deviceId: utf8.encode(remove.deviceId),
          ),
      ],
    );
    return StagedCommit(
      commit: Uint8List.fromList(staged.commit),
      welcome:
          staged.welcome.isEmpty ? null : Uint8List.fromList(staged.welcome),
      epoch: staged.epoch,
    );
  }

  @override
  void mergeStaged(Uint8List groupId) =>
      device.mergePendingCommit(_groupName(groupId));

  @override
  void discardStaged(Uint8List groupId) =>
      device.clearPendingCommit(_groupName(groupId));

  @override
  ProcessedCommit processCommit(Uint8List groupId, Uint8List commit) {
    final result = device.processCommitWithPairs(_groupName(groupId), commit);
    if (result.unreadable) {
      throw StateError('call commit could not be read');
    }
    return ProcessedCommit(
      epoch: result.epoch,
      added: result.addedLeaves.map(_member).toList(),
      removedSelf: result.removedSelf,
    );
  }

  @override
  int currentEpoch(Uint8List groupId) =>
      device.groupEpoch(_groupName(groupId)).epoch;

  @override
  Uint8List encryptApplication(Uint8List groupId, Uint8List plaintext) =>
      Uint8List.fromList(device.encrypt(_groupName(groupId), plaintext));

  @override
  Uint8List decryptApplication(
          Uint8List groupId, Uint8List ciphertext, CallMember sender) =>
      Uint8List.fromList(device.decrypt(_groupName(groupId), ciphertext,
          senderAccountId: sender.accountId, senderDeviceId: sender.deviceId));

  @override
  Uint8List mediaKey(
      Uint8List groupId, String callId, CallMember sender, int stream) {
    return device.b6MediaKey(
      groupId: _groupName(groupId),
      callId: callId,
      senderAccountId: sender.accountId,
      senderDeviceId: sender.deviceId,
      stream: stream,
    );
  }

  @override
  void drop(Uint8List groupId) {
    device.deleteGroup(_groupName(groupId));
  }
}

/// [ParentGroupView] on the parent conversation's native MLS group, filtered
/// by this device's L1 verdicts: only a leaf whose stored judgment is
/// `approved`, with the same signing key, counts (an unapproved leaf can
/// carry any account's id).
class NativeParentGroupView implements ParentGroupView {
  /// [judged] returns the stored verdicts of a conversation's leaves, or
  /// null while they are not loaded; [load] loads them.
  NativeParentGroupView(NativeCryptoDevice device,
      {required List<ApprovalLeaf>? Function(String conversationId) judged,
      required Future<List<ApprovalLeaf>?> Function(String conversationId)
          load})
      : this.live(() => device, judged: judged, load: load);

  /// Reads the device [current] returns at each call, so a replaced or
  /// closed handle is never used; null lists nobody (fail closed: no one
  /// can be added).
  NativeParentGroupView.live(NativeCryptoDevice? Function() current,
      {required List<ApprovalLeaf>? Function(String conversationId) judged,
      required Future<List<ApprovalLeaf>?> Function(String conversationId)
          load})
      : _device = current,
        _judged = judged,
        _load = load;
  final NativeCryptoDevice? Function() _device;
  final List<ApprovalLeaf>? Function(String conversationId) _judged;
  final Future<List<ApprovalLeaf>?> Function(String conversationId) _load;

  /// Every leaf of the parent with whether it is approved; empty for an
  /// unknown group or no device, null while the verdicts are not loaded.
  List<(CallMember, bool)>? _leaves(
      String conversationId, List<ApprovalLeaf>? verdicts) {
    final device = _device();
    if (device == null) return const [];
    final List<LeafPair> tree;
    try {
      tree = device.groupMembers(conversationId);
    } catch (_) {
      return const [];
    }
    if (verdicts == null) return null;
    try {
      return [
        for (final leaf in tree)
          (
            _member(leaf),
            verdicts.any((row) =>
                row.verdict == LeafVerdict.approved &&
                row.sameLeaf(leaf.accountId, leaf.deviceId) &&
                _sameBytes(row.signingKey, leaf.signingKey)),
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  List<CallMember>? members(String conversationId) {
    if (_device() == null) return const [];
    final leaves = _leaves(conversationId, _judged(conversationId));
    if (leaves == null) return null;
    return [
      for (final (member, approved) in leaves)
        if (approved) member,
    ];
  }

  @override
  bool hasMember(String conversationId, CallMember member) {
    for (final candidate in members(conversationId) ?? const <CallMember>[]) {
      if (candidate.id == member.id &&
          _sameBytes(candidate.signingKey, member.signingKey)) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<bool> allApproved(String conversationId) async {
    if (_device() == null) return false;
    final List<ApprovalLeaf>? verdicts;
    try {
      verdicts = _judged(conversationId) ?? await _load(conversationId);
    } on Object {
      return false;
    }
    final leaves = _leaves(conversationId, verdicts);
    return leaves != null &&
        leaves.isNotEmpty &&
        leaves.every((leaf) => leaf.$2);
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// A [CallGroupHandle] on a scratch device restored from the committed
/// state: the same identity and signing key as the messaging device, so its
/// leaves match the parent group, but nothing it holds is ever sealed,
/// stored, backed up or transferred. Closing it forgets the call group and
/// the call-only KeyPackage together.
class ScratchCallGroupHandle implements CallGroupHandle {
  ScratchCallGroupHandle(this._device, NativeCryptoBindings bindings)
      : crypto = NativeCallGroupCrypto(_device, bindings);
  final NativeCryptoDevice _device;
  bool _closed = false;

  @override
  final NativeCallGroupCrypto crypto;

  bool get closed => _closed;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _device.close();
  }
}
