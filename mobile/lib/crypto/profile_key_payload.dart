import 'dart:convert';
import 'dart:typed_data';

import 'profile_record_codec.dart';

/// W11 profile keys inside MLS payloads (docs/designs/W11-profiles.md,
/// "MLS payloads"). A key travels as the body of a hidden `profile_key` or
/// `group_profile_key` message, or as a sidecar member of the same name on a
/// text, reply, attachment manifest or poll body.

const String profileKeyBodyName = 'profile_key';
const String groupProfileKeyBodyName = 'group_profile_key';

/// Post types that may carry the sidecars.
const Set<String> profileSidecarCarrierTypes = {
  'text',
  'reply',
  'attachmentManifest',
  'poll',
};

/// A key that passed the field rules.
class ParsedProfileKey {
  ParsedProfileKey({
    required this.key,
    required this.keyId,
    required this.version,
  });

  final Uint8List key;
  final String keyId;

  /// The server version current when the sender sent the key (S10).
  final int version;
}

/// Reads a key body or sidecar. Null when it breaks a rule: `key` must decode
/// to exactly 32 bytes, `key_id` must equal the derived id, `version` must be
/// an integer of at least 0. A key that breaks a rule is dropped alone; the
/// message around it is kept.
ParsedProfileKey? parseProfileKey(Object? raw) {
  if (raw is! Map) return null;
  final encoded = raw['key'];
  final keyId = raw['key_id'];
  final version = raw['version'];
  if (encoded is! String ||
      encoded.length > 64 ||
      keyId is! String ||
      version is! int ||
      version < 0) {
    return null;
  }
  final Uint8List key;
  try {
    key = base64.decode(encoded);
  } on FormatException {
    return null;
  }
  if (key.length != profileKeyBytes) return null;
  if (ProfileRecordCodec.keyId(key) != keyId) return null;
  return ParsedProfileKey(key: key, keyId: keyId, version: version);
}

/// The body of a key message or sidecar.
Map<String, Object?> profileKeyBody({
  required List<int> key,
  required String keyId,
  required int version,
}) =>
    <String, Object?>{
      'key': base64.encode(key),
      'key_id': keyId,
      'version': version,
    };
