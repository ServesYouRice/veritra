import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'franking.dart';

const int appPayloadVersion = 2;
const int _headerLength = 8;
const int _paddingBucket = 256;
const int _maxPayloadBytes = 64 * 1024;

/// Longest message text, in UTF-16 code units, a payload body may carry. The
/// composer and edit dialog check it before sending.
const int maxAppTextLength = 16384;
const List<int> _magic = <int>[0x56, 0x41, 0x50, 0x31]; // VAP1

enum AppPayloadType {
  text,
  reply,
  edit,
  delete,
  reaction,
  attachmentManifest,
  pin,
  callSignal
}

class DecryptedAppPayload {
  const DecryptedAppPayload({
    required this.type,
    required this.actionId,
    required this.body,
    this.channelId,
  });

  final AppPayloadType type;
  final String actionId;
  final Map<String, Object?> body;
  final String? channelId;
}

/// What a decrypted application payload turned out to be (W8 step 0, P1).
/// Classification is total: [AppPayloadCodec.classify] never throws.
sealed class AppPayloadOutcome {
  const AppPayloadOutcome();
}

/// A payload this app understands, fully validated.
final class DecodedAppPayload extends AppPayloadOutcome {
  const DecodedAppPayload(this.payload);

  final DecryptedAppPayload payload;
}

/// Authentic (its context matched) but newer than, or unknown to, this app.
/// [rawJson] is the inner JSON exactly as decrypted, kept for a later app
/// version; [hidden] is the sender's `hidden: true` flag.
final class UnsupportedAppPayload extends AppPayloadOutcome {
  const UnsupportedAppPayload({required this.rawJson, required this.hidden});

  final String rawJson;
  final bool hidden;
}

/// Broken framing, JSON or context, or a known type with a bad body.
final class InvalidAppPayload extends AppPayloadOutcome {
  const InvalidAppPayload();
}

