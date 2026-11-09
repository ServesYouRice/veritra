import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'native_crypto_bindings.dart';
import 'sha256.dart';

/// W11 encrypted profile records (docs/designs/W11-profiles.md).
///
/// One record holds a display name and an optional photo for an account or a
/// group. It is padded to one of two sizes and sealed with the existing chunk
/// AEAD (`pm_crypto_attachment_encrypt_chunk`, no ABI change), with a context
/// that binds the subject and the key id. The server stores the blob and never
/// sees a name, a photo or a key.

const profileKindAccount = 'account';
const profileKindConversation = 'conversation';

const _plainMagic = 'VPR1';
const _blobMagic = 'VPE1';
const profileSmallBucket = 4 * 1024;
const profileLargeBucket = 256 * 1024;
const profileMaxPhotoBytes = 192 * 1024;
const profileMaxPhotoSide = 512;
const profileAccountNameMax = 64;
const profileConversationNameMax = 100;
const profileKeyBytes = 32;
const _blobOverhead = 4 + 8 + 16;

/// Why a record was refused. Callers keep the cached profile on any of them.
enum ProfileRecordFailure {
  badInput,
  badBlob,
  keyMismatch,
  authFailed,
  badFraming,
  wrongSubject,
  revisionMismatch,
  rollback,
  badName,
  badPhoto,
}

class ProfileRecordException implements Exception {
  const ProfileRecordException(this.failure);
  final ProfileRecordFailure failure;
  // Names and keys never appear in the message.
  @override
  String toString() => 'ProfileRecordException(${failure.name})';
}

class ProfilePhoto {
  const ProfilePhoto({
    required this.png,
    required this.width,
    required this.height,
  });
  final Uint8List png;
  final int width;
  final int height;
}

/// A decoded record. Both [name] and [photo] null is a removed profile (S9).
class ProfileRecord {
  const ProfileRecord({
    required this.kind,
    required this.subjectId,
    required this.revision,
    this.name,
    this.photo,
  });
  final String kind;
  final String subjectId;
  final int revision;
  final String? name;
  final ProfilePhoto? photo;
  bool get isRemoved => name == null && photo == null;
}

class ProfileRecordCodec {
  ProfileRecordCodec(this._bindings, {Random? random})
      : _random = random ?? Random.secure();

  final NativeCryptoBindings _bindings;
  final Random _random;

  Uint8List _randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  /// A new random 32-byte profile key.
  Uint8List newKey() => _randomBytes(profileKeyBytes);

