part of 'native_crypto_bindings.dart';

// C4 group role record, crypto layer (ABI 20). Nothing here is wired into
// the app: the main session moves group creation, every commit producer and
// the commit receive path onto these calls. Design:
// docs/designs/C4-custom-roles.md; formats and rules: docs/crypto.md, "Group
// role state (C4)".
//
// Rust carries the record as opaque bytes (1 to 256 KiB) in GroupContext
// extension 0xF0C4. Dart encodes it (`encodeGovernance`), decodes it
// (`decodeGovernance`) and judges every change (`validateCommit`) between
// [NativeCryptoDevice.stageIncomingCommit] and
// [NativeCryptoDevice.mergeIncomingCommit] or
// [NativeCryptoDevice.discardIncomingCommit].
//
// Account and device ids come back as BYTES, as in `l1_device_list.dart`: a
// member can commit an Add whose credential holds ids that are not UTF-8.
// [IncomingCommitReview.accountsBefore] and friends decode them strictly and
// answer null when any id is not text, so the caller decides (a record can
// only name UTF-8 accounts).

/// Largest role record (the codec's own ceiling).
const int roleRecordMaxBytes = 256 * 1024;

/// Largest review or role-state buffer the binding accepts: two records plus
/// rosters and pairs.
const int _roleOutputMaxBytes = 4 * 1024 * 1024;

/// What a staged remote commit would do, read from MLS before it is merged
/// (ABI 20). Rust holds the staged commit until
/// [NativeCryptoDevice.mergeIncomingCommit] or
/// [NativeCryptoDevice.discardIncomingCommit].
class IncomingCommitReview {
  const IncomingCommitReview({
    required this.removed,
    required this.added,
    required this.removedSelf,
    required this.recordProposal,
    required this.epoch,
    required this.committer,
    required this.addedLeaves,
    required this.rosterBefore,
    required this.rosterAfter,
    required this.recordBefore,
    required this.recordAfter,
  });

  /// At least one Remove proposal.
  final bool removed;

  /// At least one Add proposal.
  final bool added;

  /// The commit removes this device.
  final bool removedSelf;

  /// The commit carries the role-record proposal ([recordAfter] then
  /// differs from [recordBefore]; Rust refuses a proposal that changes
  /// nothing).
  final bool recordProposal;

  /// The epoch the commit produces.
  final int epoch;

  /// The committer, from the MLS tree (never a server label).
  final LeafPair committer;

  /// The leaves the commit's Add proposals bring in.
  final List<LeafPair> addedLeaves;

  /// The account roster before and after the commit: distinct, sorted by
  /// bytes. An account stays while any of its devices stays.
  final List<Uint8List> rosterBefore;
  final List<Uint8List> rosterAfter;

  /// The record before and after (null in a group without one; equal when
  /// the commit carries no proposal).
  final Uint8List? recordBefore;
  final Uint8List? recordAfter;

  /// The committer's account as text, or null when it is not UTF-8.
  String? get committerAccount => _textOrNull(committer.accountId);

  /// [rosterBefore] as text, or null when any id is not UTF-8.
  Set<String>? get accountsBefore => _textSet(rosterBefore);

  /// [rosterAfter] as text, or null when any id is not UTF-8.
  Set<String>? get accountsAfter => _textSet(rosterAfter);
}

/// A group's current role record (null without one) and account roster.
class GroupRoleState {
  const GroupRoleState({required this.record, required this.roster});

  final Uint8List? record;
  final List<Uint8List> roster;

  /// [roster] as text, or null when any id is not UTF-8.
  Set<String>? get accounts => _textSet(roster);
}

String? _textOrNull(List<int> bytes) {
  try {
    final text = utf8.decode(bytes, allowMalformed: false);
    // A byte-order mark would not round-trip through the codec.
    return text.startsWith('﻿') ? null : text;
  } on FormatException {
    return null;
  }
}

Set<String>? _textSet(List<Uint8List> ids) {
  final out = <String>{};
  for (final id in ids) {
    final text = _textOrNull(id);
    if (text == null) return null;
    out.add(text);
  }
  return out;
}

class _RoleReader {
  _RoleReader(List<int> bytes) : _inner = _SummaryReader(bytes);
  final _SummaryReader _inner;

  int byte() => _inner.byte();
  int u16() => _inner.u16();
  int u64() => _inner.u64();
  int u32() {
    final bytes = _inner.take(4);
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  }

  Uint8List lp() => _inner.lpBytes();

  LeafPair pair() => LeafPair(lp(), lp(), _inner.take(32));