/// Encodes only client-visible content. The complete padded value is protected
/// by MLS; duplicated routing fields are checked after decryption so ciphertext
/// cannot be replayed into a different conversation, device, or action row.
class AppPayloadCodec {
  AppPayloadCodec({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  Uint8List encode({
    required AppPayloadType type,
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
    required Map<String, Object?> body,
    String? channelId,
    bool hidden = false,
  }) {
    validateContext(conversationId, senderDeviceId, actionId);
    final version = type == AppPayloadType.pin ||
            channelId != null ||
            hidden ||
            body.keys.any(const {
              'entities',
              'mentions',
              'forwarded',
              'profile_key',
              'group_profile_key'
            }.contains)
        ? 2
        : 1;
    _validateBody(type, body, version: version);
    return _frame(_innerJson(version, type, conversationId, senderDeviceId,
        actionId, body, channelId, hidden));
  }

  /// Encodes a franked payload (C6, `docs/crypto.md` "Franking v1"). Always
  /// `v: 2`, because a v1 receiver refuses any seventh top-level key.
  /// [canonical] is the inner JSON exactly as [encode] would write it at v2,
  /// which the franking commitment covers; the wire JSON is [canonical] with
  /// the `frank` member appended last ([frankWireJson]). Not sent yet: the
  /// sender and receiver wiring is a later, reviewed step.
  ({Uint8List padded, Uint8List canonical}) encodeFranked({
    required AppPayloadType type,
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
    required Map<String, Object?> body,
    required Uint8List frankKey,
    String? channelId,
    bool hidden = false,
  }) {
    validateContext(conversationId, senderDeviceId, actionId);
    _validateBody(type, body, version: 2);
    final canonical = _innerJson(2, type, conversationId, senderDeviceId,
        actionId, body, channelId, hidden);
    return (
      padded: _frame(frankWireJson(canonical, frankKey)),
      canonical: canonical
    );
  }

  static Uint8List _innerJson(
          int version,
          AppPayloadType type,
          String conversationId,
          String senderDeviceId,
          String actionId,
          Map<String, Object?> body,
          String? channelId,
          bool hidden) =>
      utf8.encode(jsonEncode(<String, Object?>{
        'v': version,
        'type': type.name,
        'conversation_id': conversationId,
        'sender_device_id': senderDeviceId,
        'action_id': actionId,
        if (channelId != null) 'channel_id': channelId,
        if (hidden) 'hidden': true,
        'body': body,
      }));

  Uint8List _frame(Uint8List encoded) {
    if (encoded.length > _maxPayloadBytes - _headerLength) {
      throw const FormatException('application payload is too large');
    }
    final unpadded = _headerLength + encoded.length;
    final paddedLength =
        ((unpadded + _paddingBucket - 1) ~/ _paddingBucket) * _paddingBucket;
    final result = Uint8List(paddedLength);
    result.setRange(0, _magic.length, _magic);
    ByteData.sublistView(result).setUint32(4, encoded.length, Endian.big);
    result.setRange(_headerLength, unpadded, encoded);
    for (var index = unpadded; index < result.length; index++) {
      result[index] = _random.nextInt(256);
    }
    return result;
  }

  DecryptedAppPayload decode(
    List<int> padded, {
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
  }) {
    validateContext(conversationId, senderDeviceId, actionId);
    if (padded.length < _paddingBucket ||
        padded.length > _maxPayloadBytes ||
        padded.length % _paddingBucket != 0 ||
        !_constantTimePrefix(padded, _magic)) {
      throw const FormatException('invalid application payload framing');
    }
    final length = ByteData.sublistView(Uint8List.fromList(padded))
        .getUint32(4, Endian.big);
    if (length <= 0 || length > padded.length - _headerLength) {
      throw const FormatException('invalid application payload length');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(
        padded.sublist(_headerLength, _headerLength + length),
        allowMalformed: false,
      ));
    } catch (_) {
      throw const FormatException('invalid application payload encoding');
    }
    if (decoded is! Map) {
      throw const FormatException('invalid application payload');
    }
    final map = Map<String, Object?>.from(decoded);
    final version = map['v'];
    if (version is! int || version < 1 || version > appPayloadVersion) {
      throw const FormatException('unsupported application payload version');
    }
    final typeName = map['type'];
    final type = AppPayloadType.values
        .where((candidate) => candidate.name == typeName)
        .firstOrNull;
    if (type == null ||
        map['conversation_id'] != conversationId ||
        map['sender_device_id'] != senderDeviceId ||
        map['action_id'] != actionId ||
        map['body'] is! Map) {
      throw const FormatException('application payload context mismatch');
    }
    final body = Map<String, Object?>.from(map['body'] as Map);
    if (map.containsKey('channel_id') ||
        (version == 1 &&
            (map.length != _v1Keys.length ||
                !map.keys.every(_v1Keys.contains))))
      throw const FormatException('invalid application payload context');
    _validateBody(type, body, version: version);
    return DecryptedAppPayload(type: type, actionId: actionId, body: body);
  }

  /// Checks the envelope fields the server supplied (P2). The decrypted
  /// context is compared against these afterwards.
  static void validateContext(
      String conversationId, String deviceId, String actionId) {
    if (conversationId.isEmpty ||
        deviceId.isEmpty ||
        actionId.isEmpty ||
        conversationId.length > 128 ||
        deviceId.length > 128 ||
        actionId.length > 128) {
      throw const FormatException('invalid application payload context');
    }
  }

  /// Decodes like [decode] but never throws (P1). Run it only on a context
  /// already checked with [validateContext].
  ///
  /// v1 stays strict; v2 validates required fields and ignores additive keys.
  /// Newer versions and reserved types are retained as unsupported rows.
  AppPayloadOutcome classify(
    List<int> padded, {
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
    String? channelId,
    bool communityShared = false,
  }) {
    try {
      if (padded.length < _paddingBucket ||
          padded.length > _maxPayloadBytes ||
          padded.length % _paddingBucket != 0 ||
          !_constantTimePrefix(padded, _magic)) {
        return const InvalidAppPayload();
      }
      final length = ByteData.sublistView(Uint8List.fromList(padded))
          .getUint32(4, Endian.big);
      if (length <= 0 || length > padded.length - _headerLength) {
        return const InvalidAppPayload();
      }
      final rawJson = utf8.decode(
        padded.sublist(_headerLength, _headerLength + length),
        allowMalformed: false,
      );
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) return const InvalidAppPayload();
      final map = Map<String, Object?>.from(decoded);
      final version = map['v'];
      if (version is! int ||
          version < 1 ||
          map['conversation_id'] != conversationId ||
          map['sender_device_id'] != senderDeviceId ||
          map['action_id'] != actionId ||
          map['type'] is! String ||
          map['body'] is! Map ||
          // Channel context is mandatory only for a shared community group.
          (communityShared
              ? channelId == null || map['channel_id'] != channelId
              : map.containsKey('channel_id'))) {
        return const InvalidAppPayload();
      }
      if (version > appPayloadVersion) {
        return UnsupportedAppPayload(
            rawJson: rawJson, hidden: map['hidden'] == true);
      }
      if (version == 1 &&
          (map.length != _v1Keys.length || !map.keys.every(_v1Keys.contains))) {
        return const InvalidAppPayload();
      }
      final type = AppPayloadType.values
          .where((candidate) => candidate.name == map['type'])
          .firstOrNull;
      if (type == null) {
        return UnsupportedAppPayload(
            rawJson: rawJson, hidden: map['hidden'] == true);
      }
      final body = Map<String, Object?>.from(map['body'] as Map);
      _validateBody(type, body, version: version);
      return DecodedAppPayload(DecryptedAppPayload(
          type: type,
          actionId: actionId,
          body: body,
          channelId: map['channel_id'] as String?));
    } catch (_) {
      return const InvalidAppPayload();
    }
  }

