import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/app_payload.dart';

// L2-5 (docs/designs/L2-server-learns-less.md): the device_list_alert
// payload a device sends when it finds a leaf of its own account that its
// signed device list does not approve.

Uint8List _frame(Map<String, Object?> json) {
  final bytes = utf8.encode(jsonEncode(json));
  final result = Uint8List(((bytes.length + 8 + 255) ~/ 256) * 256);
  result.setRange(0, 4, [86, 65, 80, 49]);
  ByteData.sublistView(result).setUint32(4, bytes.length);
  result.setRange(8, 8 + bytes.length, bytes);
  return result;
}

void main() {
  final codec = AppPayloadCodec();
  final body = <String, Object?>{
    'account_id': 'acct_alice',
    'head_version': 3,
    'list_id': 'ab' * 32,
  };

  AppPayloadOutcome classify(Map<String, Object?> body,
          {int v = 2, bool hidden = true}) =>
      codec.classify(
          _frame({
            'v': v,
            'type': 'device_list_alert',
            'conversation_id': 'conv',
            'sender_device_id': 'dev',
            'action_id': 'action',
            if (hidden) 'hidden': true,
            'body': body,
          }),
          conversationId: 'conv',
          senderDeviceId: 'dev',
          actionId: 'action');

  test('device_list_alert is v2, hidden, unfranked and snake_case', () {
    const type = AppPayloadType.deviceListAlert;
    expect(type.wireName, 'device_list_alert');
    expect(type.sendsHidden, isTrue);
    expect(FrankingPolicy.unfrankedPayloadTypes, contains(type.name));
    final framed = codec.encode(
        type: type,
        conversationId: 'conv',
        senderDeviceId: 'dev',
        actionId: 'action',
        body: body,
        hidden: true);
    final length = ByteData.sublistView(framed).getUint32(4);
    final wire = jsonDecode(utf8.decode(framed.sublist(8, 8 + length))) as Map;
    expect(wire['v'], 2);
    expect(wire['hidden'], isTrue);
    expect(wire['type'], 'device_list_alert');
    final outcome = classify(body);
    expect(outcome, isA<DecodedAppPayload>());
    expect(
        const FrankingPolicy(acceptUnfranked: false).acceptsUnfranked(outcome),
        isTrue);
  });

  test('an old (v1) framing or a malformed body is refused', () {
    expect(classify(body, v: 1), isA<InvalidAppPayload>());
    for (final bad in <Map<String, Object?>>[
      {...body, 'head_version': 0},
      {...body, 'head_version': '3'},
      {...body, 'list_id': 'AB' * 32},
      {...body, 'list_id': 'ab' * 31},
      {...body, 'account_id': ''},
      {...body, 'account_id': 'a' * 129},
      {...body, 'extra': 1},
      {...body}..remove('list_id'),
    ]) {
      expect(classify(bad), isA<InvalidAppPayload>(), reason: '$bad');
      expect(isValidDeviceListAlertBody(bad), isFalse, reason: '$bad');
    }
    expect(isValidDeviceListAlertBody(body), isTrue);
  });
}