  /// A roster: distinct ids sorted by bytes, each 1 to 128 bytes.
  List<Uint8List> accounts() {
    final count = u16();
    final out = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final id = lp();
      if (id.isEmpty ||
          id.length > 128 ||
          (out.isNotEmpty && _compareBytes(out.last, id) >= 0)) {
        throw const NativeCryptoException(NativeCryptoError.invalidOutput);
      }
      out.add(id);
    }
    return out;
  }

  Uint8List? record(bool present) {
    final length = u32();
    if (present != (length > 0) || length > roleRecordMaxBytes) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    return present ? _inner.take(length) : null;
  }

  bool get finished => _inner.finished;
}

IncomingCommitReview _readReview(List<int> bytes) {
  final reader = _RoleReader(bytes);
  if (reader.byte() != 1) {
    throw const NativeCryptoException(NativeCryptoError.invalidOutput);
  }
  final flags = reader.byte();
  if (flags & ~0x3f != 0) {
    throw const NativeCryptoException(NativeCryptoError.invalidOutput);
  }
  final epoch = reader.u64();
  final committer = reader.pair();
  final addedCount = reader.u16();
  final addedLeaves = <LeafPair>[
    for (var i = 0; i < addedCount; i++) reader.pair(),
  ];
  final before = reader.accounts();
  final after = reader.accounts();
  final recordBefore = reader.record(flags & 16 != 0);
  final recordAfter = reader.record(flags & 32 != 0);
  if (!reader.finished || (flags & 2 != 0) != addedLeaves.isNotEmpty) {
    throw const NativeCryptoException(NativeCryptoError.invalidOutput);
  }
  return IncomingCommitReview(
    removed: flags & 1 != 0,
    added: flags & 2 != 0,
    removedSelf: flags & 4 != 0,
    recordProposal: flags & 8 != 0,
    epoch: epoch,
    committer: committer,
    addedLeaves: addedLeaves,
    rosterBefore: before,
    rosterAfter: after,
    recordBefore: recordBefore,
    recordAfter: recordAfter,
  );
}

GroupRoleState _readRoleState(List<int> bytes) {
  final reader = _RoleReader(bytes);
  if (reader.byte() != 1) {
    throw const NativeCryptoException(NativeCryptoError.invalidOutput);
  }
  final flags = reader.byte();
  if (flags > 1) {
    throw const NativeCryptoException(NativeCryptoError.invalidOutput);
  }
  final roster = reader.accounts();
  final record = reader.record(flags == 1);
  if (!reader.finished) {
    throw const NativeCryptoException(NativeCryptoError.invalidOutput);
  }
  return GroupRoleState(record: record, roster: roster);
}

