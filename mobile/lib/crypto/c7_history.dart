// C7 history logic that needs no native call and no storage: the record
// codecs, the ordering table, the window check and the sender-key rule.
// Design: docs/designs/C7-channel-history.md revision 7. Vectors:
// testing/vectors/c7-primitives-v1.json and c7-ordering-v1.json.
//
// Nothing here is wired into send, receive or the database yet. The caller
// (a later step) feeds it records that already passed the checks the table
// presupposes (encoding, signature, key commitment, freshness, authority) and
// stores the result in the same local transaction as the MLS state.
import 'dart:convert';
import 'dart:typed_data';

import 'sha256.dart';

const int c7RecordBytes = 512;
const int c7CompactBytes = 143;
const int c7MoveWrapBytes = 128;
const int c7SeqLimit = 0xffffffff;

/// A valid record's `seq` is at most this, and at most [c7MaxSeqJump] above
/// the highest valid `seq` seen, so a valid record can never use up the room
/// a recovering switch needs above it. A record that breaks either bound is
/// invalid before the table (design decision 4, "Sequence cap").
const int c7SeqCeiling = 0x80000000;
const int c7MaxSeqJump = 1024;

/// Whether [seq] respects the cap given the highest valid `seq` seen (-1:
/// none).
bool c7SeqWithinCap(int seq, int highestSeq) =>
    seq <= c7SeqCeiling && (highestSeq < 0 || seq <= highestSeq + c7MaxSeqJump);
const int c7ModeMembersFromJoin = 0;
const int c7ModeFull = 1;
const int c7ReasonCreate = 0;
const int c7ReasonSwitch = 1;
const int c7ReasonMove = 2;

const List<int> _zeroHash = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// `sha256("veritra-c7-chk-v1" | key)`, in plain Dart for places with no
/// native handle. The native `c7ChkCommit` is the same value.
Uint8List c7ChkCommitOf(List<int> key) =>
    sha256(<int>[...utf8.encode('veritra-c7-chk-v1'), ...key]);

class _Reader {
  _Reader(this._bytes);
  final Uint8List _bytes;
  int _at = 0;

  int get remaining => _bytes.length - _at;

  Uint8List take(int count) {
    if (count < 0 || count > remaining) {
      throw const FormatException('truncated C7 record');
    }
    final out = Uint8List.sublistView(_bytes, _at, _at + count);
    _at += count;
    return out;
  }

  int u8() => take(1)[0];
  int u32() => ByteData.sublistView(take(4)).getUint32(0, Endian.big);
  int u64() {
    final data = ByteData.sublistView(take(8));
    final high = data.getUint32(0, Endian.big);
    // Epochs stay far below 2^53; refuse anything Dart cannot hold exactly.
    if (high > 0x1fffff) throw const FormatException('C7 epoch too large');
    return high * 0x100000000 + data.getUint32(4, Endian.big);
  }

  /// `lp(x)`: u16 big-endian length, then the bytes; ids are 1 to 64 bytes.
  Uint8List lpId() {
    final data = ByteData.sublistView(take(2));
    final length = data.getUint16(0, Endian.big);
    if (length == 0 || length > 64) {
      throw const FormatException('invalid C7 id length');
    }
    return take(length);
  }

  void zeroRest() {
    if (_bytes.sublist(_at).any((value) => value != 0)) {
      throw const FormatException('C7 record padding is not zero');
    }
    _at = _bytes.length;
  }
}

void _putU32(BytesBuilder out, int value) => out.add(<int>[
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ]);

void _putU64(BytesBuilder out, int value) {
  _putU32(out, value ~/ 0x100000000);
  _putU32(out, value & 0xffffffff);
}

void _putLp(BytesBuilder out, List<int> id) {
  if (id.isEmpty || id.length > 64) {
    throw const FormatException('invalid C7 id length');
  }
  out.add(<int>[id.length >> 8, id.length & 0xff]);
  out.add(id);
}

/// A history record in full form (decision 3). Structure only: ordering,
/// freshness and authority are the table's and the caller's.
final class C7Record {
  C7Record({
    required this.communityId,
    required this.channelId,
    required this.seq,
    required List<int> prev,
    required this.mode,
    required this.reason,
    required this.groupId,
    required this.epoch,
    required this.closeGroupId,
    required this.closeEpoch,
    required List<int> chkCommit,
    required this.actorDeviceId,
    required List<int> sig,
  })  : prev = Uint8List.fromList(prev),
        chkCommit = Uint8List.fromList(chkCommit),
        sig = Uint8List.fromList(sig) {
    if (seq < 0 ||
        seq >= c7SeqLimit ||
        mode > c7ModeFull ||
        reason > c7ReasonMove ||
        this.prev.length != 32 ||
        this.chkCommit.length != 32 ||
        this.sig.length != 64) {
      throw const FormatException('invalid C7 record');
    }
  }

