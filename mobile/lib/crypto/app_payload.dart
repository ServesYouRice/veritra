import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

const int appPayloadVersion = 1;
const int _headerLength = 8;
const int _paddingBucket = 256;
const int _maxPayloadBytes = 64 * 1024;
const List<int> _magic = <int>[0x56, 0x41, 0x50, 0x31]; // VAP1

enum AppPayloadType {
  text,
  reply,
  edit,
  delete,
  reaction,
  attachmentManifest,
  callSignal
}

class DecryptedAppPayload {
  const DecryptedAppPayload({
    required this.type,
    required this.actionId,
    required this.body,
  });

  final AppPayloadType type;
  final String actionId;
  final Map<String, Object?> body;
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
  }) {
    _validateContext(conversationId, senderDeviceId, actionId);
    _validateBody(type, body);
    final encoded = utf8.encode(jsonEncode(<String, Object?>{
      'v': appPayloadVersion,
      'type': type.name,
      'conversation_id': conversationId,
      'sender_device_id': senderDeviceId,
      'action_id': actionId,
      'body': body,
    }));
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
    _validateContext(conversationId, senderDeviceId, actionId);
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
    if (map['v'] != appPayloadVersion) {
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
    _validateBody(type, body);
    return DecryptedAppPayload(type: type, actionId: actionId, body: body);
  }

  void _validateContext(
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

  void _validateBody(AppPayloadType type, Map<String, Object?> body) {
    bool stringField(String name, {int max = 16384}) =>
        body[name] is String && (body[name] as String).length <= max;
    final valid = switch (type) {
      AppPayloadType.text => stringField('text') && body.length == 1,
      AppPayloadType.reply => stringField('text') &&
          stringField('reply_to_id', max: 128) &&
          body.length == 2,
      AppPayloadType.edit => stringField('message_id', max: 128) &&
          stringField('text') &&
          body.length == 2,
      AppPayloadType.delete =>
        stringField('message_id', max: 128) && body.length == 1,
      AppPayloadType.reaction => stringField('message_id', max: 128) &&
          stringField('reaction', max: 32) &&
          body.length == 2,
      AppPayloadType.attachmentManifest => body['attachments'] is List &&
          (body['attachments'] as List).length <= 32,
      AppPayloadType.callSignal => body['signal'] is Map &&
          body.length == 1 &&
          jsonEncode(body['signal']).length <= 48 * 1024,
    };
    if (!valid) throw const FormatException('invalid application payload body');
  }
}

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
