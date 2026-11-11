import 'dart:convert';
import 'dart:typed_data';

/// One K1 copy in the account's backup list (K1-4), as the server states it.
/// All of it is the server's claim: the container's own header, opened with
/// the recovery key, is what the restore trusts.
class K1BackupEntry {
  const K1BackupEntry({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.deviceRevoked,
    required this.createdAt,
    required this.sizeBytes,
    required this.sha256Hex,
    required this.rkId,
    required this.counter,
    required this.superseded,
  });

  final String id;
  final String deviceId;
  final String deviceName;
  final bool deviceRevoked;
  final DateTime createdAt;
  final int sizeBytes;
  final String sha256Hex;
  final Uint8List rkId;
  final int counter;
  final bool superseded;

  /// A K1 row, or null for a legacy or malformed row (never a guess).
  static K1BackupEntry? tryParse(Object? raw) {
    if (raw is! Map || raw['kind'] != 1) return null;
    final id = raw['id'], device = raw['device_id'];
    final sha = raw['ciphertext_sha256'], size = raw['size_bytes'];
    final created = raw['created_at'], counter = raw['counter'];
    if (id is! String ||
        id.isEmpty ||
        device is! String ||
        device.isEmpty ||
        sha is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ||
        size is! int ||
        size <= 0 ||
        created is! String ||
        counter is! int ||
        counter <= 0) {
      return null;
    }
    final at = DateTime.tryParse(created);
    final Uint8List rkId;
    try {
      rkId = base64.decode(raw['rk_id'] as String);
    } catch (_) {
      return null;
    }
    if (at == null || rkId.length != 16) return null;
    return K1BackupEntry(
      id: id,
      deviceId: device,
      deviceName:
          raw['device_name'] is String ? raw['device_name'] as String : '',
      deviceRevoked: raw['device_revoked'] == true,
      createdAt: at.toUtc(),
      sizeBytes: size,
      sha256Hex: sha,
      rkId: rkId,
      counter: counter,
      superseded: raw['superseded'] == true,
    );
  }
}

/// The copies a restore offers: K1 rows only, never this device's own (the
/// importer refuses a snapshot whose source is the receiving device), the
/// current copy of each device first, newest first. Superseded copies come
/// last, so the screen can show them as "the one before".
List<K1BackupEntry> k1RestoreCandidates(
    Iterable<K1BackupEntry> entries, String ownDeviceId) {
  final list = entries.where((e) => e.deviceId != ownDeviceId).toList()
    ..sort((a, b) {
      if (a.superseded != b.superseded) return a.superseded ? 1 : -1;
      return b.createdAt.compareTo(a.createdAt);
    });
  return list;
}

/// Why a restore did not finish. Only the kind, never a message.
enum K1RestoreResult {
  /// The history was merged in.
  done,

  /// The typed text is not a recovery key, or not this account's.
  wrongKey,

  /// This copy is sealed to another key than the one typed.
  otherKey,

  /// The server's list or file did not match (wrong account, device, digest
  /// or a tampered container).
  corrupt,

  /// No connection, a timeout, or a server error: nothing changed.
  network,

  /// This build or session cannot restore.
  unavailable,
}

/// The container header's length: all a peek needs (matches
/// `NativeCryptoBindings.backupPeekBytes`).
const int k1BackupPeekBytes = 416;