  void _validateBody(AppPayloadType type, Map<String, Object?> body,
      {int version = 1}) {
    bool stringField(String name, {int max = maxAppTextLength}) =>
        body[name] is String && (body[name] as String).length <= max;
    final valid = switch (type) {
      AppPayloadType.text =>
        stringField('text') && (version >= 2 || body.length == 1),
      AppPayloadType.reply => stringField('text') &&
          stringField('reply_to_id', max: 128) &&
          (version >= 2 || body.length == 2),
      AppPayloadType.edit => stringField('message_id', max: 128) &&
          stringField('text') &&
          (version >= 2 || body.length == 2),
      AppPayloadType.delete => stringField('message_id', max: 128) &&
          (version >= 2 || body.length == 1),
      AppPayloadType.reaction => stringField('message_id', max: 128) &&
          stringField('reaction', max: 32) &&
          (version >= 2 || body.length == 2),
      AppPayloadType.attachmentManifest => body['attachments'] is List &&
          (body['attachments'] as List).length <= 32,
      AppPayloadType.pin => version >= 2 &&
          stringField('message_id', max: 128) &&
          body['pinned'] is bool &&
          (body['pinned'] == false ||
              const [86400, 604800, 2592000]
                  .contains(body['duration_seconds'])),
      AppPayloadType.callSignal => body['signal'] is Map &&
          (version >= 2 || body.length == 1) &&
          jsonEncode(body['signal']).length <= 48 * 1024,
    };
    if (!valid) throw const FormatException('invalid application payload body');
  }
}

const Set<String> _v1Keys = <String>{
  'v',
  'type',
  'conversation_id',
  'sender_device_id',
  'action_id',
  'body',
};

bool _constantTimePrefix(List<int> value, List<int> expected) {
  if (value.length < expected.length) return false;
  var difference = 0;
  for (var index = 0; index < expected.length; index++) {
    difference |= value[index] ^ expected[index];
  }
  return difference == 0;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