  final Uint8List communityId;
  final Uint8List channelId;
  final int seq;
  final Uint8List prev;
  final int mode;
  final int reason;
  final Uint8List groupId;
  final int epoch;
  final Uint8List closeGroupId;
  final int closeEpoch;
  final Uint8List chkCommit;
  final Uint8List actorDeviceId;
  final Uint8List sig;

  /// Whether the record opens a key (mode `full`).
  bool get opensKey => mode == c7ModeFull;

  /// The bytes after `veritra-c7-history-v1` that `sig` covers.
  Uint8List signedFields() {
    final out = BytesBuilder(copy: false);
    _putLp(out, communityId);
    _putLp(out, channelId);
    _putU32(out, seq);
    out.add(prev);
    out.addByte(mode);
    out.addByte(reason);
    _putLp(out, groupId);
    _putU64(out, epoch);
    _putLp(out, closeGroupId);
    _putU64(out, closeEpoch);
    out.add(chkCommit);
    _putLp(out, actorDeviceId);
    return out.takeBytes();
  }

  /// Full form, zero-padded to 512 bytes (at most 481 used).
  Uint8List encode() {
    final out = BytesBuilder(copy: false)
      ..addByte(1)
      ..add(signedFields())
      ..add(sig);
    final bytes = out.takeBytes();
    if (bytes.length > c7RecordBytes) {
      throw const FormatException('C7 record too long');
    }
    return Uint8List(c7RecordBytes)..setRange(0, bytes.length, bytes);
  }

  /// `sha256` of the 512-byte form: the next record's `prev`.
  Uint8List hash() => sha256(encode());

  static C7Record decode(List<int> bytes) {
    if (bytes.length != c7RecordBytes) {
      throw const FormatException('C7 record must be 512 bytes');
    }
    final reader = _Reader(Uint8List.fromList(bytes));
    if (reader.u8() != 1) throw const FormatException('C7 record version');
    final record = C7Record(
      communityId: reader.lpId(),
      channelId: reader.lpId(),
      seq: reader.u32(),
      prev: reader.take(32),
      mode: reader.u8(),
      reason: reader.u8(),
      groupId: reader.lpId(),
      epoch: reader.u64(),
      closeGroupId: reader.lpId(),
      closeEpoch: reader.u64(),
      chkCommit: reader.take(32),
      actorDeviceId: reader.lpId(),
      sig: reader.take(64),
    );
    reader.zeroRest();
    return record;
  }
}

/// What the receiver supplies when it rebuilds the full form from a compact
/// proposal: the payload context and the MLS message's own facts.
final class C7RecordContext {
  const C7RecordContext({
    required this.communityId,
    required this.channelId,
    required this.groupId,
    required this.epoch,
    required this.actorDeviceId,
  });

  final List<int> communityId;
  final List<int> channelId;
  final List<int> groupId;
  final int epoch;
  final List<int> actorDeviceId;
}

/// A record as it travels in its channel message (143 bytes; a move adds
/// `lp(close_group_id)` and a 128-byte wrap).
final class C7CompactRecord {
  C7CompactRecord._({
    required this.seq,
    required this.prev,
    required this.mode,
    required this.reason,
    required this.closeEpoch,
    required this.key,
    required this.sig,
    required this.closeGroupId,
    required this.wrap,
  });

  final int seq;
  final Uint8List prev;
  final int mode;
  final int reason;
  final int closeEpoch;

  /// The new `CHK` when the record opens a key, else 32 random bytes.
  final Uint8List key;
  final Uint8List sig;
  final Uint8List? closeGroupId;
  final Uint8List? wrap;

  static C7CompactRecord decode(List<int> bytes) {
    final reader = _Reader(Uint8List.fromList(bytes));
    if (reader.u8() != 1) throw const FormatException('C7 record version');
    final seq = reader.u32();
    final prev = reader.take(32);
    final mode = reader.u8();
    final reason = reader.u8();
    final closeEpoch = reader.u64();
    final key = reader.take(32);
    final sig = reader.take(64);
    Uint8List? closeGroupId;
    Uint8List? wrap;
    if (reason == c7ReasonMove) {
      closeGroupId = reader.lpId();
      wrap = reader.take(c7MoveWrapBytes);
    }
    if (reader.remaining != 0 ||
        seq >= c7SeqLimit ||
        mode > c7ModeFull ||
        reason > c7ReasonMove) {
      throw const FormatException('invalid compact C7 record');
    }
    return C7CompactRecord._(
      seq: seq,
      prev: prev,
      mode: mode,
      reason: reason,
      closeEpoch: closeEpoch,
      key: key,
      sig: sig,
      closeGroupId: closeGroupId,
      wrap: wrap,
    );
  }

