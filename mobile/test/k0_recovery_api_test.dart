import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/account_recovery.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/transport_policy.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';

String b64(int value, int size) => base64Encode(List<int>.filled(size, value));

/// K0 recovery on the wire (server/internal/httpapi/
/// account_recovery_handlers.go), and the pure helpers around it.
void main() {
  group('wire', () {
    late HttpServer server;
    late String origin;
    late ApiClient api;
    late Future<void> Function(HttpRequest, Map<String, Object?>) handle;
    final seen = <String>[];

    setUp(() async {
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin = 'http://127.0.0.1:${server.port}';
      api = ApiClient(baseUrl: origin, transport: TransportPolicy.demo);
      server.listen((request) async {
        final text = await utf8.decoder.bind(request).join();
        seen.add('${request.method} ${request.uri.path}');
        await handle(
            request,
            text.isEmpty
                ? <String, Object?>{}
                : Map<String, Object?>.from(jsonDecode(text) as Map));
        await request.response.close();
      });
    });

    tearDown(() async {
      api.close();
      await server.close(force: true);
    });

    void reply(HttpRequest request, int status, Object body) {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
    }

    test('status and PUT carry only the public values', () async {
      handle = (request, body) async {
        expect(request.headers.value('authorization'), 'Bearer tok');
        if (request.method == 'PUT') {
          expect(body, <String, Object?>{
            'rk_auth_pub': b64(0xA1, 32),
            'rk_id': b64(0xB2, 16),
          });
        }
        reply(request, 200, <String, Object?>{
          'available': true,
          'configured': true,
          'rk_id': b64(0xB2, 16),
          'set_at': '2026-11-01T10:00:00Z',
          'pending_request': <String, Object?>{
            'id': 'arr_1',
            'device_name': 'Phone',
            'created_at': '2026-11-01T09:00:00Z',
            'ready_at': '2026-11-08T09:00:00Z',
          },
        });
      };
      final status = await api.recoveryKeyStatus('tok');
      expect(status.available, isTrue);
      expect(status.configured, isTrue);
      expect(status.setAt, DateTime.utc(2026, 11, 1, 10));
      expect(status.pending!.id, 'arr_1');
      expect(status.pending!.deviceName, 'Phone');
      expect(status.pending!.readyAt, DateTime.utc(2026, 11, 8, 9));
      await api.putRecoveryKey('tok',
          rkAuthPub: List<int>.filled(32, 0xA1),
          rkId: List<int>.filled(16, 0xB2));
      expect(seen, <String>[
        'GET /api/v1/account/recovery-key',
        'PUT /api/v1/account/recovery-key',
      ]);
    });

    test('recovery off: available false, and PUT answers 503', () async {
      handle = (request, body) async {
        if (request.method == 'GET') {
          reply(request, 200,
              <String, Object?>{'available': false, 'configured': false});
        } else {
          reply(request, 503,
              <String, Object?>{'error': 'recovery_not_configured'});
        }
      };
      final status = await api.recoveryKeyStatus('tok');
      expect(status.available, isFalse);
      expect(status.pending, isNull);
      await expectLater(
          api.putRecoveryKey('tok',
              rkAuthPub: List<int>.filled(32, 1),
              rkId: List<int>.filled(16, 1)),
          throwsA(isA<ApiException>()
              .having((e) => e.serverCode, 'code', 'recovery_not_configured')
              .having((e) => e.localizedMessage(englishL10n), 'message',
                  englishL10n.apiErrorRecoveryNotConfigured)));
    });

    test('reserve takes the username; the claim never does', () async {
      handle = (request, body) async {
        switch (request.uri.path) {
          case '/api/v1/account-recovery/enrollment':
            expect(body, <String, Object?>{'username': 'alice'});
            expect(request.headers.value('authorization'), isNull);
            reply(request, 201, <String, Object?>{
              'id': 'res_1',
              'account_id': 'acct_me',
              'device_id': 'dev_new',
              'challenge': b64(7, 32),
              'expires_at': '2026-11-01T10:10:00Z',
            });
          case '/api/v1/account-recovery/claim':
            expect(body, <String, Object?>{
              'enrollment_reservation_id': 'res_1',
              'password': 'pw',
              'device_name': 'Phone',
              'device_key_package': b64(3, 64),
              'signing_key': b64(4, 32),
              'challenge_signature': b64(5, 64),
              'recovery_signature': b64(6, 64),
            });
            request.response.headers.set('Cache-Control', 'no-store');
            reply(request, 202, <String, Object?>{
              'request_id': 'arr_1',
              'claim_token': 'claim-token',
              'device_secret': 'device-secret',
              'state': 'waiting',
              'ready_at': '2026-11-08T10:00:00Z',
            });
          default:
            fail('unexpected ${request.uri.path}');
        }
      };
      final reservation = await api.reserveAccountRecovery('alice');
      expect(reservation.accountId, 'acct_me');
      expect(reservation.deviceId, 'dev_new');
      final claim = await api.claimAccountRecovery(
        enrollment: reservation,
        password: 'pw',
        deviceName: 'Phone',
        credential: EnrollmentCredential(
          deviceKeyPackage: List<int>.filled(64, 3),
          signingKey: List<int>.filled(32, 4),
          challengeSignature: List<int>.filled(64, 5),
        ),
        recoverySignature: List<int>.filled(64, 6),
      );
      expect(claim.requestId, 'arr_1');
      expect(claim.claimToken, 'claim-token');
      expect(claim.deviceSecret, 'device-secret');
      expect(claim.readyAt, DateTime.utc(2026, 11, 8, 10));
    });

    test('a refused claim is one 401 with no detail', () async {
      handle = (request, body) async => reply(
          request, 401, <String, Object?>{'error': 'invalid_credentials'});
      await expectLater(
          api.claimAccountRecovery(
            enrollment: const EnrollmentReservation(
                id: 'res_1',
                accountId: 'acct',
                deviceId: 'dev',
                challenge: <int>[1]),
            password: 'pw',
            deviceName: 'Phone',
            credential: EnrollmentCredential(
                deviceKeyPackage: List<int>.filled(64, 1),
                signingKey: List<int>.filled(32, 1),
                challengeSignature: List<int>.filled(64, 1)),
            recoverySignature: List<int>.filled(64, 1),
          ),
          throwsA(
              isA<ApiException>().having((e) => e.statusCode, 'status', 401)));
    });

    test('status: waiting, completed with a token, then without', () async {
      final answers = <(int, Map<String, Object?>)>[
        (202, {'state': 'waiting', 'ready_at': '2026-11-08T10:00:00Z'}),
        (
          200,
          {
            'state': 'completed',
            'account': {'id': 'acct_me', 'username': 'alice', 'role': 'member'},
            'device': {'id': 'dev_new', 'account_id': 'acct_me'},
            'token': 'session-token',
          }
        ),
        (
          200,
          {
            'state': 'completed',
            'account': {'id': 'acct_me', 'username': 'alice', 'role': 'member'},
            'device': {'id': 'dev_new', 'account_id': 'acct_me'},
          }
        ),
        (410, {'error': 'recovery_cancelled'}),
      ];
      handle = (request, body) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/api/v1/account-recovery/arr_1/status');
        expect(request.headers.value('X-Veritra-Claim-Token'), 'claim-token');
        expect(request.headers.value('authorization'), isNull);
        final (status, json) = answers.removeAt(0);
        reply(request, status, json);
      };
      final waiting = await api.accountRecoveryStatus('arr_1', 'claim-token');
      expect(waiting.phase, AccountRecoveryPhase.waiting);
      expect(waiting.readyAt, DateTime.utc(2026, 11, 8, 10));
      final done = await api.accountRecoveryStatus('arr_1', 'claim-token');
      expect(done.phase, AccountRecoveryPhase.completed);
      expect(done.token, 'session-token');
      expect(done.accountId, 'acct_me');
      expect(done.deviceId, 'dev_new');
      expect(done.username, 'alice');
      final lost = await api.accountRecoveryStatus('arr_1', 'claim-token');
      expect(lost.phase, AccountRecoveryPhase.completedWithoutToken);
      expect(lost.token, isNull);
      await expectLater(
          api.accountRecoveryStatus('arr_1', 'claim-token'),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'status', 410)
              .having((e) => e.localizedMessage(englishL10n), 'message',
                  englishL10n.recoveryRequestEnded)));
    });

    test('a 200 that is not completed is refused', () async {
      handle = (request, body) async =>
          reply(request, 200, <String, Object?>{'state': 'waiting'});
      await expectLater(api.accountRecoveryStatus('arr_1', 'claim-token'),
          throwsA(isA<ApiResponseException>()));
    });

    test('cancel uses the session and the request path', () async {
      handle = (request, body) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/api/v1/account-recovery/arr_1/cancel');
        expect(request.headers.value('authorization'), 'Bearer tok');
        reply(request, 200, <String, Object?>{'state': 'cancelled'});
      };
      await api.cancelAccountRecovery('tok', 'arr_1');
      handle = (request, body) async => reply(
          request, 403, <String, Object?>{'error': 'recent_auth_required'});
      await expectLater(
          api.cancelAccountRecovery('tok', 'arr_1'),
          throwsA(isA<ApiException>()
              .having((e) => e.serverCode, 'code', 'recent_auth_required')));
    });
  });

  group('typed key', () {
    const display = 'ABCDEFGHJKMNPQRSTVWXYZ0123456789ABCDEFGHJKMNPQRSTVWX';

    test('separators from notes, PDFs and chats are dropped', () {
      for (final raw in <String>[
        groupRecoveryKey(display),
        groupRecoveryKey(display).replaceAll('-', ' '),
        groupRecoveryKey(display).replaceAll('-', '\t'),
        groupRecoveryKey(display).replaceAll('-', '\r\n'),
        groupRecoveryKey(display).replaceAll('-', '–'),
        groupRecoveryKey(display).replaceAll('-', '—'),
        groupRecoveryKey(display).replaceAll('-', '−'),
        groupRecoveryKey(display).replaceAll('-', '‑'),
        groupRecoveryKey(display).replaceAll('-', ' '),
        groupRecoveryKey(display).replaceAll('-', '​'),
        groupRecoveryKey(display).replaceAll('-', '－'),
        '﻿ $display \n',
      ]) {
        expect(normalizeRecoveryKeyInput(raw), display, reason: raw);
      }
    });

    test('full-width forms become ASCII; anything else is kept', () {
      expect(normalizeRecoveryKeyInput('Ａｂ３'), 'Ab3');
      // A real typo still fails the decode later.
      expect(normalizeRecoveryKeyInput('AB*C'), 'AB*C');
      expect(normalizeRecoveryKeyInput('ab_c'), 'ab_c');
    });

    test('groups of four', () {
      expect(groupRecoveryKey(display).split('-'), hasLength(13));
      expect(groupRecoveryKey(display).split('-').first, 'ABCD');
    });
  });

  group('persisted claim', () {
    PendingAccountRecovery claim() => PendingAccountRecovery(
          origin: 'https://chat.example.org',
          username: 'alice',
          accountId: 'acct_me',
          deviceId: 'dev_new',
          deviceName: 'Phone',
          requestId: 'arr_1',
          claimToken: 'claim-token',
          deviceSecret: 'device-secret',
          readyAt: DateTime.utc(2026, 11, 8, 10),
          mlsState: StoredCryptoState(
            counter: 1,
            stateKey: List<int>.filled(32, 9),
            sealedState: const <int>[1, 2, 3],
            changes: const <CryptoRecordChange>[
              CryptoRecordChange(
                  kind: 1, recordId: <int>[7], generation: 1, sealed: <int>[8]),
              CryptoRecordChange(
                  kind: 3, recordId: <int>[9], generation: 1, sealed: null),
            ],
          ),
        );

    test('round-trips every field', () {
      final decoded = PendingAccountRecovery.decode(
          claim().copyWith(needsLogin: true).encode())!;
      expect(decoded.origin, 'https://chat.example.org');
      expect(decoded.username, 'alice');
      expect(decoded.accountId, 'acct_me');
      expect(decoded.deviceId, 'dev_new');
      expect(decoded.requestId, 'arr_1');
      expect(decoded.claimToken, 'claim-token');
      expect(decoded.deviceSecret, 'device-secret');
      expect(decoded.readyAt, DateTime.utc(2026, 11, 8, 10));
      expect(decoded.needsLogin, isTrue);
      expect(decoded.mlsState.counter, 1);
      expect(decoded.mlsState.stateKey, List<int>.filled(32, 9));
      expect(decoded.mlsState.sealedState, <int>[1, 2, 3]);
      expect(decoded.mlsState.changes, hasLength(2));
      expect(decoded.mlsState.changes.first.sealed, <int>[8]);
      expect(decoded.mlsState.changes.last.sealed, isNull);
    });

    test('anything else is no claim', () {
      expect(PendingAccountRecovery.decode(null), isNull);
      expect(PendingAccountRecovery.decode(''), isNull);
      expect(PendingAccountRecovery.decode('{'), isNull);
      expect(PendingAccountRecovery.decode('{"v":2}'), isNull);
      final json = jsonDecode(claim().encode()) as Map<String, Object?>;
      json.remove('claim_token');
      expect(PendingAccountRecovery.decode(jsonEncode(json)), isNull);
    });
  });
}
