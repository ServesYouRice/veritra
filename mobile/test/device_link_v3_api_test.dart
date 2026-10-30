import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/device_link_v3_models.dart';
import 'package:private_messenger/core/models.dart';

String hash(String c) => List.filled(64, c).join();
String binary(int n, [int size = 32]) => base64Encode(List.filled(size, n));
final claimToken = base64Url.encode(List.filled(32, 11)).replaceAll('=', '');

Map<String, Object?> context(String origin, {String state = 'claimed'}) => {
      'id': 'dlink_test',
      'protocol_version': deviceLinkV3Protocol,
      'state': state,
      'account_id': 'acct_test',
      'created_by_device_id': 'dev_old',
      'server_origin': origin,
      'link_nonce': binary(1),
      'existing_signing_key': binary(2),
      'created_at': '2026-10-28T10:00:00Z',
      'expires_at': '2026-10-28T10:10:00Z',
      if (state == 'pending') 'code': hash('a'),
      if (state != 'pending') ...{
        'claimed_device_id': 'dev_new',
        'claimed_device_name': 'New phone',
        'claimed_signing_key': binary(3),
        'transfer_public_key': binary(4),
        'transcript_hash': binary(5),
        'claim_tag': binary(6),
        'claim_request_hash': hash('d'),
        'claimed_at': '2026-10-28T10:01:00Z',
      },
      if (state == 'approved' || state == 'consumed') ...{
        'approval_tag': binary(7),
        'approved_at': '2026-10-28T10:02:00Z',
        'transfer_expires_at': '2026-11-04T10:02:00Z',
      },
      if (state == 'consumed') 'completed_at': '2026-10-28T10:03:00Z',
    };

Map<String, Object?> signedClaim(String origin) => {
      'code': hash('a'),
      'protocol_version': deviceLinkV3Protocol,
      'server_origin': origin,
      'reservation_request_id': hash('b'),
      'enrollment_reservation_id': 'dlink_test',
      'device_name': 'New phone',
      'device_key_package': binary(8, 64),
      'signing_key': binary(3),
      'transfer_public_key': binary(4),
      'transcript_hash': binary(5),
      'claim_tag': binary(6),
      'claim_token_hash': hash('1'),
      'device_secret_hash': hash('2'),
      'initial_session_token_hash': hash('3'),
      'challenge_signature': binary(9, 64),
    };

Map<String, Object?> receipt(String origin) => {
      'completion': <String, Object?>{
        'link_id': 'dlink_test',
        'account_id': 'acct_test',
        'device_id': 'dev_new',
        'server_origin': origin,
        'claim_request_hash': hash('d'),
        'transcript_hash': binary(5),
        'initial_session_token_hash': hash('3'),
        'completed_at': '2026-10-28T10:03:00Z',
      },
      'approval_tag': binary(7),
    };

