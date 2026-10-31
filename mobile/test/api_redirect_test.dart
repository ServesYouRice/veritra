// Custom secret headers (recovery token, claim token, crypto metadata) are
// not covered by dart:io's Authorization stripping on redirects, so ApiClient
// must never follow a 3xx on any request it opens.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';

/// Two loopback servers: [origin] answers every request with a redirect to
/// [other]; [other] only counts what reaches it.
class _RedirectPair {
  _RedirectPair._(this.origin, this.other);

  final HttpServer origin;
  final HttpServer other;
  final List<HttpRequest> hits = <HttpRequest>[];
  final List<String> originMethods = <String>[];

  String get originUrl => 'http://127.0.0.1:${origin.port}';
  String get otherUrl => 'http://127.0.0.1:${other.port}';

  static Future<_RedirectPair> start({
    required int status,
    required bool crossOrigin,
  }) async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final pair = _RedirectPair._(origin, other);
    other.listen((request) async {
      pair.hits.add(request);
      await request.drain<void>();
      request.response.statusCode = 200;
      await request.response.close();
    });
    origin.listen((request) async {
      pair.originMethods.add(request.method);
      // Consume the request body so an upload completes before the answer.
      await request.drain<void>();
      final target = crossOrigin ? pair.otherUrl : pair.originUrl;
      request.response
        ..statusCode = status
        ..headers.set(HttpHeaders.locationHeader, '$target/landing');
      await request.response.close();
    });
    return pair;
  }

  Future<void> close() async {
    await origin.close(force: true);
    await other.close(force: true);
  }
}

Matcher _redirectStatus(int status) => isA<ApiException>()
    .having((e) => e.statusCode, 'statusCode', status)
    .having((e) => e.toString(), 'text', isNot(contains('landing')));

Stream<List<int>> _body(int length) =>
    Stream<List<int>>.value(List<int>.filled(length, 7));

void main() {
  const recoveryToken = <int>[
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
  ];
  const metadata = <String, Object?>{'v': 1};

  for (final crossOrigin in <bool>[true, false]) {
    final where = crossOrigin ? 'cross-origin' : 'same-origin';
    // GET follows 301/302/303/307/308 in dart:io; POST follows only 303.
    for (final status in <int>[301, 302, 303, 307, 308]) {
      group('$where $status', () {
        late _RedirectPair pair;
        late ApiClient client;

        setUp(() async {
          pair = await _RedirectPair.start(
            status: status,
            crossOrigin: crossOrigin,
          );
          client = ApiClient(baseUrl: pair.originUrl);
        });
        tearDown(() async {
          client.close();
          await pair.close();
        });

        void expectNotFollowed() {
          expect(pair.hits, isEmpty, reason: 'the redirect was followed');
          expect(pair.originMethods, hasLength(1),
              reason: 'the origin saw a second request');
        }

        test('recoverEncryptedBackup does not forward the recovery token',
            () async {
          await expectLater(
            client.recoverEncryptedBackup(recoveryToken),
            throwsA(_redirectStatus(status)),
          );
          expectNotFollowed();
        });

        test('completeDeviceLinkClaim does not forward the claim token',
            () async {
          await expectLater(
            client.completeDeviceLinkClaim(
              'link_1',
              'claim-token',
              List<int>.filled(32, 1),
              List<int>.filled(32, 2),
            ),
            throwsA(_redirectStatus(status)),
          );
          expectNotFollowed();
        });

        test('a JSON request with a bearer token is not redirected', () async {
          await expectLater(
            client.exportAccountPage('token'),
            throwsA(_redirectStatus(status)),
          );
          expectNotFollowed();
        });

        test('downloadEncryptedAttachment is not redirected', () async {
          await expectLater(
            client.downloadEncryptedAttachment('token', 'att_1'),
            throwsA(_redirectStatus(status)),
          );
          expectNotFollowed();
        });
      });
    }
  }

  // dart:io turns a 303 answer to a POST into a GET that carries the
  // request's custom headers (X-Recovery-Token, X-Crypto-Metadata).
  for (final crossOrigin in <bool>[true, false]) {
    final where = crossOrigin ? 'cross-origin' : 'same-origin';
    group('$where 303 after a POST', () {
      late _RedirectPair pair;
      late ApiClient client;

      setUp(() async {
        pair = await _RedirectPair.start(status: 303, crossOrigin: crossOrigin);
        client = ApiClient(baseUrl: pair.originUrl);
      });
      tearDown(() async {
        client.close();
        await pair.close();
      });

      test('a JSON POST with a setup token is not redirected', () async {
        await expectLater(
          client.reserveOwnerEnrollment(setupToken: 'setup-secret'),
          throwsA(_redirectStatus(303)),
        );
        expect(pair.hits, isEmpty);
        expect(pair.originMethods, <String>['POST']);
      });

      test('uploadEncryptedAttachment is not redirected', () async {
        await expectLater(
          client.uploadEncryptedAttachment(
            'token',
            'conv_1',
            _body(16),
            ciphertextLength: 16,
            cryptoMetadata: metadata,
          ),
          throwsA(_redirectStatus(303)),
        );
        expect(pair.hits, isEmpty);
        expect(pair.originMethods, <String>['POST']);
      });

      test('uploadEncryptedBackup does not forward the recovery token',
          () async {
        await expectLater(
          client.uploadEncryptedBackup(
            'token',
            _body(16),
            ciphertextLength: 16,
            recoveryToken: recoveryToken,
            cryptoMetadata: metadata,
          ),
          throwsA(_redirectStatus(303)),
        );
        expect(pair.hits, isEmpty);
        expect(pair.originMethods, <String>['POST']);
      });
    });
  }
}
