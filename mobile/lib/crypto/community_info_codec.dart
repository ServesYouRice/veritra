import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'native_crypto_bindings.dart';
import 'profile_record_codec.dart';
import 'sha256.dart';

/// C3 encrypted community info (docs/designs/C3-private-channels-and-info.md).
///
/// Names, topics and icons of a community, its categories and its channels
/// are W11 records with three more subject kinds: the same `VPR1` plaintext
/// framing, the same `VPE1` blob, the same chunk AEAD
/// (`pm_crypto_attachment_encrypt_chunk`, no ABI change) and the same context
/// literal (`ProfileRecordCodec.context`). The server stores the blob and
/// sees IDs only.
///
/// Deviation from the design text: a record goes into the smallest bucket it
/// fits (4 KiB, else 256 KiB), not "256 KiB only with an icon". A community
/// record lists up to 500 open channels, about 80 bytes each, which cannot fit
/// 4 KiB. So the large bucket shows "an icon or a big community", and a tiny
/// icon may hide in the small one.

const infoKindCommunity = 'community';
const infoKindCategory = 'category';
const infoKindChannel = 'channel';
const infoKinds = <String>{
  infoKindCommunity,
  infoKindCategory,
  infoKindChannel
};

const _plainMagic = 'VPR1';
const _blobMagic = 'VPE1';
const _blobOverhead = 4 + 8 + 16;
const infoNameMax = 100;
const infoTopicMax = 1024;
const infoMaxCategories = 50;
const infoMaxChannels = 500;
const infoMaxIconSide = 256;

final _communityId = RegExp(r'^comm_[0-9a-f]{32}$');
final _categoryId = RegExp(r'^cat_[0-9a-f]{32}$');
final _channelId = RegExp(r'^chan_[0-9a-f]{32}$');

bool validInfoSubject(String kind, String id) => switch (kind) {
      infoKindCommunity => _communityId.hasMatch(id),
      infoKindCategory => _categoryId.hasMatch(id),
      infoKindChannel => _channelId.hasMatch(id),
      _ => false,
    };

bool validCategoryId(String id) => _categoryId.hasMatch(id);
bool validChannelId(String id) => _channelId.hasMatch(id);

/// An open channel's place in the community record. A null [categoryId] is a
/// channel outside any category.
class InfoChannelPlace {
  const InfoChannelPlace({required this.channelId, this.categoryId});
  final String channelId;
  final String? categoryId;

  @override
  bool operator ==(Object other) =>
      other is InfoChannelPlace &&
      other.channelId == channelId &&
      other.categoryId == categoryId;
  @override
  int get hashCode => Object.hash(channelId, categoryId);
}

/// A private channel's own place: it is never listed in the community record
/// every member can read, so its record says where it sits.
class InfoPrivatePlace {
  const InfoPrivatePlace({this.categoryId, required this.position});
  final String? categoryId;
  final int position;
}

/// One decoded C3 record. Every content field null (and no lists) is a
/// tombstone: the category or channel is gone from the apps' view.
class CommunityInfoRecord {
  const CommunityInfoRecord({
    required this.kind,
    required this.subjectId,
    required this.revision,
    this.name,
    this.topic,
    this.icon,
    this.categories,
    this.channels,
    this.privatePlace,
  });

  final String kind;
  final String subjectId;
  final int revision;
  final String? name;

  /// Channels only.
  final String? topic;

  /// Community and channels only.
  final ProfilePhoto? icon;

  /// Community only: ordered category IDs.
  final List<String>? categories;

  /// Community only: ordered open channels.
  final List<InfoChannelPlace>? channels;

  /// Private channels only.
  final InfoPrivatePlace? privatePlace;

  bool get isTombstone =>
      name == null &&
      topic == null &&
      icon == null &&
      categories == null &&
      channels == null &&
      privatePlace == null;
}

class CommunityInfoCodec {
  CommunityInfoCodec(this._bindings, {Random? random})
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

  /// A new random 32-byte info key (community or private channel).
  Uint8List newKey() => _randomBytes(profileKeyBytes);

