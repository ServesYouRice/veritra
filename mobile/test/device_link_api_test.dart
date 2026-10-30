import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/models.dart';

void main() {
  test('claim-token requests refuse redirects to another server', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var redirectedRequests = 0;
    destination.listen((request) async {
      redirectedRequests++;
      request.response.statusCode = 500;
      await request.response.close();
    });
    final client = ApiClient(baseUrl: 'http://127.0.0.1:${source.port}');
    addTearDown(() async {
      client.close();
      await source.close(force: true);
      await destination.close(force: true);
    });
    final incoming = source.first;
    final result = client.completeDeviceLinkClaim(
        'link', 'secret-claim-token', List.filled(32, 7), List.filled(32, 9));
    final refused = expectLater(
        result,
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 302)));
    final request = await incoming;
    request.response.statusCode = 302;
    request.response.headers.set(HttpHeaders.locationHeader,
        'http://127.0.0.1:${destination.port}/leak');
    await request.response.close();
    await refused;
    expect(redirectedRequests, 0);
  });

  test('claim sends only the locator, public transcript and claim tag',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });
    final request = server.first;
    final claiming = client.claimDeviceLink(
      code: 'a' * 64,
      deviceName: 'Tablet',
      enrollment: const EnrollmentReservation(
          id: 'link', accountId: 'acct', deviceId: 'dev', challenge: [1]),
      credential: const EnrollmentCredential(
          deviceKeyPackage: [1], signingKey: [2], challengeSignature: [3]),
      verification: DeviceLinkVerification(
          transcriptHash: List.filled(32, 7),
          sas: '65432101',
          claimTag: List.filled(32, 8),
          approvalTag: List.filled(32, 9)),
    );
    final received = await request;
    final body = jsonDecode(await utf8.decoder.bind(received).join()) as Map;
    expect(body.keys.toSet(), {
      'code',
      'device_name',
      'enrollment_reservation_id',
      'device_key_package',
      'signing_key',
      'challenge_signature',
      'transcript_hash',
      'claim_tag'
    });
    expect(body['code'], 'a' * 64);
    expect(base64Decode(body['claim_tag'] as String), List.filled(32, 8));
    received.response.headers.contentType = ContentType.json;
    received.response.write(jsonEncode({
      'device_link': {
        'id': 'link',
        'state': 'claimed',
        'expires_at': '2030-01-01T00:00:00Z'
      },
      'claim_token': 'token',
      'device_secret': 'device-secret'
    }));
    await received.response.close();
    await claiming;
  });

  for (final mode in ['missing', 'truncated', 'reflected', 'wrong', 'valid']) {
    test('completion checks $mode approval tag before returning a session',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
      addTearDown(() async {
        client.close();
        await server.close(force: true);
      });
      final request = server.first;
      final completion = client.completeDeviceLinkClaim(
          'link', 'claim-token', List.filled(32, 7), List.filled(32, 9));
      final expectation = mode == 'valid'
          ? expectLater(completion, completionOfSession())
          : expectLater(completion, throwsA(anything));
      final received = await request;
      final response = <String, Object?>{
        'token': 'linked',
        'transcript_hash': base64Encode(List.filled(32, 7)),
        'account': {'id': 'acct', 'username': 'user', 'role': 'member'},
        'device': {'id': 'dev'}
      };
      if (mode != 'missing')
        response['approval_tag'] = base64Encode(List.filled(
            mode == 'truncated' ? 31 : 32,
            mode == 'valid'
                ? 9
                : mode == 'reflected'
                    ? 8
                    : 10));
      received.response.headers.contentType = ContentType.json;
      received.response.write(jsonEncode(response));
      await received.response.close();
      await expectation;
    });
  }
}

Matcher completionOfSession() =>
    completion(isA<Session>().having((s) => s.token, 'token', 'linked'));
