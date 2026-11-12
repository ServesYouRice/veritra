// C7 per-channel state as a device keeps it (docs/designs/C7-channel-history.md
// decisions 2 to 5): the chain (head, the current period's records, the
// highest valid `seq`, the status), the current period's generations and
// their keys, and this device's own pending proposal.
//
// One sealed setting per channel and group (`c7ChannelSetting`), written only
// inside the MLS transition of the message that changes it (decision 5, "One
// local transaction"). Sealed settings are never copied into K1 backups, K2
// bundles or history snapshots (`mobile/test/c7_full_state_test.dart`).
import 'dart:convert';
import 'dart:typed_data';

import 'c7_history.dart';

/// At most this many records of the current period are kept per channel; an
/// older record then meets row 6 (ignored, no key taken), never row 7.
const int c7KeptRecordLimit = 64;

/// At most this many generation epochs of earlier periods are remembered
/// (no keys): a live post signed for one of them is from a sender still in
/// an older period, which is not an `unsure` trigger (decision 5).
const int c7PastGenerationLimit = 64;

/// `u64 E_cur | key_commit[32] | u64 E_prev | CHK_prev[32]`, zero-padded.
const int c7EntryBytes = 128;

/// A sealed `history_sync` slot: commitment, nonce, 640-byte plaintext, tag.
const int c7SlotBytes = 700;

/// `head record (512) | generation entry (128)`.
const int c7SlotPlainBytes = c7RecordBytes + c7EntryBytes;

Uint8List _b64(Object? value) => base64Decode(value! as String);

