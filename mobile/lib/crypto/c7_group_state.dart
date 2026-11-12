// C7 per-group state kept across messages (docs/designs/C7-channel-history.md
// decision 5): the membership floor, the latest removal commit's rekey root,
// the channels this device keeps chain state for in the group, the slot
// snapshots taken at each membership commit, the `history_sync` duties and a
// newcomer's request timer. Stored as one sealed setting per group
// (`c7GroupSetting`) and written only inside the MLS transition that changes
// it, so a crash can never merge a removal and lose its root. Sealed settings
// are never copied into K1 backups, K2 bundles or history snapshots.
//
// Per-channel chains live beside it, one setting per channel
// (`c7_channel_book.dart`).
import 'dart:convert';
import 'dart:typed_data';

import 'c7_channel_book.dart';
import 'native_crypto_bindings.dart' show C7CommitOutcome;

/// Snapshots of at most this many membership commits are kept: a
/// `history_sync` for an older one is not sent (its newcomers are served by
/// a later one; a gap at worst).
const int c7SnapshotLimit = 4;

/// One membership commit's `history_sync` as this device sees it.
final class C7SyncDuty {
  const C7SyncDuty({required this.dueAtMs, this.settled = false});

  /// When this device sends its own if none that matches its snapshot has
  /// arrived: at once for the committer, after a jittered delay for others.
  final int dueAtMs;

  /// A matching `history_sync` arrived, or this device sent one.
  final bool settled;

  Map<String, Object?> toJson() =>
      <String, Object?>{'due': dueAtMs, if (settled) 'settled': true};

  static C7SyncDuty fromJson(Object? raw) {
    final map = raw! as Map;
    return C7SyncDuty(
        dueAtMs: map['due'] as int, settled: map['settled'] == true);
  }
}

final class C7GroupState {
  C7GroupState({
    required this.floor,
    this.rootEpoch,
    this.root,
    Set<String> channels = const <String>{},
    Map<int, Map<String, C7SlotSnapshot>> snapshots =
        const <int, Map<String, C7SlotSnapshot>>{},
    Map<int, C7SyncDuty> duties = const <int, C7SyncDuty>{},
    this.joinEpoch,
    this.requestDueAtMs,
    this.joinSynced = false,
    this.imported = false,
  })  : channels = Set<String>.unmodifiable(channels),
        snapshots =
            Map<int, Map<String, C7SlotSnapshot>>.unmodifiable(snapshots),
        duties = Map<int, C7SyncDuty>.unmodifiable(duties);

  /// A group this device holds no C7 state for.
  static final C7GroupState empty = C7GroupState(floor: 0);

  /// The epoch produced by the latest membership commit merged here (or the
  /// Welcome's epoch for a newcomer): every proposal must be at or above it.
  final int floor;

  /// The epoch the latest removal commit produced, and its exporter root
  /// (`veritra-c7-rekey-v1`). Kept until the next removal merge, so a
  /// channel learned later still gets its generation key.
  final int? rootEpoch;
  final Uint8List? root;

  /// Channels with a stored chain in this group (`c7ChannelSetting`).
  final Set<String> channels;

  /// Slot snapshots per membership commit (`for_epoch`), by channel.
  final Map<int, Map<String, C7SlotSnapshot>> snapshots;

  /// `history_sync` duties per `for_epoch`.
  final Map<int, C7SyncDuty> duties;

  /// A newcomer's join epoch (the Welcome's); null for a creator.
  final int? joinEpoch;

  /// When a newcomer asks for the `history_sync` of its join, if none came.
  final int? requestDueAtMs;

  /// A valid `history_sync` for [joinEpoch] has been applied.
  final bool joinSynced;

  /// The newcomer's history import has run.
  final bool imported;

  C7GroupState copyWith({
    int? floor,
    int? rootEpoch,
    Uint8List? root,
    Set<String>? channels,
    Map<int, Map<String, C7SlotSnapshot>>? snapshots,
    Map<int, C7SyncDuty>? duties,
    int? requestDueAtMs,
    bool clearRequest = false,
    bool? joinSynced,
    bool? imported,
  }) =>
      C7GroupState(
        floor: floor ?? this.floor,
        rootEpoch: rootEpoch ?? this.rootEpoch,
        root: root ?? this.root,
        channels: channels ?? this.channels,
        snapshots: snapshots ?? this.snapshots,
        duties: duties ?? this.duties,
        joinEpoch: joinEpoch,
        requestDueAtMs:
            clearRequest ? null : (requestDueAtMs ?? this.requestDueAtMs),
        joinSynced: joinSynced ?? this.joinSynced,
        imported: imported ?? this.imported,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'v': 2,
        'floor': floor,
        if (rootEpoch != null && root != null) ...<String, Object?>{
          'root_epoch': rootEpoch,
          'root': base64Encode(root!),
        },
        if (channels.isNotEmpty) 'channels': (channels.toList()..sort()),
        if (snapshots.isNotEmpty)
          'snapshots': <String, Object?>{
            for (final entry in snapshots.entries)
              '${entry.key}': <String, Object?>{
                for (final slot in entry.value.entries)
                  slot.key: slot.value.toJson(),
              },
          },
        if (duties.isNotEmpty)
          'duties': <String, Object?>{
            for (final entry in duties.entries)
              '${entry.key}': entry.value.toJson(),
          },
        if (joinEpoch != null) 'join': joinEpoch,
        if (requestDueAtMs != null) 'request_due': requestDueAtMs,
        if (joinSynced) 'join_synced': true,
        if (imported) 'imported': true,
      };

