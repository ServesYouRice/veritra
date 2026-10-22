// T44A: error taxonomy, bounded bodies, casts, timestamps and pagination.
// Run through test/api_contract_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/errors.dart';
import 'package:private_messenger/core/models.dart';

const _fixtureDir = 'test/fixtures/api/v1';

Map<String, Object?> _fixture(String name) => Map<String, Object?>.from(
    jsonDecode(File('$_fixtureDir/$name').readAsStringSync()) as Map);

Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value! as Map);

/// Every error code the Go server writes, read from its sources the way a
/// reviewer would grep them.
Set<String> _serverErrorCodes() {
  final root = Directory('../server/internal');
  final call = RegExp(r'write(?:Retry)?Error\([^)]*"([a-z0-9_]+)"');
  final inline = RegExp(r'"error":\s*"([a-z0-9_]+)"');
  final codes = <String>{};
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File ||
        !entity.path.endsWith('.go') ||
        entity.path.endsWith('_test.go')) {
      continue;
    }
    final source = entity.readAsStringSync();
    for (final pattern in <RegExp>[call, inline]) {
      for (final match in pattern.allMatches(source)) {
        codes.add(match.group(1)!);
      }
    }
  }
  return codes;
}

/// A loopback server whose responses are scripted per test.
class _ScriptedServer {
  _ScriptedServer._(this._server);

  final HttpServer _server;
  final List<Uri> requests = <Uri>[];

  String get baseUrl => 'http://${_server.address.address}:${_server.port}';

  static Future<_ScriptedServer> start(
      FutureOr<void> Function(HttpRequest request, int index) handle) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final scripted = _ScriptedServer._(server);
    server.listen((request) async {
      final index = scripted.requests.length;
      scripted.requests.add(request.uri);
      try {
        await request.drain<void>();
        await handle(request, index);
        await request.response.close();
      } catch (_) {
        // The client may stop reading early on purpose; that is the test.
      }
    });
    return scripted;
  }

  Future<void> close() => _server.close(force: true);
}

Future<ApiClient> _clientFor(_ScriptedServer server) async {
  final client = ApiClient(baseUrl: server.baseUrl);
  addTearDown(server.close);
  addTearDown(client.close);
  return client;
}

void _respondJson(HttpRequest request, Object? body) {
  request.response
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
}

Matcher _hides(String sentinel) => predicate<Object>(
      (error) =>
          !error.toString().contains(sentinel) &&
          !describeError(error).contains(sentinel),
      'an error whose text does not contain "$sentinel"',
    );

