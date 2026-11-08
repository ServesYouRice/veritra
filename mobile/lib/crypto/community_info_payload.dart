import 'dart:convert';
import 'dart:typed_data';

import 'community_info_codec.dart';
import 'profile_record_codec.dart';

/// Bodies of the C3 MLS payloads `info_key`, `info_key_request` and
/// `info_update` (docs/crypto.md §5.x, docs/designs/C3-private-channels-and-info.md).
/// Pure Dart; the codec checks shape, never authority. Whether a key came
/// from the group that owns it, and whether an announcement came from an
/// allowed editor, is `CommunityInfoBook`'s call.
///
/// Only a community and a private channel have their own key: a category and
/// an open channel are sealed under the community key.
const keyedInfoKinds = <String>{infoKindCommunity, infoKindChannel};

final _hex32 = RegExp(r'^[0-9a-f]{32}$');
final _hex64 = RegExp(r'^[0-9a-f]{64}$');

bool _subject(Map<String, Object?> body, {required bool keyed}) {
  final kind = body['subject_kind'];
  final id = body['subject_id'];
  return kind is String &&
      id is String &&
      (keyed ? keyedInfoKinds.contains(kind) : infoKinds.contains(kind)) &&
      validInfoSubject(kind, id);
}

/// The 32 raw bytes of an `info_key` body's key, or null when the body does
/// not carry a well-formed key whose id matches `key_id`.
Uint8List? infoKeyBytes(Map<String, Object?> body) {
  final encoded = body['key'];
  final keyId = body['key_id'];
  if (encoded is! String || keyId is! String || !_hex32.hasMatch(keyId)) {
    return null;
  }
  final Uint8List key;
  try {
    key = base64.decode(encoded);
  } on FormatException {
    return null;
  }
  // Canonical base64 only, so one key has one encoding.
  if (key.length != profileKeyBytes || base64.encode(key) != encoded) {
    return null;
  }
  if (ProfileRecordCodec.keyId(key) != keyId) return null;
  return key;
}

bool isValidInfoKeyBody(Map<String, Object?> body) =>
    _subject(body, keyed: true) && infoKeyBytes(body) != null;

bool isValidInfoKeyRequestBody(Map<String, Object?> body) =>
    _subject(body, keyed: true);

bool isValidInfoUpdateBody(Map<String, Object?> body) {
  final revision = body['revision'];
  final keyId = body['key_id'];
  final digest = body['record_sha256'];
  return _subject(body, keyed: false) &&
      revision is int &&
      revision >= 1 &&
      keyId is String &&
      _hex32.hasMatch(keyId) &&
      digest is String &&
      _hex64.hasMatch(digest);
}

Map<String, Object?> infoKeyBody({
  required String subjectKind,
  required String subjectId,
  required List<int> key,
}) =>
    <String, Object?>{
      'subject_kind': subjectKind,
      'subject_id': subjectId,
      'key_id': ProfileRecordCodec.keyId(key),
      'key': base64.encode(key),
    };

Map<String, Object?> infoKeyRequestBody({
  required String subjectKind,
  required String subjectId,
}) =>
    <String, Object?>{'subject_kind': subjectKind, 'subject_id': subjectId};

Map<String, Object?> infoUpdateBody({
  required String subjectKind,
  required String subjectId,
  required int revision,
  required String keyId,
  required String recordSha256,
}) =>
    <String, Object?>{
      'subject_kind': subjectKind,
      'subject_id': subjectId,
      'revision': revision,
      'key_id': keyId,
      'record_sha256': recordSha256,
    };