  String encode() => jsonEncode(toJson());

  /// Reads a stored state; anything malformed reads as [empty] (the group
  /// then seals nothing under history keys, which fails closed). Version 1
  /// (floor and root only) still reads.
  static C7GroupState decode(String? stored) {
    if (stored == null) return empty;
    try {
      final map = jsonDecode(stored);
      if (map is! Map || (map['v'] != 1 && map['v'] != 2)) return empty;
      final floor = map['floor'];
      if (floor is! int || floor < 0) return empty;
      final epoch = map['root_epoch'];
      final rootText = map['root'];
      Uint8List? root;
      int? rootEpoch;
      if (epoch is int && rootText is String) {
        final bytes = base64Decode(rootText);
        if (bytes.length == 32) {
          root = Uint8List.fromList(bytes);
          rootEpoch = epoch;
        }
      }
      return C7GroupState(
        floor: floor,
        rootEpoch: rootEpoch,
        root: root,
        channels: <String>{...?(map['channels'] as List?)?.cast<String>()},
        snapshots: <int, Map<String, C7SlotSnapshot>>{
          for (final entry
              in ((map['snapshots'] as Map?) ?? const <String, Object?>{})
                  .entries)
            int.parse(entry.key as String): <String, C7SlotSnapshot>{
              for (final slot in (entry.value as Map).entries)
                slot.key as String: C7SlotSnapshot.fromJson(slot.value),
            },
        },
        duties: <int, C7SyncDuty>{
          for (final entry
              in ((map['duties'] as Map?) ?? const <String, Object?>{}).entries)
            int.parse(entry.key as String): C7SyncDuty.fromJson(entry.value),
        },
        joinEpoch: map['join'] as int?,
        requestDueAtMs: map['request_due'] as int?,
        joinSynced: map['join_synced'] == true,
        imported: map['imported'] == true,
      );
    } on Object {
      return empty;
    }
  }

  /// The state after this device merged a commit, from what MLS itself
  /// reported (never the server's labels). Null when the commit removed
  /// this device: the caller deletes the group's C7 state (the re-add wipe).
  /// The caller still wipes [outcome]'s root afterwards; this keeps a copy.
  /// Snapshots and duties are the caller's ([withSnapshot]).
  C7GroupState? afterCommit(C7CommitOutcome outcome) {
    if (outcome.removedSelf) return null;
    if (!outcome.membership) return this;
    final root = outcome.removedAny ? outcome.root : null;
    return C7GroupState(
      floor: outcome.newEpoch,
      rootEpoch: root != null ? outcome.newEpoch : rootEpoch,
      root: root != null ? Uint8List.fromList(root) : this.root,
      channels: channels,
      snapshots: snapshots,
      duties: duties,
      joinEpoch: joinEpoch,
      requestDueAtMs: requestDueAtMs,
      joinSynced: joinSynced,
      imported: imported,
    );
  }

  /// The slots fixed at the merge that produced [forEpoch] and the duty to
  /// send its `history_sync` at [dueAtMs]. Older snapshots beyond
  /// [c7SnapshotLimit] are dropped.
  C7GroupState withSnapshot(
      int forEpoch, Map<String, C7SlotSnapshot> slots, int dueAtMs) {
    final nextSnapshots = <int, Map<String, C7SlotSnapshot>>{
      ...snapshots,
      forEpoch: Map<String, C7SlotSnapshot>.unmodifiable(slots),
    };
    final nextDuties = <int, C7SyncDuty>{
      ...duties,
      forEpoch: C7SyncDuty(dueAtMs: dueAtMs),
    };
    final epochs = nextSnapshots.keys.toList()..sort();
    while (epochs.length > c7SnapshotLimit) {
      final oldest = epochs.removeAt(0);
      nextSnapshots.remove(oldest);
      nextDuties.remove(oldest);
    }
    return copyWith(snapshots: nextSnapshots, duties: nextDuties);
  }

  /// The duty for [forEpoch] settled (a matching `history_sync` arrived or
  /// this device sent one), or re-armed at [dueAtMs] (a request).
  C7GroupState withDuty(int forEpoch, C7SyncDuty duty) =>
      copyWith(duties: <int, C7SyncDuty>{...duties, forEpoch: duty});

  /// A Welcome made this device a newcomer at [joinEpoch]: any earlier state
  /// for the group id (a removed and re-added device) is dropped by the
  /// caller. [requestDueAtMs] is when it asks for its `history_sync`.
  static C7GroupState joined(int joinEpoch, {int? requestDueAtMs}) =>
      C7GroupState(
        floor: joinEpoch,
        joinEpoch: joinEpoch,
        requestDueAtMs: requestDueAtMs,
      );
}