void boundedDecodingTests() {
  test('every server error code has a typed client mapping', () {
    final server = _serverErrorCodes();
    expect(server.length, greaterThan(50));
    expect(server.difference(apiErrorKinds.keys.toSet()), isEmpty,
        reason: 'server codes without a client mapping');
    expect(apiErrorKinds.keys.toSet().difference(server), isEmpty,
        reason: 'client mappings for codes the server no longer writes');
  });

  test('versioned error-code fixture matches the client mapping', () {
    final fixture = _fixture('error_codes.json');
    expect(fixture['contract_version'], apiErrorContractVersion);
    expect(_map(fixture['codes']), <String, Object?>{
      for (final entry in apiErrorKinds.entries) entry.key: entry.value.name,
    });
  });

  test('every mapped code yields a sentence that hides the code', () {
    for (final entry in apiErrorKinds.entries) {
      final error = ApiException(400, jsonEncode({'error': entry.key}));
      expect(error.serverCode, entry.key);
      expect(error.kind, entry.value);
      expect(error.message, isNotEmpty);
      expect(error.message, isNot(contains(entry.key)), reason: entry.key);
      expect(describeError(error), error.message);
    }
  });

  test('fixture error bodies decode to bounded, typed errors', () {
    final errors = _map(_fixture('responses.json')['errors']);
    ApiException decode(String name) {
      final row = _map(errors[name]);
      return ApiException(row['status']! as int, row['body']! as String);
    }

    expect(decode('plain').kind, ApiErrorKind.permission);
    final epoch = decode('with_int_field');
    expect(epoch.serverCode, 'mls_epoch_conflict');
    expect(epoch.intField('epoch'), 12);
    final recovery = decode('recovery');
    expect(recovery.serverCode, 'device_recovery_required');
    expect(recovery.intField('latest_event_id'), 90);
    final limiter = decode('rate_limiter_text');
    expect(limiter.serverCode, isNull);
    expect(limiter.kind, ApiErrorKind.rateLimited);
    expect(limiter.retryable, isTrue);
    final unknown = decode('unknown_code');
    expect(unknown.serverCode, 'some_future_code');
    expect(unknown.kind, ApiErrorKind.invalidRequest);
    expect(unknown.message, isNot(contains('some_future_code')));
    final hostile = decode('hostile_code');
    expect(hostile.serverCode, isNull);
    expect(hostile.toString(), isNot(contains('script')));
    expect(ApiException(500, '{"error":"${'a' * 5000}"}').serverCode, isNull);
  });

  test('error bodies are read to a bound and never kept', () async {
    const sentinel = 'SENTINEL_CIPHERTEXT_BODY';
    final server = await _ScriptedServer.start((request, index) {
      request.response.statusCode = index == 0 ? 500 : 403;
      if (index == 0) {
        // A binary error page far above the error-body bound.
        request.response.add(List<int>.generate(512 * 1024, (i) => i % 256));
      } else {
        request.response.write(jsonEncode(<String, Object?>{
          'error': 'forbidden',
          'detail': sentinel,
        }));
      }
    });
    final client = await _clientFor(server);

    await expectLater(
      client.conversations('token'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 500)
          .having((e) => e.serverCode, 'serverCode', isNull)
          .having((e) => e.kind, 'kind', ApiErrorKind.server)),
    );
    await expectLater(
      client.listInvites('token'),
      throwsA(isA<ApiException>()
          .having((e) => e.serverCode, 'serverCode', 'forbidden')
          .having((e) => e, 'text', _hides(sentinel))),
    );
  });

  test('download and recovery error bodies are bounded and typed', () async {
    final server = await _ScriptedServer.start((request, index) {
      request.response.statusCode = 404;
      request.response.write('{"error":"blob_not_found"}');
      request.response.add(List<int>.filled(256 * 1024, 0x20));
    });
    final client = await _clientFor(server);
    await expectLater(
      client.downloadEncryptedAttachment('token', 'att_1'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 404)
          .having((e) => e.kind, 'kind', ApiErrorKind.notFound)),
    );
    await expectLater(
      client.recoverEncryptedBackup(List<int>.filled(32, 1)),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
    );
  });

  test('downloads above the ciphertext cap fail while streaming', () async {
    final server = await _ScriptedServer.start((request, index) async {
      if (index == 0) {
        // Announce more than the cap; the client must refuse it on headers.
        request.response.contentLength =
            ApiClient.maxAttachmentCiphertextBytes + 1;
        request.response.add(List<int>.filled(64, 7));
        await request.response.flush();
        return;
      }
      request.response.add(List<int>.filled(64, 7));
    });
    final client = await _clientFor(server);
    await expectLater(
      client.downloadEncryptedAttachment('token', 'att_1'),
      throwsA(isA<ApiResponseTooLargeException>()),
    );
    // A resumed recovery may only bring the backup up to its cap.
    final stream = await client.recoverEncryptedBackup(
      List<int>.filled(32, 1),
      startOffset: ApiClient.maxBackupCiphertextBytes - 10,
    );
    await expectLater(
      stream.drain<void>(),
      throwsA(isA<ApiResponseTooLargeException>()),
    );
  });

  test('malformed success bodies become one typed, body-free error', () async {
    const sentinel = 'SENTINEL_RESPONSE_TEXT';
    final bodies = <Object>[
      'not json $sentinel',
      <Object?>[sentinel],
      <String, Object?>{'conversations': sentinel},
      <String, Object?>{
        'conversations': <Object?>[
          <String, Object?>{'id': 42, 'kind': sentinel},
        ],
      },
      <String, Object?>{
        'conversations': <Object?>[sentinel],
      },
      List<int>.generate(64, (i) => 0x80 + i),
    ];
    final server = await _ScriptedServer.start((request, index) {
      final body = bodies[index];
      request.response.headers.contentType = ContentType.json;
      if (body is String) {
        request.response.write(body);
      } else if (body is List<int>) {
        request.response.add(body);
      } else {
        request.response.write(jsonEncode(body));
      }
    });
    final client = await _clientFor(server);
    for (var i = 0; i < bodies.length; i++) {
      await expectLater(
        client.conversations('token'),
        throwsA(allOf(isA<ApiResponseException>(), _hides(sentinel))),
        reason: 'body $i',
      );
    }
    expect(describeError(const ApiResponseException()),
        'The server returned an unexpected response.');
  });

  test('oversized success bodies are refused', () async {
    final server = await _ScriptedServer.start((request, index) {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"conversations":[],"pad":"');
      request.response.add(List<int>.filled(3 * 1024 * 1024, 0x61));
      request.response.write('"}');
    });
    final client = await _clientFor(server);
    await expectLater(client.conversations('token'),
        throwsA(isA<ApiResponseTooLargeException>()));
  });

  test('list pagination has a page cap and rejects a stuck cursor', () async {
    var stuck = true;
    final server = await _ScriptedServer.start((request, index) {
      final offset = stuck ? 0 : index * 100;
      _respondJson(request, <String, Object?>{
        'conversations': <Object?>[
          for (var i = 0; i < 100; i++)
            <String, Object?>{'id': 'conv_${offset + i}', 'kind': 'group'},
        ],
      });
    });
    final client = await _clientFor(server);

    await expectLater(
        client.conversations('token'), throwsA(isA<ApiResponseException>()));
    expect(server.requests, hasLength(2));

    stuck = false;
    server.requests.clear();
    final all = await client.conversations('token');
    expect(server.requests, hasLength(ApiClient.maxListPages));
    expect(all, hasLength(ApiClient.maxListPages * 100));
  });

  test('page limits are clamped to what the server serves', () async {
    final server = await _ScriptedServer.start((request, index) {
      _respondJson(request, <String, Object?>{});
    });
    final client = await _clientFor(server);
    await client.syncEvents('token', limit: 5000);
    await client.mlsMessages('token', limit: 0);
    await client.listMessagePage('token', 'conv_1', limit: 1000);
    await client.searchMetadata('token', 'q', limit: 500, offset: -4);
    expect(server.requests.map((uri) => uri.queryParameters['limit']),
        <String>['200', '1', '200', '50']);
    expect(server.requests.last.queryParameters['offset'], '0');
  });

  test('versioned response fixtures decode with bounded timestamps', () {
    final fixture = _fixture('responses.json');
    expect(fixture['contract_version'], apiErrorContractVersion);
    final rows = (_map(fixture['conversations_page'])['conversations']! as List)
        .map((row) => Conversation.fromJson(_map(row)))
        .toList();
    expect(
        rows.map((c) => c.id), <String>['conv_dm', 'conv_group', 'conv_far']);
    expect(
        rows[0].lastMessageAt, DateTime.utc(2026, 6, 2, 12, 30, 0, 123, 456));
    expect(rows[0].peerUsername, 'peer');
    expect(rows[1].createdAt, DateTime.utc(2026, 6, 1, 8));
    expect(rows[1].createdAt!.isUtc, isTrue);
    expect(rows[1].lastMessageAt, isNull);
    expect(rows[2].createdAt, isNull, reason: 'year out of range');
    expect(rows[2].lastMessageAt, isNull, reason: 'over-long timestamp');

    final device = Device.fromJson(
        _map((_map(fixture['devices_page'])['devices']! as List)[0]));
    expect(device.lastSeenAt, DateTime.utc(2026, 6, 2, 10));

    final message = ReceivedMessageEnvelope.fromJson(
        _map((_map(fixture['message_page'])['messages']! as List)[0]));
    expect(message.ciphertext, <int>[1, 2, 3]);
    expect(message.expiresAt, DateTime.utc(2026, 6, 9, 12, 30));

    final event = SyncEvent.fromJson(
        _map((_map(fixture['sync_events'])['events']! as List)[0]));
    expect(event.id, 7);

    final mls = _map(_map(fixture['mls_message'])['mls_message']);
    expect(MlsMessage.fromJson(mls).syncEventId, 8);
    for (final bad in <Object?>[
      'yesterday',
      '+275760-09-13T00:00:00.000Z',
      '2026-06-01T10:00:00.${'0' * 64}Z',
      null,
      12,
    ]) {
      expect(
        () => MlsMessage.fromJson(<String, Object?>{...mls, 'created_at': bad}),
        throwsA(isA<FormatException>()),
        reason: '$bad',
      );
    }
  });

  test('invalid base64 never echoes the field into the error', () {
    const sentinel = 'SENTINEL_CIPHERTEXT!!';
    expect(
      () => ReceivedMessageEnvelope.fromJson(<String, Object?>{
        'id': 'm',
        'conversation_id': 'c',
        'sender_account_id': 'a',
        'sender_device_id': 'd',
        'idempotency_key': 'i',
        'ciphertext': sentinel,
        'crypto_protocol': 'p',
        'created_at': '2026-06-01T00:00:00Z',
      }),
      throwsA(isA<FormatException>()
          .having((e) => e.toString(), 'text', isNot(contains(sentinel)))),
    );
  });

  test('implementation errors map to safe sentences', () {
    const generic = 'Something went wrong. Please try again.';
    expect(describeError(StateError('No element')), generic);
    expect(describeError(StateError('sync events are not strictly ordered')),
        generic);
    expect(describeError(StateError('attachments are unavailable')),
        'This action is unavailable in this build.');
    const sentence = 'Password login requires this device to be linked first.';
    expect(describeError(StateError(sentence)), sentence);
    expect(describeError(const ApiResponseTooLargeException()),
        'The server returned an unexpected response.');
    final client = ApiClient(baseUrl: 'https://example.test');
    addTearDown(client.close);
    expect(
      () => client.recoverEncryptedBackup(List<int>.filled(5, 0x41)),
      throwsA(isA<ArgumentError>()
          .having((e) => e.toString(), 'text', isNot(contains('65')))),
    );
  });

  test('ciphertext pages over the cap are re-requested smaller', () async {
    // A 5 MB MLS payload is legal (the server allows 4 MiB raw), so a
    // single item must fit and a page of several must shrink, not loop.
    final payload = base64Encode(List<int>.filled(4 * 1024 * 1024, 1));
    final server = await _ScriptedServer.start((request, index) {
      final limit = int.parse(request.uri.queryParameters['limit']!);
      _respondJson(request, <String, Object?>{
        'mls_messages': <Object?>[
          // Three items already exceed the cap; more would only slow the test.
          for (var i = 0; i < min(limit, 3); i++)
            <String, Object?>{
              'id': 'mls_$i',
              'conversation_id': 'conv_1',
              'sender_account_id': 'acct_1',
              'sender_device_id': 'dev_1',
              'kind': 'commit',
              'payload': payload,
              'idempotency_key': 'idem_$i',
              'sync_event_id': i + 1,
              'created_at': '2026-10-22T00:00:00Z',
            },
        ],
      });
    });
    final client = await _clientFor(server);
    final page = await client.mlsMessages('token', limit: 200);
    expect(page, hasLength(1));
    expect(page.single.payload, hasLength(4 * 1024 * 1024));
    expect(
      server.requests.map((uri) => uri.queryParameters['limit']),
      <String>['200', '100', '50', '25', '12', '6', '3', '1'],
    );
  });
}