  /// Rebuilds the full form; the signature is checked by the caller against
  /// the actor's key in the current tree.
  C7Record expand(C7RecordContext context) => C7Record(
        communityId: Uint8List.fromList(context.communityId),
        channelId: Uint8List.fromList(context.channelId),
        seq: seq,
        prev: prev,
        mode: mode,
        reason: reason,
        groupId: Uint8List.fromList(context.groupId),
        epoch: context.epoch,
        closeGroupId: closeGroupId ?? Uint8List.fromList(context.groupId),
        closeEpoch: closeEpoch,
        chkCommit: mode == c7ModeFull ? c7ChkCommitOf(key) : _zeroHash,
        actorDeviceId: Uint8List.fromList(context.actorDeviceId),
        sig: sig,
      );
}

// ---- the ordering table (decision 4) ---------------------------------------

enum C7Status { ok, keyless, unsure, closed }

/// Where a valid record came from. A proposal is the compact record in the
/// channel message that carries it (live, or fetched from history); a report
/// is a slot's repeated head.
enum C7Source { proposalLive, proposalHistory, report }

/// What the table needs of a valid record. [hash] is the hash of the full
/// 512-byte form (`C7Record.hash()`); the table never looks inside it.
final class C7Entry {
  C7Entry({
    required this.seq,
    required List<int> hash,
    required List<int> prev,
    required this.mode,
    required this.reason,
    required this.epoch,
  })  : hash = Uint8List.fromList(hash),
        prev = Uint8List.fromList(prev);

  factory C7Entry.of(C7Record record) => C7Entry(
        seq: record.seq,
        hash: record.hash(),
        prev: record.prev,
        mode: record.mode,
        reason: record.reason,
        epoch: record.epoch,
      );

  final int seq;
  final Uint8List hash;
  final Uint8List prev;
  final int mode;
  final int reason;
  final int epoch;

  bool get opensKey => mode == c7ModeFull;

  /// The chain's own shape (decision 3): `create` is seq 0 with zero `prev`
  /// and only `create` is seq 0. A record that breaks it is invalid before
  /// the table, so it cannot raise the highest `seq`.
  bool get shapeValid {
    final zeroPrev = prev.every((value) => value == 0);
    if (reason == c7ReasonCreate) return seq == 0 && zeroPrev;
    return seq != 0 && seq < c7SeqLimit;
  }

  bool get isSwitchOrMove => reason == c7ReasonSwitch || reason == c7ReasonMove;
}

/// Which row of the table decided; [invalid] is a record that failed a
/// validity check before the table (it leaves an `action` row and changes
/// nothing).
enum C7Row {
  invalid(0),
  adopt(1),
  noop(2),
  apply(3),
  lostRace(4),
  recover(5),
  older(6),
  closed(7);

  const C7Row(this.number);
  final int number;
}

/// One channel's chain state: head, the current period's records, the
/// highest valid `seq`, and the status (decision 4). Immutable; every step
/// returns the next state.
final class C7ChannelState {
  const C7ChannelState._({
    required this.head,
    required this.kept,
    required this.highestSeq,
    required this.status,
    required this.missEpoch,
  });

  /// The implicit genesis: no record held means `members_from_join` with no
  /// head, so nothing is sealed under a history key.
  const C7ChannelState.implicitGenesis()
      : head = null,
        kept = const <int, C7Entry>{},
        highestSeq = -1,
        status = C7Status.ok,
        missEpoch = 0;

  final C7Entry? head;

  /// The records applied in the current period, by `seq`.
  final Map<int, C7Entry> kept;

  /// The highest `seq` of any valid record seen (-1: none).
  final int highestSeq;
  final C7Status status;

  /// The highest epoch of any message this device could not fully apply in
  /// this channel's group (0: none). `unsure` and `keyless` channels return
  /// to `ok` only through a record or slot above it.
  final int missEpoch;

  int get mode => head?.mode ?? c7ModeMembersFromJoin;

  /// "The first seq this device holds" (row 6): the lowest kept `seq`.
  int? get firstSeq => kept.isEmpty ? head?.seq : kept.keys.reduce(_min);

