import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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
    unknownVersion[markerIndex + marker.length - 1] = 0x33;
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
  group('sender expiry (TASK-106)', () {
    Uint8List framed(int? expiresAtMs) => codec
        .encodeFranked(
          type: AppPayloadType.text,
          conversationId: 'conv_1',
          senderDeviceId: 'dev_1',
          actionId: 'action_1',
          body: const <String, Object?>{'text': 'hello'},
          frankKey: Uint8List(32),
          expiresAtMs: expiresAtMs,
        )
        .padded;

    int? read(Uint8List padded) {
      final outcome = codec.classify(padded,
          conversationId: 'conv_1',
          senderDeviceId: 'dev_1',
          actionId: 'action_1');
      return (outcome as DecodedAppPayload).payload.expiresAtMs;
    }

    test('the sender expiry round-trips inside the payload', () {
      expect(read(framed(1900000000000)), 1900000000000);
    });

    test('a payload with no expiry reads as none (older sender)', () {
      expect(read(framed(null)), isNull);
    });

    test('a damaged expiry reads as none, not as a failure', () {
      for (final bad in <Object?>[-5, 0, 'soon', 3.5, 999999999999999999]) {
        final json = jsonEncode(<String, Object?>{
          'v': 2,
          'type': 'text',
          'conversation_id': 'conv_1',
          'sender_device_id': 'dev_1',
          'action_id': 'action_1',
          'expires_at': bad,
          'body': <String, Object?>{'text': 'hi'},
        });
        final bytes = utf8.encode(json);
        final padded = Uint8List(256);
        padded.setRange(0, 4, <int>[0x56, 0x41, 0x50, 0x31]);
        ByteData.sublistView(padded).setUint32(4, bytes.length, Endian.big);
        padded.setRange(8, 8 + bytes.length, bytes);
        expect(read(padded), isNull, reason: '$bad');
      }
    });

    test('the shorter of the sender and server times wins', () {
      expect(effectiveExpiryMillis(senderMs: 100, serverMs: 500), 100);
      expect(effectiveExpiryMillis(senderMs: 500, serverMs: 100), 100);
      expect(effectiveExpiryMillis(senderMs: 100), 100);
      // No sender expiry: today's behaviour, the server's time.
      expect(effectiveExpiryMillis(serverMs: 500), 500);
      expect(effectiveExpiryMillis(), isNull);
    });
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
