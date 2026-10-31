// The pending-changes read carries the server's response-level overall-cut
// flag (D68), and stays a plain list of items for every other caller.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';

Future<List<MlsPendingChange>> _readAgainst(Map<String, Object?> body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    await utf8.decodeStream(request);
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  });
  final client =
      ApiClient(baseUrl: 'http://${server.address.address}:${server.port}');
  addTearDown(client.close);
  return client.mlsPendingChanges('token');
}

Map<String, Object?> _item(String id, {bool truncated = false}) =>
    <String, Object?>{
      'conversation_id': id,
      'epoch': 2,
      'add': const <Object?>[],
      'remove': const <Object?>[],
      'truncated': truncated,
    };

void main() {
  test('the overall-cut flag is read next to the items', () async {
    for (final cut in <bool>[true, false]) {
      final changes = await _readAgainst(<String, Object?>{
        'pending_changes': <Object?>[_item('conv_a', truncated: true)],
        'list_truncated': cut,
      });
      expect(changes, isA<MlsPendingChanges>());
      expect((changes as MlsPendingChanges).cut, cut);
      expect(changes.single.conversationId, 'conv_a');
      expect(changes.single.truncated, isTrue);
    }
  });

  test('an older server without the flag leaves it unknown', () async {
    final changes = await _readAgainst(<String, Object?>{
      'pending_changes': <Object?>[_item('conv_a')],
    });
    expect((changes as MlsPendingChanges).cut, isNull);
    expect(changes.length, 1);
  });
}