// The bodies of the NativeCryptoDevice members of the same names (as L1's
// `_groupMembersImpl`): members, not extension methods, so a test can wrap a
// device and still forward these calls.
extension _RoleStateDevice on NativeCryptoDevice {
  /// Creates a record group (ABI 20, C4 item 2): its context requires the
  /// role extension and carries [genesisRecord], which the app builds as
  /// `encodeGovernance(GovernanceState.genesis(creator))`. [createGroup]
  /// stays for a group without a record (a private channel's group).
  void _createGroupWithRolesImpl(String groupId, List<int> genesisRecord) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(genesisRecord, roleRecordMaxBytes);
    _withTwo(
        groupId.codeUnits,
        genesisRecord,
        (group, record) =>
            _bindings._groupCreateWithRoles(_liveHandle, group, record));
  }

  /// [stageCommitKeyed] that also carries the group's new role [record]
  /// (ABI 20, C4 item 3). [adds] and [removes] may both be empty: the
  /// commit is then the role change alone. Rust refuses (operationFailed,
  /// nothing staged) a record equal to the current one, a group without a
  /// record, or anything receivers would refuse. Merge or clear it as usual.
  ({List<int> commit, List<int> welcome, int epoch}) _stageCommitWithRolesImpl(
    String groupId, {
    required List<int> record,
    List<
            ({
              List<int> keyPackage,
              List<int> accountId,
              List<int> deviceId,
              List<int> signingKey
            })>
        adds = const [],
    List<({List<int> accountId, List<int> deviceId})> removes = const [],
  }) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(record, roleRecordMaxBytes);
    final changes = encodeKeyedMembershipChanges(
        adds: adds, removes: removes, allowEmpty: true);
    return _bindings._withByteLists([groupId.codeUnits, changes, record],
        (slices) {
      final commit = calloc<_PmOwnedBuffer>();
      final welcome = calloc<_PmOwnedBuffer>();
      final epoch = calloc<Uint64>();
      try {
        _bindings._check(_bindings._groupStageWithRoles(_liveHandle, slices[0],
            slices[1], slices[2], commit, welcome, epoch));
        final commitBytes = _bindings._take(commit.ref);
        commit.ref
          ..data = nullptr
          ..len = 0;
        final List<int> welcomeBytes;
        if (welcome.ref.data == nullptr) {
          welcomeBytes = const <int>[];
        } else {
          welcomeBytes = _bindings._take(welcome.ref);
          welcome.ref
            ..data = nullptr
            ..len = 0;
        }
        if (adds.isEmpty != welcomeBytes.isEmpty) {
          throw const NativeCryptoException(NativeCryptoError.invalidOutput);
        }
        return (commit: commitBytes, welcome: welcomeBytes, epoch: epoch.value);
      } finally {
        if (commit.ref.data != nullptr) _bindings._free(commit.ref);
        if (welcome.ref.data != nullptr) _bindings._free(welcome.ref);
        calloc.free(commit);
        calloc.free(welcome);
        calloc.free(epoch);
      }
    });
  }

  /// Phase one of receiving a commit (ABI 20, C4 item 4): Rust stages
  /// [commit], checks it, holds it unmerged and returns what it would do.
  /// The caller judges the review (`validateCommit`), then calls
  /// [mergeIncomingCommit] with the same bytes or [discardIncomingCommit].
  ///
  /// Staging uses up the commit's handshake ratchet step: after a discard
  /// (or any failure here) restore the committed state; never seal it. A
  /// review this binding cannot read is discarded before it throws.
  IncomingCommitReview _stageIncomingCommitImpl(
      String groupId, List<int> commit) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(commit, 4 * 1024 * 1024);
    final bytes = _bindings._withByteLists(
        <List<int>>[groupId.codeUnits, commit],
        (slices) => _bindings._output(
            (out) => _bindings._groupStageIncoming(
                _liveHandle, slices[0], slices[1], out),
            maximum: _roleOutputMaxBytes));
    try {
      return _readReview(bytes);
    } on Object {
      _discardIncomingCommitImpl(groupId);
      rethrow;
    }
  }

  /// Phase two (ABI 20): merges the commit held for [groupId]. [commit] must
  /// be the bytes [stageIncomingCommit] reviewed, and the group must not
  /// have moved since; otherwise operationFailed with nothing changed and
  /// the commit still held. Returns what the one-shot L1 call returns
  /// (flags, epoch, the C7 root of a removal that keeps this device, added
  /// and committer pairs). Once this returns the commit is merged: as with
  /// [processCommitWithPairs], nothing here throws after that.
  CommitPairs _mergeIncomingCommitImpl(String groupId, List<int> commit) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(commit, 4 * 1024 * 1024);
    return _bindings._withByteLists(
        <List<int>>[groupId.codeUnits, commit],
        (slices) => _commitPairs((flags, epoch, root, added, committer) =>
            _bindings._groupMergeIncoming(_liveHandle, slices[0], slices[1],
                flags, epoch, root, added, committer)));
  }

  /// Drops the commit held for [groupId] (the caller refused it). The group
  /// is untouched. Returns whether one was held.
  bool _discardIncomingCommitImpl(String groupId) {
    _bindings._bounded(groupId.codeUnits, 128);
    return _bindings._withSlice(Uint8List.fromList(groupId.codeUnits), (group) {
      final held = calloc<Uint8>();
      try {
        _bindings
            ._check(_bindings._groupDiscardIncoming(_liveHandle, group, held));
        return held.value == 1;
      } finally {
        calloc.free(held);
      }
    });
  }

  /// The group's current role record and account roster (ABI 20, C4 item
  /// 5), for after a join or a restore.
  GroupRoleState _groupRoleStateImpl(String groupId) {
    _bindings._bounded(groupId.codeUnits, 128);
    final bytes = _bindings._withSlice(
        Uint8List.fromList(groupId.codeUnits),
        (group) => _bindings._output(
            (out) => _bindings._groupRoleState(_liveHandle, group, out),
            maximum: _roleOutputMaxBytes));
    return _readRoleState(bytes);
  }
}

/// C4 wiring: the two-phase merge reports what the one-shot C7 call did, so
/// C7's group state follows a commit received either way. [root] is shared,
/// not copied: wiping one wipes both.
extension CommitPairsC7Outcome on CommitPairs {
  C7CommitOutcome get c7Outcome => C7CommitOutcome._(
        removedAny: removed,
        addedAny: added,
        removedSelf: removedSelf,
        newEpoch: epoch,
        root: root,
      );
}