  /// Whether a post sent now is sealed under the channel's history key:
  /// `full` with status `ok` (otherwise a random key, I4).
  bool get sealsUnderHistoryKey => mode == c7ModeFull && status == C7Status.ok;

  /// Whether a `history_sync` hands this channel's key over.
  bool get handsOverKey => sealsUnderHistoryKey;

  C7ChannelState _copy({
    C7Entry? head,
    Map<int, C7Entry>? kept,
    int? highestSeq,
    C7Status? status,
    int? missEpoch,
  }) =>
      C7ChannelState._(
        head: head ?? this.head,
        kept: kept ?? this.kept,
        highestSeq: highestSeq ?? this.highestSeq,
        status: status ?? this.status,
        missEpoch: missEpoch ?? this.missEpoch,
      );

  /// A valid record meets the table. [keyGiven] says the message that
  /// carries it also gives its key (a live proposal, or a slot whose key
  /// matches the record's `chk_commit`). Rows apply in order; the first
  /// match decides.
  ///
  /// Interpretation of the design text, to confirm at the crypto review: a
  /// `closed` channel recovers only through a live switch or move above the
  /// highest valid `seq` (row 5, or row 3 when it also chains from the head);
  /// rows 2, 4 and 6 and a plain row 3 never lift `closed`.
  ({C7ChannelState state, C7Row row}) apply(
    C7Entry x, {
    required C7Source source,
    required bool keyGiven,
  }) {
    if (!x.shapeValid || !c7SeqWithinCap(x.seq, highestSeq)) {
      return (state: this, row: C7Row.invalid);
    }
    final highest = x.seq > highestSeq ? x.seq : highestSeq;
    final h = head;
    // A record above the miss epoch clears `unsure`; one at or below it
    // leaves the channel `unsure` (I3).
    C7Status cleared(C7Entry record) =>
        record.epoch > missEpoch ? C7Status.ok : C7Status.unsure;
    C7ChannelState next(
      C7Entry newHead, {
      required C7Status status,
      Map<int, C7Entry>? kept,
    }) =>
        _copy(
          head: newHead,
          kept: kept ?? <int, C7Entry>{...this.kept, newHead.seq: newHead},
          highestSeq: highest,
          status: status,
        );

    // Row 1: no head (newcomer, or implicit genesis).
    if (h == null) {
      final status = x.opensKey && !keyGiven ? C7Status.keyless : C7Status.ok;
      return (
        state: next(x, status: status, kept: <int, C7Entry>{x.seq: x}),
        row: C7Row.adopt,
      );
    }
    final applied = kept[x.seq] ?? (h.seq == x.seq ? h : null);
    // Row 2: the record this device already applied at that seq.
    if (applied != null && _sameBytes(applied.hash, x.hash)) {
      return (state: _copy(highestSeq: highest), row: C7Row.noop);
    }
    // Row 3: the next record in the chain.
    if (x.seq == h.seq + 1 && _sameBytes(x.prev, h.hash)) {
      final liveSetting = source == C7Source.proposalLive &&
          x.isSwitchOrMove &&
          x.seq > highestSeq;
      if (status == C7Status.closed) {
        // A live switch above everything seen that also chains from this
        // device's head is the ordinary recovery (every honest admin chains
        // from the head they hold): it recovers like row 5.
        if (liveSetting) {
          return (
            state: _copy(
              head: x,
              kept: <int, C7Entry>{x.seq: x},
              highestSeq: highest,
              status: cleared(x),
            ),
            row: C7Row.apply,
          );
        }
        return (state: next(x, status: C7Status.closed), row: C7Row.apply);
      }
      final C7Status status_;
      if (x.opensKey && !keyGiven) {
        status_ = C7Status.keyless;
      } else if (status == C7Status.keyless && !x.opensKey) {
        status_ = C7Status.keyless;
      } else if (status == C7Status.unsure) {
        status_ = cleared(x);
      } else {
        status_ = C7Status.ok;
      }
      return (state: next(x, status: status_), row: C7Row.apply);
    }
    // Row 4: a proposal that lost the race for a seq already applied.
    if (source != C7Source.report &&
        x.seq <= h.seq &&
        applied != null &&
        _sameBytes(x.prev, applied.prev)) {
      return (state: _copy(highestSeq: highest), row: C7Row.lostRace);
    }
    // Row 5: a live switch or move above everything valid seen states the
    // whole setting: recovery, and a new period.
    if (source == C7Source.proposalLive &&
        x.isSwitchOrMove &&
        x.seq > highestSeq) {
      return (
        state: _copy(
          head: x,
          kept: <int, C7Entry>{x.seq: x},
          highestSeq: highest,
          status: cleared(x),
        ),
        row: C7Row.recover,
      );
    }
    // Row 6: older than anything this device holds.
    final first = firstSeq;
    if (first != null && x.seq < first) {
      return (state: _copy(highestSeq: highest), row: C7Row.older);
    }
    // Row 7: a fork or a missed record.
    return (
      state: _copy(highestSeq: highest, status: C7Status.closed),
      row: C7Row.closed,
    );
  }