  /// `hex(SHA-256("veritra-profile-key-id-v1" || key)[0..16])`.
  static String keyId(List<int> key) {
    if (key.length != profileKeyBytes) {
      throw const ProfileRecordException(ProfileRecordFailure.badInput);
    }
    final digest = sha256(<int>[
      ...utf8.encode('veritra-profile-key-id-v1'),
      ...key,
    ]);
    final buffer = StringBuffer();
    for (final byte in digest.sublist(0, 16)) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static final _idPattern = RegExp(r'^(acct|conv)_[0-9a-f]{32}$');

  static bool _validSubject(String kind, String id) =>
      _idPattern.hasMatch(id) &&
      id.startsWith(kind == profileKindAccount ? 'acct_' : 'conv_');

  /// The AEAD context: `"veritra-profile-v1\0" kind "\0" subject "\0" keyId`.
  static Uint8List context(String kind, String subjectId, String keyId) =>
      Uint8List.fromList(utf8.encode(
        'veritra-profile-v1\u0000$kind\u0000$subjectId\u0000$keyId',
      ));

  /// Null when [name] is acceptable, otherwise why not. A name is 1..[max]
  /// UTF-16 units after trimming and holds no control or bidi characters.
  static bool validName(String name, {required String kind}) {
    final max = kind == profileKindAccount
        ? profileAccountNameMax
        : profileConversationNameMax;
    return validText(name, max: max);
  }

  /// [validName]'s rules for any short text: at most [max] UTF-16 units, no
  /// control, bidi or line-separator characters, no unpaired surrogates, and
  /// not blank unless [allowEmpty] (C3 topics may be empty).
  static bool validText(String name,
      {required int max, bool allowEmpty = false}) {
    if (name.length > max) return false;
    if (name.trim().isEmpty) return allowEmpty && name.isEmpty;
    final units = name.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      // Unpaired surrogates make Flutter text throw: refuse them.
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (i + 1 >= units.length ||
            units[i + 1] < 0xdc00 ||
            units[i + 1] > 0xdfff) {
          return false;
        }
        i++;
        continue;
      }
      if (unit >= 0xdc00 && unit <= 0xdfff) return false;
      if (unit == 0x2028 || unit == 0x2029 || unit == 0x200b) return false;
      if (unit < 0x20 || (unit >= 0x7f && unit <= 0x9f)) return false;
      if (unit >= 0x202a && unit <= 0x202e) return false;
      if (unit >= 0x2066 && unit <= 0x2069) return false;
      if (unit == 0x200e || unit == 0x200f || unit == 0x061c) return false;
    }
    return true;
  }

  /// Seals [record] under [key]. `record.revision` must be the server version
  /// this upload will become (If-Match + 1, or 1). [noncePrefix] is for tests
  /// only: real uploads draw eight fresh random bytes.
  Uint8List seal({
    required List<int> key,
    required ProfileRecord record,
    List<int>? noncePrefix,
  }) {
    if (key.length != profileKeyBytes ||
        !_validSubject(record.kind, record.subjectId) ||
        record.revision < 1 ||
        (record.kind != profileKindAccount &&
            record.kind != profileKindConversation)) {
      throw const ProfileRecordException(ProfileRecordFailure.badInput);
    }
    final name = record.name?.trim();
    if (name != null && !validName(name, kind: record.kind)) {
      throw const ProfileRecordException(ProfileRecordFailure.badName);
    }
    final photo = record.photo;
    if (photo != null) _checkPhoto(photo.png, photo.width, photo.height);
    final json = <String, Object?>{
      'v': 1,
      'kind': record.kind,
      'subject_id': record.subjectId,
      'revision': record.revision,
      'name': name,
      'photo': photo == null
          ? null
          : <String, Object?>{
              'media_type': 'image/png',
              'width': photo.width,
              'height': photo.height,
            },
    };
    final jsonBytes = utf8.encode(jsonEncode(json));
    final photoBytes = photo?.png ?? Uint8List(0);
    final bucket = photo == null ? profileSmallBucket : profileLargeBucket;
    final used = 4 + 4 + jsonBytes.length + 4 + photoBytes.length;
    if (used > bucket) {
      throw const ProfileRecordException(ProfileRecordFailure.badInput);
    }
    final plain = _randomBytes(bucket);
    final view = ByteData.sublistView(plain);
    var at = 0;
    plain.setRange(at, at += 4, utf8.encode(_plainMagic));
    view.setUint32(at, jsonBytes.length);
    at += 4;
    plain.setRange(at, at += jsonBytes.length, jsonBytes);
    view.setUint32(at, photoBytes.length);
    at += 4;
    plain.setRange(at, at + photoBytes.length, photoBytes);
    final nonce = noncePrefix ?? _randomBytes(8);
    final id = keyId(key);
    try {
      final sealed = _bindings.encryptAttachmentChunk(
        key: key,
        noncePrefix: nonce,
        chunkIndex: 0,
        context: context(record.kind, record.subjectId, id),
        plaintext: plain,
      );
      return Uint8List.fromList(
          <int>[...utf8.encode(_blobMagic), ...nonce, ...sealed]);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  /// Opens a fetched blob. Accepted only when every check of the design's
  /// "Receiving and caching" list passes; otherwise it throws and the caller
  /// keeps the cached profile (a 404 or a failure never clears it).
  ///
  /// [servedKeyId] and [servedVersion] are the server's `X-Profile-Key-Id` and
  /// `ETag`. [key] is the held key whose id equals [servedKeyId].
  /// [cachedRevision] is the revision already accepted (0 for none) and
  /// [versionFloor] the highest authenticated hint (accounts only).
  ProfileRecord open({
    required List<int> key,
    required String servedKeyId,
    required int servedVersion,
    required String kind,
    required String subjectId,
    required List<int> blob,
    int cachedRevision = 0,
    int versionFloor = 0,
  }) {
    if (key.length != profileKeyBytes ||
        (kind != profileKindAccount && kind != profileKindConversation) ||
        !_validSubject(kind, subjectId)) {
      throw const ProfileRecordException(ProfileRecordFailure.badInput);
    }
    if (keyId(key) != servedKeyId) {
      throw const ProfileRecordException(ProfileRecordFailure.keyMismatch);
    }
    if (blob.length != _blobOverhead + profileSmallBucket &&
        blob.length != _blobOverhead + profileLargeBucket) {
      throw const ProfileRecordException(ProfileRecordFailure.badBlob);
    }
    if (!_startsWith(blob, utf8.encode(_blobMagic))) {
      throw const ProfileRecordException(ProfileRecordFailure.badBlob);
    }
    final Uint8List plain;
    try {
      plain = Uint8List.fromList(_bindings.decryptAttachmentChunk(
        key: key,
        noncePrefix: blob.sublist(4, 12),
        chunkIndex: 0,
        context: context(kind, subjectId, servedKeyId),
        ciphertext: blob.sublist(12),
      ));
    } on NativeCryptoException {
      throw const ProfileRecordException(ProfileRecordFailure.authFailed);
    }
    try {
      return _parse(
        plain,
        kind: kind,
        subjectId: subjectId,
        servedVersion: servedVersion,
        cachedRevision: cachedRevision,
        versionFloor: versionFloor,
      );
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  ProfileRecord _parse(
    Uint8List plain, {
    required String kind,
    required String subjectId,
    required int servedVersion,
    required int cachedRevision,
    required int versionFloor,
  }) {
    const framing = ProfileRecordException(ProfileRecordFailure.badFraming);
    if (plain.length != profileSmallBucket &&
        plain.length != profileLargeBucket) {
      throw framing;
    }
    final view = ByteData.sublistView(plain);
    if (!_startsWith(plain, utf8.encode(_plainMagic))) throw framing;
    var at = 4;
    final jsonLength = view.getUint32(at);
    at += 4;
    if (jsonLength > plain.length - at - 4) throw framing;
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plain.sublist(at, at + jsonLength)));
    } on FormatException {
      throw framing;
    }
    at += jsonLength;
    final photoLength = view.getUint32(at);
    at += 4;
    if (photoLength > plain.length - at) throw framing;
    if (decoded is! Map<String, Object?>) throw framing;
    if (decoded['v'] != 1) throw framing;
    // (2) The record names the subject that was asked for.
    if (decoded['kind'] != kind || decoded['subject_id'] != subjectId) {
      throw const ProfileRecordException(ProfileRecordFailure.wrongSubject);
    }
    // (3) The authenticated revision equals the served version.
    final revision = decoded['revision'];
    if (revision is! int || revision != servedVersion) {
      throw const ProfileRecordException(ProfileRecordFailure.revisionMismatch);
    }
    // (4) No rollback below the cache or the authenticated floor.
    if (revision < cachedRevision ||
        (kind == profileKindAccount && revision < versionFloor)) {
      throw const ProfileRecordException(ProfileRecordFailure.rollback);
    }
    // (5) The name passes the rules.
    final rawName = decoded['name'];
    String? name;
    if (rawName != null) {
      if (rawName is! String || !validName(rawName, kind: kind)) {
        throw const ProfileRecordException(ProfileRecordFailure.badName);
      }
      name = rawName.trim();
    }
    final rawPhoto = decoded['photo'];
    ProfilePhoto? photo;
    if (rawPhoto == null) {
      if (photoLength != 0) throw framing;
    } else {
      if (rawPhoto is! Map<String, Object?> ||
          rawPhoto['media_type'] != 'image/png' ||
          rawPhoto['width'] is! int ||
          rawPhoto['height'] is! int ||
          photoLength == 0) {
        throw const ProfileRecordException(ProfileRecordFailure.badPhoto);
      }
      final png = Uint8List.fromList(plain.sublist(at, at + photoLength));
      _checkPhoto(png, rawPhoto['width'] as int, rawPhoto['height'] as int);
      photo = ProfilePhoto(
        png: png,
        width: rawPhoto['width'] as int,
        height: rawPhoto['height'] as int,
      );
    }
    return ProfileRecord(
      kind: kind,
      subjectId: subjectId,
      revision: revision,
      name: name,
      photo: photo,
    );
  }

  /// Checks a PNG before any decoder sees it: signature, size, and an IHDR
  /// whose width and height are within bounds and equal the declared ones.
  static void _checkPhoto(Uint8List png, int width, int height) =>
      checkPhoto(png, width, height);

  /// [_checkPhoto] with a caller's side limit (C3 icons are at most 256).
  static void checkPhoto(Uint8List png, int width, int height,
      {int maxSide = profileMaxPhotoSide}) {
    const bad = ProfileRecordException(ProfileRecordFailure.badPhoto);
    if (png.length < 33 || png.length > profileMaxPhotoBytes) throw bad;
    const signature = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    for (var i = 0; i < signature.length; i++) {
      if (png[i] != signature[i]) throw bad;
    }
    final view = ByteData.sublistView(png);
    if (view.getUint32(8) != 13 ||
        !_startsWith(png.sublist(12), utf8.encode('IHDR'))) {
      throw bad;
    }
    final w = view.getUint32(16);
    final h = view.getUint32(20);
    if (w == 0 ||
        h == 0 ||
        w > maxSide ||
        h > maxSide ||
        w != width ||
        h != height) {
      throw bad;
    }
  }

  static bool startsWith(List<int> data, List<int> prefix) =>
      _startsWith(data, prefix);

  static bool _startsWith(List<int> data, List<int> prefix) {
    if (data.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }
}