bool c7SameBytes(List<int>? a, List<int>? b) {
  if (a == null || b == null) return a == null && b == null;
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

void _putU64(BytesBuilder out, int value) {
  final data = ByteData(8)
    ..setUint32(0, value ~/ 0x100000000, Endian.big)
    ..setUint32(4, value % 0x100000000, Endian.big);
  out.add(data.buffer.asUint8List());
}

int _readU64(Uint8List bytes, int at) {
  final data = ByteData.sublistView(bytes, at, at + 8);
  final high = data.getUint32(0, Endian.big);
  if (high > 0x1fffff) throw const FormatException('C7 epoch too large');
  return high * 0x100000000 + data.getUint32(4, Endian.big);
}

/// A generation entry (decision 5, "Generation entry and backward walk").
final class C7GenerationEntry {
  C7GenerationEntry({
    required this.epoch,
    required List<int> keyCommit,
    this.previousEpoch,
    List<int>? previousKey,
  })  : keyCommit = Uint8List.fromList(keyCommit),
        previousKey =
            previousKey == null ? null : Uint8List.fromList(previousKey) {
    if (this.keyCommit.length != 32 ||
        (previousKey == null) != (previousEpoch == null) ||
        (this.previousKey != null &&
            (this.previousKey!.length != 32 ||
                this.previousKey!.every((b) => b == 0)))) {
      throw const FormatException('invalid C7 generation entry');
    }
  }

  /// `E_cur`, the opening epoch of the generation current at `for_epoch`.
  final int epoch;
  final Uint8List keyCommit;

  /// The previous generation in the same group (`E_prev`, `CHK_prev`), which
  /// closes at [epoch]; null at the period's first generation and when the
  /// previous generation lives in another group.
  final int? previousEpoch;
  final Uint8List? previousKey;

  Uint8List encode() {
    final out = BytesBuilder(copy: false);
    _putU64(out, epoch);
    out.add(keyCommit);
    if (previousKey != null) {
      _putU64(out, previousEpoch!);
      out.add(previousKey!);
    }
    final bytes = out.takeBytes();
    return Uint8List(c7EntryBytes)..setRange(0, bytes.length, bytes);
  }

  /// Null for the zero entry (a slot with no key). A zero key with a
  /// non-zero epoch, or non-zero padding, is malformed (as in Rust).
  static C7GenerationEntry? decode(List<int> raw) {
    if (raw.length != c7EntryBytes) {
      throw const FormatException('C7 entry must be 128 bytes');
    }
    final bytes = Uint8List.fromList(raw);
    if (bytes.every((b) => b == 0)) return null;
    if (bytes.sublist(80).any((b) => b != 0)) {
      throw const FormatException('C7 entry padding is not zero');
    }
    final epoch = _readU64(bytes, 0);
    final commit = bytes.sublist(8, 40);
    final previousEpoch = _readU64(bytes, 40);
    final previousKey = bytes.sublist(48, 80);
    if (previousKey.every((b) => b == 0)) {
      if (previousEpoch != 0) {
        throw const FormatException('C7 entry wrap epoch without key');
      }
      return C7GenerationEntry(epoch: epoch, keyCommit: commit);
    }
    return C7GenerationEntry(
      epoch: epoch,
      keyCommit: commit,
      previousEpoch: previousEpoch,
      previousKey: previousKey,
    );
  }
}

/// One generation of the current period (decision 2): named by its group and
/// opening epoch; [key] is null while the device is `keyless` for it.
final class C7Gen {
  C7Gen({
    required this.epoch,
    required this.groupId,
    List<int>? key,
    this.close,
  }) : key = key == null ? null : Uint8List.fromList(key);

  final int epoch;
  final String groupId;
  final Uint8List? key;

  /// `E_close`: the next generation's opening epoch or the closing record's
  /// `close_epoch`; null while open-ended.
  final int? close;

  bool covers(String group, int at) =>
      groupId == group && epoch <= at && (close == null || at < close!);

  C7Gen closedAt(int at) =>
      C7Gen(epoch: epoch, groupId: groupId, key: key, close: at);

  C7Gen withKey(List<int> value) =>
      C7Gen(epoch: epoch, groupId: groupId, key: value, close: close);

  List<Object?> toJson() => <Object?>[
        epoch,
        groupId,
        key == null ? null : base64Encode(key!),
        close,
      ];

  static C7Gen fromJson(Object? raw) {
    final list = raw! as List;
    return C7Gen(
      epoch: list[0] as int,
      groupId: list[1] as String,
      key: list[2] == null ? null : _b64(list[2]),
      close: list[3] as int?,
    );
  }
}

/// This device's own proposal that has not come back in sync order yet
/// (decision 4, "Own proposals"): at most one per channel. [record] is its
/// full form and [key] the key its compact form carried; both are applied
/// when the message comes back.
final class C7Pending {
  C7Pending({
    required this.actionId,
    required this.sentAtMs,
    required List<int> record,
    required List<int> key,
  })  : record = Uint8List.fromList(record),
        key = Uint8List.fromList(key);

  final String actionId;
  final int sentAtMs;
  final Uint8List record;
  final Uint8List key;

  C7Record get full => C7Record.decode(record);

  Map<String, Object?> toJson() => <String, Object?>{
        'action': actionId,
        'at': sentAtMs,
        'record': base64Encode(record),
        'key': base64Encode(key),
      };

  static C7Pending fromJson(Object? raw) {
    final map = raw! as Map;
    return C7Pending(
      actionId: map['action'] as String,
      sentAtMs: map['at'] as int,
      record: _b64(map['record']),
      key: _b64(map['key']),
    );
  }
}

/// What happened to this device's own proposal when a record came back.
enum C7OwnOutcome { none, applied, lost }

/// One channel's C7 state in one group.
final class C7ChannelBook {
  C7ChannelBook({
    required this.channelId,
    required this.groupId,
    required this.chain,
    required Map<int, Uint8List> records,
    required List<C7Gen> gens,
    List<int> pastGens = const <int>[],
    this.pending,
    this.ownNotice,
    this.lastOwn = C7OwnOutcome.none,
  })  : records = Map<int, Uint8List>.unmodifiable(records),
        gens = List<C7Gen>.unmodifiable(gens),
        pastGens = List<int>.unmodifiable(pastGens);

  /// A channel this device holds no record for: `members_from_join`, no head.
  C7ChannelBook.genesis(this.channelId, this.groupId)
      : chain = const C7ChannelState.implicitGenesis(),
        records = const <int, Uint8List>{},
        gens = const <C7Gen>[],
        pastGens = const <int>[],
        pending = null,
        ownNotice = null,
        lastOwn = C7OwnOutcome.none;

  final String channelId;

  /// The group whose state this is (a shared group, or a private channel's
  /// own group).
  final String groupId;
  final C7ChannelState chain;

  /// Full forms of the kept records, by `seq` (the head among them).
  final Map<int, Uint8List> records;
  final List<C7Gen> gens;
  final List<int> pastGens;
  final C7Pending? pending;

  /// What became of this device's last own proposal: `lost` (another
  /// record took its seq), `stale` (sequenced after a membership commit; the
  /// app proposes it again) or `timeout`; null once the app has acted.
  final String? ownNotice;

  /// Not stored: what the last [applyRecord] did to [pending].
  final C7OwnOutcome lastOwn;

  bool get hasHead => chain.head != null;
  int get mode => chain.mode;
  C7Status get status => chain.status;

  /// The head's full form (512 bytes), or null.
  Uint8List? get headBytes {
    final head = chain.head;
    return head == null ? null : records[head.seq];
  }

  C7Record? get headRecord {
    final bytes = headBytes;
    return bytes == null ? null : C7Record.decode(bytes);
  }

  /// The first epoch of the current period: the opening epoch of its first
  /// generation, or null outside `full`.
  int? get periodStart => gens.isEmpty ? null : gens.first.epoch;

  /// The generation covering [epoch] in [group], or null.
  C7Gen? genAt(String group, int epoch) {
    for (final gen in gens.reversed) {
      if (gen.covers(group, epoch)) return gen;
    }
    return null;
  }

  /// The generation and key a post sent at [epoch] seals under: only while
  /// the channel is `full` and `ok` and the generation's key is held
  /// (I4: anything else seals under a random key).
  C7Gen? sealGenAt(int epoch) {
    if (!chain.sealsUnderHistoryKey) return null;
    final gen = genAt(groupId, epoch);
    return gen?.key == null ? null : gen;
  }

  C7ChannelBook copyWith({
    C7ChannelState? chain,
    Map<int, Uint8List>? records,
    List<C7Gen>? gens,
    List<int>? pastGens,
    C7Pending? pending,
    bool clearPending = false,
    String? ownNotice,
    bool clearNotice = false,
    C7OwnOutcome lastOwn = C7OwnOutcome.none,
  }) =>
      C7ChannelBook(
        channelId: channelId,
        groupId: groupId,
        chain: chain ?? this.chain,
        records: records ?? this.records,
        gens: gens ?? this.gens,
        pastGens: pastGens ?? this.pastGens,
        pending: clearPending ? null : (pending ?? this.pending),
        ownNotice: clearNotice ? null : (ownNotice ?? this.ownNotice),
        lastOwn: lastOwn,
      );

  List<int> _retired() {
    final all = <int>[...pastGens, for (final gen in gens) gen.epoch];
    return all.length <= c7PastGenerationLimit
        ? all
        : all.sublist(all.length - c7PastGenerationLimit);
  }

  /// A valid record [record] (full form [full]) meets the ordering table
  /// (decision 4). [key] is the key the carrying message gives: the compact
  /// record's `key` for a proposal, a slot's `key_c` for a report. It counts
  /// when it matches the record's `chk_commit`, or, for a report, when
  /// [entry] (the slot's generation entry) commits to it: then the current
  /// generation is the entry's and its wrap the one before it (decision 5,
  /// "Handover"). [ownProposal]: this device's own proposal came back.
  ({C7ChannelBook book, C7Row row}) applyRecord(
    C7Record record,
    Uint8List full, {
    required C7Source source,
    Uint8List? key,
    C7GenerationEntry? entry,
    bool ownProposal = false,
  }) {
    final group = utf8.decode(record.groupId);
    final fromEntry = record.opensKey &&
        key != null &&
        entry != null &&
        c7SameBytes(c7ChkCommitOf(key), entry.keyCommit) &&
        entry.epoch >= record.epoch &&
        // The period's first generation is the record's own key.
        (entry.epoch != record.epoch ||
            c7SameBytes(entry.keyCommit, record.chkCommit)) &&
        // A wrap never reaches before the period's record.
        (entry.previousEpoch == null ||
            (entry.previousEpoch! >= record.epoch &&
                entry.previousEpoch! < entry.epoch));
    final keyGiven = fromEntry ||
        (record.opensKey &&
            key != null &&
            c7SameBytes(c7ChkCommitOf(key), record.chkCommit));
    final step =
        chain.apply(C7Entry.of(record), source: source, keyGiven: keyGiven);
    var own = C7OwnOutcome.none;
    var pendingNext = pending;
    var notice = ownNotice;
    final applied = step.row == C7Row.adopt ||
        step.row == C7Row.apply ||
        step.row == C7Row.recover;
    if (ownProposal) {
      own = applied || step.row == C7Row.noop
          ? C7OwnOutcome.applied
          : C7OwnOutcome.lost;
      pendingNext = null;
      notice = own == C7OwnOutcome.lost ? 'lost' : null;
    } else if (pending != null && applied) {
      // Someone else's record took the seq this device proposed for, or
      // moved the chain past it: the proposal can only lose now.
      final mine = pending!.full;
      if (record.seq >= mine.seq) {
        own = C7OwnOutcome.lost;
        pendingNext = null;
        notice = 'lost';
      }
    }
    final next = step.state;
    final headChanged = applied;
    if (!headChanged) {
      return (
        book: C7ChannelBook(
          channelId: channelId,
          groupId: groupId,
          chain: next,
          records: records,
          gens: gens,
          pastGens: pastGens,
          pending: pendingNext,
          ownNotice: notice,
          lastOwn: own,
        ),
        row: step.row,
      );
    }
    // The kept records follow the table's map; the new head's bytes added.
    final keptRecords = <int, Uint8List>{
      for (final seq in next.kept.keys)
        if (seq == record.seq)
          seq: Uint8List.fromList(full)
        else if (records[seq] != null)
          seq: records[seq]!,
    };
    while (keptRecords.length > c7KeptRecordLimit) {
      keptRecords.remove(keptRecords.keys.reduce((a, b) => a < b ? a : b));
    }
    final trimmed = C7ChannelState.restore(
      head: next.head,
      kept: <int, C7Entry>{
        for (final seq in keptRecords.keys) seq: next.kept[seq]!,
      },
      highestSeq: next.highestSeq,
      status: next.status,
      missEpoch: next.missEpoch,
    );
    // A record that opens `full` (create, switch, move) opens a generation
    // with the record's random key; one that leaves `full` ends the period
    // and its keys are deleted (decision 2). A report whose entry commits to
    // its key gives the current generation and the one its wrap names.
    final List<C7Gen> nextGens;
    if (!record.opensKey) {
      nextGens = const <C7Gen>[];
    } else if (fromEntry && entry.epoch != record.epoch) {
      nextGens = <C7Gen>[
        if (entry.previousEpoch != null)
          C7Gen(
            epoch: entry.previousEpoch!,
            groupId: group,
            key: entry.previousKey,
            close: entry.epoch,
          ),
        C7Gen(epoch: entry.epoch, groupId: group, key: key),
      ];
    } else {
      nextGens = <C7Gen>[
        C7Gen(epoch: record.epoch, groupId: group, key: keyGiven ? key : null),
      ];
    }
    return (
      book: C7ChannelBook(
        channelId: channelId,
        groupId: groupId,
        chain: trimmed,
        records: keptRecords,
        gens: nextGens,
        pastGens: _retired(),
        pending: pendingNext,
        ownNotice: notice,
        lastOwn: own,
      ),
      row: step.row,
    );
  }

  /// A later valid slot for this device's own head (row 2) gave [key] for the
  /// generation [entry] names (decision 5): a `keyless` channel takes it and
  /// is `ok` when [forEpoch] is above its miss epoch; an `unsure` one is
  /// `ok` again when the key is the one it holds as current.
  C7ChannelBook confirmedBySlot(
      int forEpoch, Uint8List key, C7GenerationEntry entry) {
    if (chain.mode != c7ModeFull ||
        !c7SameBytes(c7ChkCommitOf(key), entry.keyCommit)) {
      return this;
    }
    final head = headRecord;
    if (head == null) return this;
    if (chain.status == C7Status.keyless) {
      if (entry.epoch == head.epoch &&
          !c7SameBytes(entry.keyCommit, head.chkCommit)) {
        return this;
      }
      final group = utf8.decode(head.groupId);
      final nextGens = <C7Gen>[
        for (final gen in gens)
          if (gen.epoch < entry.epoch) gen,
        if (entry.previousEpoch != null &&
            !gens.any((gen) => gen.epoch == entry.previousEpoch))
          C7Gen(
            epoch: entry.previousEpoch!,
            groupId: group,
            key: entry.previousKey,
            close: entry.epoch,
          ),
        C7Gen(epoch: entry.epoch, groupId: group, key: key),
      ]..sort((a, b) => a.epoch.compareTo(b.epoch));
      return copyWith(
        chain: chain.keyArrived(forEpoch),
        gens: nextGens,
      );
    }
    if (chain.status == C7Status.unsure) {
      final held = genAt(groupId, forEpoch);
      if (held?.key == null || !c7SameBytes(held!.key, key)) return this;
      return copyWith(chain: chain.slotConfirmed(forEpoch));
    }
    return this;
  }

  /// A removal commit produced [epoch] in this group and every member
  /// derived [key] from its exporter root (decision 5, "Rekey"). A channel
  /// whose period is open closes the previous generation at [epoch] and
  /// opens the next with [key]. Statuses do not change: a `keyless` device
  /// keeps the key but still seals under random keys until a slot or record
  /// confirms its head.
  C7ChannelBook rekey(int epoch, Uint8List key) {
    if (chain.mode != c7ModeFull || gens.isEmpty) return this;
    final last = gens.last;
    if (last.groupId != groupId || last.epoch >= epoch) return this;
    return copyWith(gens: <C7Gen>[
      ...gens.sublist(0, gens.length - 1),
      last.closedAt(epoch),
      C7Gen(epoch: epoch, groupId: groupId, key: key),
    ], pending: pending);
  }

  C7ChannelBook markUnsure(int epoch) =>
      copyWith(chain: chain.markUnsure(epoch), pending: pending);

  /// The slot plaintext and key this device hands over for this channel
  /// (decision 5, `history_sync`): an `ok` `full` channel whose key is held
  /// gives its current generation; anything else gives its head (or zeros)
  /// with a zero entry and a random key (null here).
  C7SlotSnapshot snapshot(int forEpoch) {
    final head = headBytes ?? Uint8List(c7RecordBytes);
    final gen = chain.sealsUnderHistoryKey ? genAt(groupId, forEpoch) : null;
    final key = gen?.key;
    if (gen == null || key == null) {
      return C7SlotSnapshot(
          head: head, key: null, entry: Uint8List(c7EntryBytes));
    }
    C7Gen? previous;
    final index = gens.indexOf(gen);
    if (index > 0) {
      final before = gens[index - 1];
      if (before.groupId == groupId &&
          before.key != null &&
          before.close == gen.epoch) {
        previous = before;
      }
    }
    final entry = C7GenerationEntry(
      epoch: gen.epoch,
      keyCommit: c7ChkCommitOf(key),
      previousEpoch: previous?.epoch,
      previousKey: previous?.key,
    );
    return C7SlotSnapshot(head: head, key: key, entry: entry.encode());
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'v': 1,
        'channel': channelId,
        'group': groupId,
        if (chain.head != null) 'head': chain.head!.seq,
        'records': <String, Object?>{
          for (final entry in records.entries)
            '${entry.key}': base64Encode(entry.value),
        },
        'highest': chain.highestSeq,
        'status': chain.status.name,
        'miss': chain.missEpoch,
        'gens': <Object?>[for (final gen in gens) gen.toJson()],
        'past': pastGens,
        if (pending != null) 'pending': pending!.toJson(),
        if (ownNotice != null) 'notice': ownNotice,
      };

  String encode() => jsonEncode(toJson());

  /// Reads a stored state. Anything malformed reads as `closed` with no
  /// generations, so the channel seals nothing under a history key and hands
  /// no key over until a live switch recovers it (I4, fail closed).
  static C7ChannelBook decode(
      String? stored, String channelId, String groupId) {
    if (stored == null) return C7ChannelBook.genesis(channelId, groupId);
    try {
      final map = jsonDecode(stored) as Map;
      if (map['v'] != 1 ||
          map['channel'] != channelId ||
          map['group'] != groupId) {
        throw const FormatException('C7 channel state');
      }
      final records = <int, Uint8List>{
        for (final entry in (map['records'] as Map).entries)
          int.parse(entry.key as String): _b64(entry.value),
      };
      final entries = <int, C7Entry>{
        for (final entry in records.entries)
          entry.key: C7Entry.of(C7Record.decode(entry.value)),
      };
      final headSeq = map['head'] as int?;
      final head = headSeq == null ? null : entries[headSeq];
      if (headSeq != null && head == null) {
        throw const FormatException('C7 head not kept');
      }
      final status = C7Status.values.byName(map['status'] as String);
      return C7ChannelBook(
        channelId: channelId,
        groupId: groupId,
        chain: C7ChannelState.restore(
          head: head,
          kept: entries,
          highestSeq: map['highest'] as int,
          status: status,
          missEpoch: map['miss'] as int,
        ),
        records: records,
        gens: <C7Gen>[
          for (final gen in map['gens'] as List) C7Gen.fromJson(gen)
        ],
        pastGens: (map['past'] as List).cast<int>(),
        pending:
            map['pending'] == null ? null : C7Pending.fromJson(map['pending']),
        ownNotice: map['notice'] as String?,
      );
    } on Object {
      return C7ChannelBook(
        channelId: channelId,
        groupId: groupId,
        chain:
            const C7ChannelState.implicitGenesis().withStatus(C7Status.closed),
        records: const <int, Uint8List>{},
        gens: const <C7Gen>[],
      );
    }
  }
}

/// What one channel's slot says in the `history_sync` for one membership
/// commit, fixed at merge (decision 5, "The state is the state at merge").
final class C7SlotSnapshot {
  C7SlotSnapshot({
    required List<int> head,
    required List<int>? key,
    required List<int> entry,
  })  : head = Uint8List.fromList(head),
        key = key == null ? null : Uint8List.fromList(key),
        entry = Uint8List.fromList(entry);

  /// The head's full form, or 512 zero bytes.
  final Uint8List head;

  /// `key_c` when the slot hands a key over; null: a random key at send.
  final Uint8List? key;
  final Uint8List entry;

  Uint8List get plain => Uint8List(c7SlotPlainBytes)
    ..setRange(0, c7RecordBytes, head)
    ..setRange(c7RecordBytes, c7SlotPlainBytes, entry);

  List<Object?> toJson() => <Object?>[
        base64Encode(head),
        key == null ? null : base64Encode(key!),
        base64Encode(entry),
      ];

  static C7SlotSnapshot fromJson(Object? raw) {
    final list = raw! as List;
    return C7SlotSnapshot(
      head: _b64(list[0]),
      key: list[1] == null ? null : _b64(list[1]),
      entry: _b64(list[2]),
    );
  }
}