  /// The device met a message it could not fully apply in this channel's
  /// group, or a live post with a `gen` it does not hold (decision 5,
  /// "Unsure"). Every `full` channel remembers the miss epoch; an `ok` one
  /// becomes `unsure`. `keyless` and `closed` channels already seal random
  /// keys, but keep the epoch so no later record or slot at or below it can
  /// turn sealing back on.
  C7ChannelState markUnsure(int messageEpoch) {
    if (mode != c7ModeFull) return this;
    final epoch = messageEpoch > missEpoch ? messageEpoch : missEpoch;
    return _copy(
      status: status == C7Status.ok ? C7Status.unsure : status,
      missEpoch: epoch,
    );
  }

  /// A later valid slot (a `history_sync` for [forEpoch]) gave a key that
  /// matches the head's commitment. Only a slot above the miss epoch makes
  /// the channel `ok`; a stale one leaves it `unsure`.
  C7ChannelState keyArrived(int forEpoch) => status == C7Status.keyless
      ? _copy(status: forEpoch > missEpoch ? C7Status.ok : C7Status.unsure)
      : this;
}

int _min(int a, int b) => a < b ? a : b;

// ---- windows (decision 6) --------------------------------------------------

/// A generation of the current period as a newcomer reconstructs it.
final class C7Generation {
  const C7Generation({
    required this.epoch,
    required this.groupId,
    required this.closeEpoch,
  });

  /// `E_g`, the opening epoch (and the signed `gen`).
  final int epoch;
  final String groupId;

  /// `E_close`: the next generation's opening epoch or the closing record's
  /// `close_epoch`; null while the generation is open-ended.
  final int? closeEpoch;
}

/// What a newcomer checks after a body opened under a generation's key.
/// Anything else drops the body (I3: gaps are acceptable, leaks are not).
bool c7WindowAccepts({
  required C7Generation generation,
  required bool inCurrentPeriod,
  required int signedGen,
  required String signedGroupId,
  required int signedEpoch,
  required int routeEpoch,
}) {
  if (!inCurrentPeriod) return false;
  if (signedGen != generation.epoch) return false;
  if (signedGroupId != generation.groupId) return false;
  if (signedEpoch != routeEpoch) return false;
  if (signedEpoch < generation.epoch) return false;
  final close = generation.closeEpoch;
  // Bodies in the closing epoch are dropped.
  if (close != null && signedEpoch >= close) return false;
  return true;
}

// ---- sender keys (decision 8, owner decision D85) --------------------------

/// Which key checks a newcomer's post and how it is shown.
final class C7SenderKey {
  const C7SenderKey(this.key, {required this.fromFormerMember});
  final Uint8List key;
  final bool fromFormerMember;
}

/// A sender in the current tree is checked against the tree's key. A sender
/// no longer in the group is checked against the server's device list and the
/// post is marked "from a former member" (D85, until L1). With neither key
/// the post drops: a deleted account's keys are gone.
C7SenderKey? c7SenderKey({Uint8List? treeKey, Uint8List? serverKey}) {
  if (treeKey != null) return C7SenderKey(treeKey, fromFormerMember: false);
  if (serverKey != null) return C7SenderKey(serverKey, fromFormerMember: true);
  return null;
}

// ---- the record message's size (decision 3) --------------------------------

/// The inner JSON of a compact `history_change` message exactly as Dart's
/// `jsonEncode` writes it, with `r` the base64 of the compact record.
Uint8List c7HistoryChangeInnerJson({
  required String conversationId,
  required String senderDeviceId,
  required String actionId,
  required String channelId,
  required List<int> compactRecord,
}) =>
    Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
      'v': 2,
      'type': 'history_change',
      'conversation_id': conversationId,
      'sender_device_id': senderDeviceId,
      'action_id': actionId,
      'channel_id': channelId,
      'hidden': true,
      'body': <String, Object?>{'r': base64Encode(compactRecord)},
    })));
