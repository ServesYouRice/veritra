import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/native_crypto_bindings.dart';
import '../../crypto/sha256.dart';
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
/// joined and dropped in memory only: callers never seal this device's
/// state for a call group, and [drop] deletes it.
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

/// [ParentGroupView] on the parent conversation's native MLS group.
class NativeParentGroupView implements ParentGroupView {
  NativeParentGroupView(this.device);
  final NativeCryptoDevice device;

  @override
  List<CallMember> members(String conversationId) {
    try {
      return device.groupMembers(conversationId).map(_member).toList();
    } on NativeCryptoException {
      return const [];
    }
  }

  @override
  bool hasMember(String conversationId, CallMember member) {
    for (final candidate in members(conversationId)) {
      if (candidate.id == member.id &&
          _sameBytes(candidate.signingKey, member.signingKey)) {
        return true;
      }
    }
    return false;
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
