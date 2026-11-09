import 'dart:typed_data';

/// What a profile GET answered (W11): a record, or "unchanged" for a 304.
/// A 404 is an [ApiException] of kind notFound; callers keep their cache.
class ProfileFetch {
  const ProfileFetch.notModified()
      : notModified = true,
        version = 0,
        keyId = '',
        blob = null;

  const ProfileFetch.record({
    required this.version,
    required this.keyId,
    required Uint8List this.blob,
  }) : notModified = false;

  final bool notModified;
  final int version;
  final String keyId;
  final Uint8List? blob;
}

/// One row of the batch version check: the server's current version and key
/// id for a subject the caller may read.
class ProfileVersion {
  const ProfileVersion({
    required this.kind,
    required this.id,
    required this.version,
    required this.keyId,
  });

  final String kind;
  final String id;
  final int version;
  final String keyId;

  factory ProfileVersion.fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    final id = json['id'];
    final version = json['version'];
    final keyId = json['key_id'];
    if (kind is! String ||
        id is! String ||
        version is! int ||
        version < 1 ||
        keyId is! String) {
      throw const FormatException('invalid profile version');
    }
    return ProfileVersion(kind: kind, id: id, version: version, keyId: keyId);
  }
}