  /// What an `info_update` announcement carries: hex SHA-256 of the blob
  /// exactly as uploaded and served.
  static String recordSha256(List<int> blob) => sha256Hex(blob);

  /// Seals [record] under [key]. `record.revision` must be the server version
  /// this upload becomes. [noncePrefix] is for tests only.
  Uint8List seal({
    required List<int> key,
    required CommunityInfoRecord record,
    List<int>? noncePrefix,
  }) {
    if (key.length != profileKeyBytes ||
        !validInfoSubject(record.kind, record.subjectId) ||
        record.revision < 1) {
      throw const ProfileRecordException(ProfileRecordFailure.badInput);
    }
    final json = _toJson(record);
    // Round-trip the JSON through the receiver's checks, so this app never
    // uploads a record another app would refuse.
    _checkContent(json, kind: record.kind, subjectId: record.subjectId);
    final icon = record.icon;
    if (icon != null) {
      ProfileRecordCodec.checkPhoto(icon.png, icon.width, icon.height,
          maxSide: infoMaxIconSide);
    }
    final jsonBytes = utf8.encode(jsonEncode(json));
    final iconBytes = icon?.png ?? Uint8List(0);
    final used = 4 + 4 + jsonBytes.length + 4 + iconBytes.length;
    final bucket = used <= profileSmallBucket
        ? profileSmallBucket
        : used <= profileLargeBucket
            ? profileLargeBucket
            : throw const ProfileRecordException(ProfileRecordFailure.badInput);
    final plain = _randomBytes(bucket);
    final view = ByteData.sublistView(plain);
    var at = 0;
    plain.setRange(at, at += 4, utf8.encode(_plainMagic));
    view.setUint32(at, jsonBytes.length);
    at += 4;
    plain.setRange(at, at += jsonBytes.length, jsonBytes);
    view.setUint32(at, iconBytes.length);
    at += 4;
    plain.setRange(at, at + iconBytes.length, iconBytes);
    final nonce = noncePrefix ?? _randomBytes(8);
    final id = ProfileRecordCodec.keyId(key);
    try {
      final sealed = _bindings.encryptAttachmentChunk(
        key: key,
        noncePrefix: nonce,
        chunkIndex: 0,
        context: ProfileRecordCodec.context(record.kind, record.subjectId, id),
        plaintext: plain,
      );
      return Uint8List.fromList(
          <int>[...utf8.encode(_blobMagic), ...nonce, ...sealed]);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  /// Opens a fetched blob. [servedKeyId] and [servedVersion] are the server's
  /// `X-Profile-Key-Id` and `ETag`; [key] is the held key with that id;
  /// [cachedRevision] is the revision already accepted (0 for none).
  ///
  /// This checks the record itself. Whether to show it is the announcement
  /// check's call (`CommunityInfoBook`): a record no allowed editor announced
  /// is never displayed, however well it opens.
  CommunityInfoRecord open({
    required List<int> key,
    required String servedKeyId,
    required int servedVersion,
    required String kind,
    required String subjectId,
    required List<int> blob,
    int cachedRevision = 0,
  }) {
    if (key.length != profileKeyBytes || !validInfoSubject(kind, subjectId)) {
      throw const ProfileRecordException(ProfileRecordFailure.badInput);
    }
    if (ProfileRecordCodec.keyId(key) != servedKeyId) {
      throw const ProfileRecordException(ProfileRecordFailure.keyMismatch);
    }
    if ((blob.length != _blobOverhead + profileSmallBucket &&
            blob.length != _blobOverhead + profileLargeBucket) ||
        !ProfileRecordCodec.startsWith(blob, utf8.encode(_blobMagic))) {
      throw const ProfileRecordException(ProfileRecordFailure.badBlob);
    }
    final Uint8List plain;
    try {
      plain = Uint8List.fromList(_bindings.decryptAttachmentChunk(
        key: key,
        noncePrefix: blob.sublist(4, 12),
        chunkIndex: 0,
        context: ProfileRecordCodec.context(kind, subjectId, servedKeyId),
        ciphertext: blob.sublist(12),
      ));
    } on NativeCryptoException {
      throw const ProfileRecordException(ProfileRecordFailure.authFailed);
    }
    try {
      return _parse(plain,
          kind: kind,
          subjectId: subjectId,
          servedVersion: servedVersion,
          cachedRevision: cachedRevision);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  static Map<String, Object?> _toJson(CommunityInfoRecord r) {
    final icon = r.icon;
    final iconJson = icon == null
        ? null
        : <String, Object?>{
            'media_type': 'image/png',
            'width': icon.width,
            'height': icon.height,
          };
    return <String, Object?>{
      'v': 1,
      'kind': r.kind,
      'subject_id': r.subjectId,
      'revision': r.revision,
      'name': r.name?.trim(),
      if (r.kind == infoKindChannel) 'topic': r.topic,
      if (r.kind != infoKindCategory) 'icon': iconJson,
      if (r.kind == infoKindCommunity) ...{
        'categories': r.categories,
        'channels': r.channels
            ?.map((c) => <String, Object?>{
                  'channel_id': c.channelId,
                  'category_id': c.categoryId,
                })
            .toList(),
      },
      if (r.kind == infoKindChannel && r.privatePlace != null)
        'private': <String, Object?>{
          'category_id': r.privatePlace!.categoryId,
          'position': r.privatePlace!.position,
        },
    };
  }

  CommunityInfoRecord _parse(
    Uint8List plain, {
    required String kind,
    required String subjectId,
    required int servedVersion,
    required int cachedRevision,
  }) {
    const framing = ProfileRecordException(ProfileRecordFailure.badFraming);
    if (plain.length != profileSmallBucket &&
        plain.length != profileLargeBucket) {
      throw framing;
    }
    if (!ProfileRecordCodec.startsWith(plain, utf8.encode(_plainMagic))) {
      throw framing;
    }
    final view = ByteData.sublistView(plain);
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
    final iconLength = view.getUint32(at);
    at += 4;
    if (iconLength > plain.length - at) throw framing;
    if (decoded is! Map<String, Object?>) throw framing;
    final record = _checkContent(decoded, kind: kind, subjectId: subjectId);
    final revision = record.revision;
    if (revision != servedVersion) {
      throw const ProfileRecordException(ProfileRecordFailure.revisionMismatch);
    }
    if (revision < cachedRevision) {
      throw const ProfileRecordException(ProfileRecordFailure.rollback);
    }
    final rawIcon = decoded['icon'];
    if (rawIcon == null) {
      if (iconLength != 0) throw framing;
      return record;
    }
    if (rawIcon is! Map<String, Object?> ||
        rawIcon['media_type'] != 'image/png' ||
        rawIcon['width'] is! int ||
        rawIcon['height'] is! int ||
        rawIcon.length != 3 ||
        iconLength == 0) {
      throw const ProfileRecordException(ProfileRecordFailure.badPhoto);
    }
    final png = Uint8List.fromList(plain.sublist(at, at + iconLength));
    final width = rawIcon['width'] as int;
    final height = rawIcon['height'] as int;
    ProfileRecordCodec.checkPhoto(png, width, height, maxSide: infoMaxIconSide);
    return CommunityInfoRecord(
      kind: record.kind,
      subjectId: record.subjectId,
      revision: record.revision,
      name: record.name,
      topic: record.topic,
      icon: ProfilePhoto(png: png, width: width, height: height),
      categories: record.categories,
      channels: record.channels,
      privatePlace: record.privatePlace,
    );
  }

  /// The receiver's content check alone, for tests of JSON the sealing side
  /// would never write.
  @visibleForTesting
  static CommunityInfoRecord checkContent(Map<String, Object?> json,
          {required String kind, required String subjectId}) =>
      _checkContent(json, kind: kind, subjectId: subjectId);

  /// Checks the JSON of a record (without its icon bytes) and returns it with
  /// no icon.
  static CommunityInfoRecord _checkContent(
    Map<String, Object?> json, {
    required String kind,
    required String subjectId,
  }) {
    const framing = ProfileRecordException(ProfileRecordFailure.badFraming);
    const badName = ProfileRecordException(ProfileRecordFailure.badName);
    if (json['v'] != 1) throw framing;
    if (json['kind'] != kind || json['subject_id'] != subjectId) {
      throw const ProfileRecordException(ProfileRecordFailure.wrongSubject);
    }
    final revision = json['revision'];
    if (revision is! int || revision < 1) {
      throw const ProfileRecordException(ProfileRecordFailure.revisionMismatch);
    }
    // Required keys per kind. Unknown keys are ignored, as in W11, so a
    // later app may add fields; a key of another kind is refused.
    final required = switch (kind) {
      infoKindCommunity => const {'name', 'icon', 'categories', 'channels'},
      infoKindCategory => const {'name'},
      _ => const {'name', 'topic', 'icon'},
    };
    const kindKeys = {'topic', 'icon', 'categories', 'channels', 'private'};
    final foreign = kindKeys.difference(required).difference(
        kind == infoKindChannel ? const {'private'} : const <String>{});
    if (!required.every(json.containsKey) || foreign.any(json.containsKey)) {
      throw framing;
    }
    final rawName = json['name'];
    String? name;
    if (rawName != null) {
      if (rawName is! String ||
          !ProfileRecordCodec.validText(rawName, max: infoNameMax)) {
        throw badName;
      }
      name = rawName.trim();
    }
    final rawTopic = json['topic'];
    if (rawTopic != null &&
        (rawTopic is! String ||
            !ProfileRecordCodec.validText(rawTopic,
                max: infoTopicMax, allowEmpty: true))) {
      throw badName;
    }
    List<String>? categories;
    List<InfoChannelPlace>? channels;
    if (kind == infoKindCommunity) {
      // A community is never removed through its record: it always has a
      // name and both lists.
      final rawCategories = json['categories'];
      final rawChannels = json['channels'];
      if (name == null || rawCategories is! List || rawChannels is! List) {
        throw framing;
      }
      if (rawCategories.length > infoMaxCategories ||
          rawChannels.length > infoMaxChannels) {
        throw framing;
      }
      categories = <String>[];
      for (final c in rawCategories) {
        if (c is! String || !validCategoryId(c) || categories.contains(c)) {
          throw framing;
        }
        categories.add(c);
      }
      final seen = <String>{};
      channels = <InfoChannelPlace>[];
      for (final c in rawChannels) {
        if (c is! Map<String, Object?> ||
            c.length != 2 ||
            !c.containsKey('category_id')) {
          throw framing;
        }
        final channelId = c['channel_id'];
        final categoryId = c['category_id'];
        if (channelId is! String ||
            !validChannelId(channelId) ||
            !seen.add(channelId) ||
            (categoryId != null &&
                (categoryId is! String || !categories.contains(categoryId)))) {
          throw framing;
        }
        channels.add(InfoChannelPlace(
            channelId: channelId, categoryId: categoryId as String?));
      }
    }
    InfoPrivatePlace? privatePlace;
    final rawPrivate = json['private'];
    if (json.containsKey('private')) {
      if (rawPrivate is! Map<String, Object?> ||
          rawPrivate.length != 2 ||
          !rawPrivate.containsKey('category_id')) {
        throw framing;
      }
      final categoryId = rawPrivate['category_id'];
      final position = rawPrivate['position'];
      if ((categoryId != null &&
              (categoryId is! String || !validCategoryId(categoryId))) ||
          position is! int ||
          position < 0 ||
          position >= infoMaxChannels) {
        throw framing;
      }
      privatePlace = InfoPrivatePlace(
          categoryId: categoryId as String?, position: position);
    }
    final record = CommunityInfoRecord(
      kind: kind,
      subjectId: subjectId,
      revision: revision,
      name: name,
      topic: rawTopic as String?,
      categories: categories,
      channels: channels,
      privatePlace: privatePlace,
    );
    // A record names its subject or is a tombstone; a tombstone has nothing
    // else (W11 S9 for C3).
    final hasIcon = json['icon'] != null;
    if (name == null && !(record.isTombstone && !hasIcon)) {
      throw badName;
    }
    return record;
  }
}
