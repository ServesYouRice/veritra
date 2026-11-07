// The v2 `ApiClient.completeDeviceLinkClaim` transcript binding. The AppState
// half of the v2 link is gone (K2 v3 replaced it; see
// device_link_v3_flow_test.dart); the client call stays for v2 links.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';

List<int> _bytes(int value) => List<int>.filled(32, value);

void main() {
  group('ApiClient.completeDeviceLinkClaim', () {
    late HttpServer server;
    late ApiClient client;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
    });

    tearDown(() async {
      client.close();
      await server.close(force: true);
    });

    Future<void> answer(int status, Map<String, Object?> body) async {
      final request = await server.first;
      expect(request.uri.path, '/api/v1/device-links/link/claim-status');
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    }

    test('throws on a transcript_mismatch answer', () async {
      final completion = client.completeDeviceLinkClaim(
          'link', 'claim-token', _bytes(7), _bytes(9));
      final refused = expectLater(
          completion,
          throwsA(
              isA<ApiException>().having((e) => e.statusCode, 'status', 409)));
      await answer(409, <String, Object?>{'error': 'transcript_mismatch'});
      await refused;
    });

    test('throws when the session carries another transcript', () async {
      final completion = client.completeDeviceLinkClaim(
          'link', 'claim-token', _bytes(7), _bytes(9));
      final refused = expectLater(
          completion,
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'status', 409)
              .having((e) => e.serverCode, 'code', 'transcript_mismatch')));
      final transcript = _bytes(7)..[31] = 6;
      await answer(200, <String, Object?>{
        'token': 'linked',
        'transcript_hash': base64Encode(transcript),
        'approval_tag': base64Encode(_bytes(9)),
        'account': <String, Object?>{'id': 'acct'},
        'device': <String, Object?>{'id': 'dev'},
      });
      await refused;
    });
  });
}
