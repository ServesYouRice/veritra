import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/app_payload.dart';

void main() {
  final codec = AppPayloadCodec(random: Random(7));

  test('application payload round-trips in a padded authenticated context', () {
    final encoded = codec.encode(
      type: AppPayloadType.reply,
      conversationId: 'conv_1',
      senderDeviceId: 'dev_1',
      actionId: 'action_1',
      body: const <String, Object?>{'text': 'hello', 'reply_to_id': 'msg_1'},
    );

    expect(encoded.length % 256, 0);
    final decoded = codec.decode(
      encoded,
      conversationId: 'conv_1',
      senderDeviceId: 'dev_1',
      actionId: 'action_1',
    );
    expect(decoded.type, AppPayloadType.reply);
    expect(decoded.body, <String, Object?>{
      'text': 'hello',
      'reply_to_id': 'msg_1',
    });
  });

  test('application payload rejects replay into another context', () {
    final encoded = codec.encode(
      type: AppPayloadType.text,
      conversationId: 'conv_1',
      senderDeviceId: 'dev_1',
      actionId: 'action_1',
      body: const <String, Object?>{'text': 'hello'},
    );

    for (final context
        in <({String conversation, String device, String action})>[
      (conversation: 'conv_2', device: 'dev_1', action: 'action_1'),
      (conversation: 'conv_1', device: 'dev_2', action: 'action_1'),
      (conversation: 'conv_1', device: 'dev_1', action: 'action_2'),
    ]) {
      expect(
        () => codec.decode(
          encoded,
          conversationId: context.conversation,
          senderDeviceId: context.device,
          actionId: context.action,
        ),
        throwsFormatException,
      );
    }
  });

  test('application payload rejects unknown versions and damaged framing', () {
    final encoded = codec.encode(
      type: AppPayloadType.delete,
      conversationId: 'conv_1',
      senderDeviceId: 'dev_1',
      actionId: 'action_1',
      body: const <String, Object?>{'message_id': 'msg_1'},
    );
    final unknownVersion = List<int>.from(encoded);
    final marker = utf8.encode('"v":1');
    final markerIndex = _indexOf(unknownVersion, marker);
    expect(markerIndex, greaterThanOrEqualTo(0));
    unknownVersion[markerIndex + marker.length - 1] = 0x32;
    expect(
      () => codec.decode(
        unknownVersion,
        conversationId: 'conv_1',
        senderDeviceId: 'dev_1',
        actionId: 'action_1',
      ),
      throwsFormatException,
    );

    final damaged = List<int>.from(encoded);
    damaged[0] ^= 0xff;
    expect(
      () => codec.decode(
        damaged,
        conversationId: 'conv_1',
        senderDeviceId: 'dev_1',
        actionId: 'action_1',
      ),
      throwsFormatException,
    );
  });
}

int _indexOf(List<int> haystack, List<int> needle) {
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matches = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[start + offset] != needle[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return start;
  }
  return -1;
}