void main() {
  late HttpServer server;
  late String origin;
  late ApiClient api;
  late Session owner;
  late Future<void> Function(HttpRequest) handle;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    api = ApiClient(baseUrl: origin);
    owner = Session(
        baseUrl: origin,
        token: 'source-token',
        accountId: 'acct_test',
        deviceId: 'dev_old',
        username: 'owner');
    server.listen((r) async {
      await handle(r);
      await r.response.close();
    });
  });
  tearDown(() async {
    api.close();
    await server.close(force: true);
  });

  test('v3 wire keeps credentials client-owned and completion receipt-only',
      () async {
    final methods = <String>[];
    handle = (r) async {
      methods.add('${r.method} ${r.uri.path}');
      final text = await utf8.decoder.bind(r).join();
      final body = text.isEmpty
          ? <String, Object?>{}
          : Map<String, Object?>.from(jsonDecode(text) as Map);
      expect(body.keys, isNot(contains('device_secret')));
      expect(body.keys, isNot(contains('session_token')));
      expect(body.keys, isNot(contains('claim_token')));
      Object response;
      switch (r.uri.path) {
        case '/api/v1/device-links/v3':
          expect(r.headers.value('authorization'), 'Bearer source-token');
          expect(body['server_origin'], origin);
          response = {'device_link': context(origin, state: 'pending')};
        case '/api/v1/device-links/v3/claim-enrollment':
          expect(body['reservation_request_id'], hash('b'));
          response = {
            'id': 'dlink_test',
            'account_id': 'acct_test',
            'device_id': 'dev_new',
            'challenge': binary(10),
            'expires_at': '2026-10-28T10:10:00Z',
            'protocol_version': deviceLinkV3Protocol,
            'link_nonce': binary(1),
            'existing_device_id': 'dev_old',
            'existing_signing_key': binary(2)
          };
        case '/api/v1/device-links/v3/claim':
          expect(body, signedClaim(origin));
          response = {'device_link': context(origin)};
        case '/api/v1/device-links/v3/dlink_test/claim-status':
          expect(r.method, 'GET');
          expect(body, isEmpty);
          expect(r.headers.value('X-Veritra-Claim-Token'), claimToken);
          response = {'device_link': context(origin, state: 'approved')};
        case '/api/v1/device-links/v3/dlink_test/approve':
          expect(body['claim_request_hash'], hash('d'));
          expect(body['approval_tag'], binary(7));
          response = {
            'device_link': context(origin, state: 'approved'),
            'device': {}
          };
        case '/api/v1/device-links/v3/dlink_test/complete':
          expect(r.method, 'POST');
          expect(r.headers.value('X-Veritra-Claim-Token'), claimToken);
          expect(body['initial_session_token_hash'], hash('3'));
          response = receipt(origin);
        default:
          response = r.method == 'DELETE'
              ? {'state': 'revoked'}
              : {'device_link': context(origin)};
      }
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode(response));
    };
    await api.createDeviceLinkV3(owner, hash('a'));
    final reservation = await api.reserveDeviceLinkV3(hash('a'), hash('b'));
    expect(reservation.fields['device_id'], 'dev_new');
    final frozen = FrozenDeviceLinkV3Claim.fromJson(signedClaim(origin),
        requestHash: hash('d'));
    final claimed = await api.submitDeviceLinkV3Claim(frozen, reservation);
    await api.deviceLinkV3(owner, claimed.id);
    final approved =
        await api.approveDeviceLinkV3(owner, claimed, List.filled(32, 7));
    await api.deviceLinkV3ClaimStatus(approved, claimToken);
    final completed =
        await api.completeDeviceLinkV3(approved, claimToken, hash('3'));
    expect(completed.fields['device_id'], 'dev_new');
    expect(completed.approvalTag, List.filled(32, 7));
    await api.cancelDeviceLinkV3(owner, claimed.id);
    expect(methods.length, 8);
  });

  test('completion rejects substituted context, tokens and malformed MACs',
      () async {
    for (final key in [
      'link_id',
      'account_id',
      'device_id',
      'server_origin',
      'claim_request_hash',
      'transcript_hash',
      'initial_session_token_hash',
      'token',
      'approval_tag'
    ]) {
      handle = (r) async {
        await r.drain<void>();
        final json = receipt(origin);
        if (key == 'approval_tag') {
          json[key] = binary(1, 31);
        } else {
          (json['completion'] as Map<String, Object?>)[key] = switch (key) {
            'server_origin' => 'https://other.example',
            'claim_request_hash' || 'initial_session_token_hash' => hash('f'),
            'transcript_hash' => binary(20),
            _ => 'substituted',
          };
        }
        r.response.write(jsonEncode(json));
      };
      await expectLater(
          api.completeDeviceLinkV3(
              DeviceLinkV3Record.fromJson(context(origin, state: 'approved')),
              claimToken,
              hash('3')),
          throwsA(isA<ApiResponseException>()),
          reason: key);
    }
  });

  test('claim acknowledgement pins every durable reservation identity field',
      () async {
    final reservation = DeviceLinkV3Reservation.fromJson({
      'id': 'dlink_test',
      'account_id': 'acct_test',
      'device_id': 'dev_new',
      'challenge': binary(10),
      'expires_at': '2026-10-28T10:10:00Z',
      'protocol_version': deviceLinkV3Protocol,
      'link_nonce': binary(1),
      'existing_device_id': 'dev_old',
      'existing_signing_key': binary(2),
    });
    for (final key in [
      'account_id',
      'created_by_device_id',
      'claimed_device_id',
      'existing_signing_key',
      'link_nonce',
      'expires_at',
      'claim_request_hash'
    ]) {
      handle = (r) async {
        await r.drain<void>();
        final json = context(origin);
        json[key] = switch (key) {
          'existing_signing_key' || 'link_nonce' => binary(19),
          'expires_at' => '2026-10-28T10:11:00Z',
          'claim_request_hash' => hash('e'),
          _ => 'changed_identity',
        };
        r.response.write(jsonEncode({'device_link': json}));
      };
      await expectLater(
          api.submitDeviceLinkV3Claim(
              FrozenDeviceLinkV3Claim.fromJson(signedClaim(origin),
                  requestHash: hash('d')),
              reservation),
          throwsA(isA<ApiResponseException>()),
          reason: key);
    }
  });

  test('approved polling rejects regression and changed fixed approval context',
      () async {
    final expected =
        DeviceLinkV3Record.fromJson(context(origin, state: 'approved'));
    for (final change in ['regression', 'tag', 'deadline']) {
      handle = (r) async {
        await r.drain<void>();
        final json = context(origin,
            state: change == 'regression' ? 'claimed' : 'approved');
        if (change == 'tag') json['approval_tag'] = binary(18);
        if (change == 'deadline') {
          json['approved_at'] = '2026-10-28T10:03:00Z';
          json['transfer_expires_at'] = '2026-11-04T10:03:00Z';
        }
        r.response.write(jsonEncode({'device_link': json}));
      };
      await expectLater(api.deviceLinkV3ClaimStatus(expected, claimToken),
          throwsA(isA<ApiResponseException>()),
          reason: change);
    }
  });

  test('claim credential cannot follow redirects to a different origin',
      () async {
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => other.close(force: true));
    var leaked = 0;
    other.listen((r) async {
      leaked++;
      await r.response.close();
    });
    handle = (r) async {
      r.response.statusCode = HttpStatus.temporaryRedirect;
      r.response.headers
          .set('location', 'http://127.0.0.1:${other.port}/capture');
    };
    await expectLater(
        api.deviceLinkV3ClaimStatus(
            DeviceLinkV3Record.fromJson(context(origin)), claimToken),
        throwsA(isA<ApiException>()));
    expect(leaked, 0);
  });

  test('invalid inputs fail before requests; decoder exceptions omit values',
      () async {
    var requests = 0;
    handle = (r) async {
      requests++;
    };
    await expectLater(
        api.deviceLinkV3(owner, '../other'), throwsFormatException);
    await expectLater(api.reserveDeviceLinkV3('raw-secret', hash('b')),
        throwsFormatException);
    await expectLater(
        api.createDeviceLinkV3(
            const Session(
                baseUrl: 'https://elsewhere.example',
                token: 'token',
                accountId: 'acct_test',
                deviceId: 'dev_old',
                username: 'owner'),
            hash('a')),
        throwsFormatException);
    expect(requests, 0);
    for (final mutate in <void Function(Map<String, Object?>)>[
      (j) => j['link_nonce'] = 'sensitive-invalid-binary',
      (j) => j['protocol_version'] = 'veritra-device-link-v2',
      (j) => j['session_token'] = 'forbidden',
      (j) => j['expires_at'] = '2026-10-28T09:00:00Z',
    ]) {
      final json = context(origin);
      mutate(json);
      try {
        DeviceLinkV3Record.fromJson(json);
        fail('accepted malformed context');
      } on FormatException catch (e) {
        expect(e.source, isNull);
        expect(e.toString(), isNot(contains('sensitive-invalid-binary')));
      }
    }
  });
}
