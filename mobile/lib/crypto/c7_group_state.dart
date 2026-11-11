// C7 per-group state kept across messages (docs/designs/C7-channel-history.md
// decision 5): the membership floor and the latest removal commit's rekey
// root. Stored as one sealed setting per group (`c7GroupSetting`) and written
// only inside the MLS transition that changes it, so a crash can never merge
// a removal and lose its root. Sealed settings are never copied into K1
// backups, K2 bundles or history snapshots.
//
// Not here yet: per-channel chains (head, records, status), period and
// generation keys, the membership-commit snapshot for `history_sync`.
import 'dart:convert';
import 'dart:typed_data';

import 'native_crypto_bindings.dart' show C7CommitOutcome;

final class C7GroupState {
  const C7GroupState({required this.floor, this.rootEpoch, this.root});

  /// A group this device holds no C7 state for.
  static const C7GroupState empty = C7GroupState(floor: 0);

  /// The epoch produced by the latest membership commit merged here (or the
  /// Welcome's epoch for a newcomer): every record must be at or above it.
  final int floor;

  /// The epoch the latest removal commit produced, and its exporter root
  /// (`veritra-c7-rekey-v1`). Kept until the next removal merge, so a
  /// channel learned later still gets its generation key.
  final int? rootEpoch;
  final Uint8List? root;

  Map<String, Object?> toJson() => <String, Object?>{
        'v': 1,
        'floor': floor,
        if (rootEpoch != null && root != null) ...<String, Object?>{
          'root_epoch': rootEpoch,
          'root': base64Encode(root!),
        },
      };

  String encode() => jsonEncode(toJson());

  /// Reads a stored state; anything malformed reads as [empty] (the group
  /// then seals nothing under history keys, which fails closed).
  static C7GroupState decode(String? stored) {
    if (stored == null) return empty;
    try {
      final map = jsonDecode(stored);
      if (map is! Map || map['v'] != 1) return empty;
      final floor = map['floor'];
      if (floor is! int || floor < 0) return empty;
      final epoch = map['root_epoch'];
      final root = map['root'];
      if (epoch is int && root is String) {
        final bytes = base64Decode(root);
        if (bytes.length == 32) {
          return C7GroupState(
              floor: floor, rootEpoch: epoch, root: Uint8List.fromList(bytes));
        }
      }
      return C7GroupState(floor: floor);
    } on Object {
      return empty;
    }
  }

  /// The state after this device merged a commit, from what MLS itself
  /// reported (never the server's labels). Null when the commit removed
  /// this device: the caller deletes the group's C7 state (the re-add wipe).
  /// The caller still wipes [outcome]'s root afterwards; this keeps a copy.
  C7GroupState? afterCommit(C7CommitOutcome outcome) {
    if (outcome.removedSelf) return null;
    if (!outcome.membership) return this;
    final root = outcome.removedAny ? outcome.root : null;
    return C7GroupState(
      floor: outcome.newEpoch,
      rootEpoch: root != null ? outcome.newEpoch : rootEpoch,
      root: root != null ? Uint8List.fromList(root) : this.root,
    );
  }

  /// A Welcome made this device a newcomer at [joinEpoch]: any earlier state
  /// for the group id (a removed and re-added device) is dropped.
  static C7GroupState joined(int joinEpoch) => C7GroupState(floor: joinEpoch);
}
