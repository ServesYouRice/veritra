import 'dart:typed_data';

// Plain records for the L1 approved-device list tables (local schema 26).
// See `device_list_sql.dart` and docs/designs/L1-approved-device-list.md.

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A pair the pinned chain listed: added at [addedVersion], removed at
/// [removedVersion] (0 while it is listed).
class DeviceListKeyRow {
  DeviceListKeyRow({
    required List<int> deviceId,
    required List<int> signingKey,
    required this.addedVersion,
    required this.removedVersion,
    List<int>? frankKey,
  })  : deviceId = Uint8List.fromList(deviceId),
        signingKey = Uint8List.fromList(signingKey),
        frankKey = frankKey == null ? null : Uint8List.fromList(frankKey);

  final Uint8List deviceId;
  final Uint8List signingKey;
  final int addedVersion;
  final int removedVersion;

  /// L2-3: the X25519 franking key the chain gave this device (L1 format 2),
  /// fixed once set; null while it has none.
  final Uint8List? frankKey;

  DeviceListKeyRow withFrankKey(List<int>? key) => DeviceListKeyRow(
        deviceId: deviceId,
        signingKey: signingKey,
        addedVersion: addedVersion,
        removedVersion: removedVersion,
        frankKey: key,
      );

  DeviceListKeyRow removedAt(int version) => DeviceListKeyRow(
        deviceId: deviceId,
        signingKey: signingKey,
        addedVersion: addedVersion,
        removedVersion: version,
        frankKey: frankKey,
      );

  bool get listed => removedVersion == 0;
}

/// The verified head this device pinned for an account, and every pair the
/// chain ever listed.
class DeviceListPin {
  DeviceListPin({
    required this.accountId,
    required this.version,
    required List<int> listHash,
    required List<int> listId,
    required List<int> headStatement,
    required this.conflict,
    required this.checkedAt,
    required this.keys,
    List<int>? recoveryKey,
  })  : listHash = Uint8List.fromList(listHash),
        listId = Uint8List.fromList(listId),
        headStatement = Uint8List.fromList(headStatement),
        recoveryKey =
            recoveryKey == null ? null : Uint8List.fromList(recoveryKey);

  /// The head's recovery key (`rk_list_pub`), or null when it names none.
  final Uint8List? recoveryKey;

  /// The pairs the head lists now.
  List<DeviceListKeyRow> get listed => [
        for (final key in keys)
          if (key.listed) key
      ];

  DeviceListPin copyWith({bool? conflict, int? checkedAt}) => DeviceListPin(
        accountId: accountId,
        version: version,
        listHash: listHash,
        listId: listId,
        headStatement: headStatement,
        conflict: conflict ?? this.conflict,
        checkedAt: checkedAt ?? this.checkedAt,
        keys: keys,
        recoveryKey: recoveryKey,
      );

  final String accountId;
  final int version;
  final Uint8List listHash;
  final Uint8List listId;
  final Uint8List headStatement;

  /// A sticky fork: a validly signed statement disagreed with the pin.
  final bool conflict;
  final int checkedAt;
  final List<DeviceListKeyRow> keys;

  /// What the pin says about `(deviceId, signingKey)`.
  PinStanding standing(List<int> deviceId, List<int> signingKey) {
    var seen = false;
    for (final key in keys) {
      final sameDevice = _same(key.deviceId, deviceId);
      final sameKey = _same(key.signingKey, signingKey);
      if (sameDevice && sameKey) {
        return key.listed ? PinStanding.approved : PinStanding.removed;
      }
      // The id with another key, or the key under another id: never this
      // pair (one key, one device; a leaf never changes its key).
      if (sameDevice || sameKey) seen = true;
    }
    return seen ? PinStanding.mismatch : PinStanding.unknown;
  }

  /// L2-3: the franking key the pinned chain gave [deviceId], listed now or
  /// removed since (a report may be older than a removal), or null.
  Uint8List? frankKeyOf(List<int> deviceId) {
    for (final key in keys) {
      if (key.frankKey != null && _same(key.deviceId, deviceId)) {
        return key.frankKey;
      }
    }
    return null;
  }

  /// L2-3: the franking key the head lists for [deviceId], or null.
  Uint8List? listedFrankKey(List<int> deviceId) {
    for (final key in keys) {
      if (key.listed && _same(key.deviceId, deviceId)) return key.frankKey;
    }
    return null;
  }

  /// The signing key the pin lists now for [deviceId], or null.
  Uint8List? listedKey(List<int> deviceId) {
    for (final key in keys) {
      if (key.listed && _same(key.deviceId, deviceId)) return key.signingKey;
    }
    return null;
  }
}

enum PinStanding { approved, removed, mismatch, unknown }

/// How this device judged a leaf of a group (D94).
enum LeafVerdict {
  /// On its account's list now.
  approved,

  /// On the list once, removed since.
  removed,

  /// Never on its account's list (or the account's list is in conflict).
  unapproved,

  /// Not decided yet: the list could not be fetched or verified.
  checking,
}

class ApprovalLeaf {
  ApprovalLeaf({
    required this.conversationId,
    required List<int> accountId,
    required List<int> deviceId,
    required List<int> signingKey,
    required this.verdict,
    required this.updatedAt,
  })  : accountId = Uint8List.fromList(accountId),
        deviceId = Uint8List.fromList(deviceId),
        signingKey = Uint8List.fromList(signingKey);

  final String conversationId;
  final Uint8List accountId;
  final Uint8List deviceId;
  final Uint8List signingKey;
  final LeafVerdict verdict;
  final int updatedAt;

  bool get isStorable =>
      accountId.isNotEmpty &&
      accountId.length <= 128 &&
      deviceId.isNotEmpty &&
      deviceId.length <= 128 &&
      signingKey.length == 32;

  bool sameLeaf(List<int> account, List<int> device) =>
      _same(accountId, account) && _same(deviceId, device);

  ApprovalLeaf withVerdict(LeafVerdict next, int at) => ApprovalLeaf(
        conversationId: conversationId,
        accountId: accountId,
        deviceId: deviceId,
        signingKey: signingKey,
        verdict: next,
        updatedAt: at,
      );
}

/// Leaf verdicts to write for one conversation. With [replaceAll] the rows
/// are the conversation's whole group (after a commit or a Welcome) and any
/// other row is deleted (a leaf that left).
class ApprovalLeafChange {
  const ApprovalLeafChange({
    required this.conversationId,
    required this.leaves,
    required this.replaceAll,
  });

  final String conversationId;
  final List<ApprovalLeaf> leaves;
  final bool replaceAll;
}
