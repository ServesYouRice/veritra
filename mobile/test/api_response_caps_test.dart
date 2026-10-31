// Replies that carry ciphertext are read up to the ciphertext cap, not the
// 2 MiB cap of ordinary JSON (TASK-025).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';

/// The 16 MiB cap on replies that carry ciphertext.
const _cap = 16 * 1024 * 1024;

/// Answers every request with the JSON [build] makes for it and records the
/// request URIs.
Future<(ApiClient, List<Uri>)> _client(
  Object? Function(HttpRequest request) build,
) async {
  final requests = <Uri>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    requests.add(request.uri);
    try {
      await request.drain<void>();
      final body = utf8.encode(jsonEncode(build(request)));
      request.response
        ..headers.contentType = ContentType.json
        ..add(body);
      await request.response.close();
    } catch (_) {
      // The client may stop reading early on purpose.
    }
  });
  addTearDown(() => server.close(force: true));
  final client = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
  addTearDown(client.close);
  return (client, requests);
}

/// A page of export rows that is about [bytes] long once encoded.
Map<String, Object?> _page(int bytes, {String? next}) => <String, Object?>{
      'messages': <Object?>[
        <String, Object?>{'ciphertext': 'A' * bytes},
      ],
      'next_before': next,
    };

Map<String, Object?> _mlsMessage(int payloadBytes) => <String, Object?>{
      'mls_message': <String, Object?>{
        'id': 'mls_1',
        'conversation_id': 'conv_1',
        'sender_account_id': 'acct_1',
        'sender_device_id': 'dev_1',
        'kind': 'application',
        'payload': base64Encode(List<int>.filled(payloadBytes, 1)),
        'idempotency_key': 'idem_1',
        'sync_event_id': 1,
        'created_at': '2026-10-22T00:00:00Z',
      },
    };

List<String?> _limits(List<Uri> requests) =>
    requests.map((uri) => uri.queryParameters['limit']).toList();

void main() {
  group('exportAccountPage', () {
    test('accepts a page above 2 MiB and keeps the requested limit', () async {
      final (client, requests) = await _client(
        (_) => _page(3 * 1024 * 1024, next: 'cursor_2'),
      );
      final page = await client.exportAccountPage('token', limit: 250);
      expect(page['next_before'], 'cursor_2');
      expect(_limits(requests), <String>['250']);
    });

    test('halves the limit while the page is over the cap, keeping the cursor',
        () async {
      final (client, requests) = await _client((request) {
        final limit = int.parse(request.uri.queryParameters['limit']!);
        return limit > 60 ? _page(_cap + 1024) : _page(1024, next: 'cursor_9');
      });
      final page = await client.exportAccountPage(
        'token',
        limit: 250,
        before: 'cursor_1',
      );
      expect(page['next_before'], 'cursor_9');
      expect(_limits(requests), <String>['250', '125', '62', '31']);
      for (final uri in requests) {
        expect(uri.queryParameters['before'], 'cursor_1');
      }
    });

    test('a limit above the 200-row list cap is not silently lowered',
        () async {
      final (client, requests) = await _client((_) => _page(1024));
      await client.exportAccountPage('token', limit: 1000);
      expect(_limits(requests), <String>['1000']);
    });

    test('a single row over the cap still fails', () async {
      final (client, requests) = await _client(
        (_) => _page(_cap + 1024),
      );
      await expectLater(
        client.exportAccountPage('token', limit: 4),
        throwsA(isA<ApiResponseTooLargeException>()),
      );
      expect(_limits(requests), <String>['4', '2', '1']);
    });
  });

  group('sendMlsMessage', () {
    test('decodes the echoed 4 MiB payload', () async {
      // 4 MiB of payload is about 5.6 MB as base64, above the 2 MiB JSON cap.
      final (client, _) = await _client(
        (_) => _mlsMessage(4 * 1024 * 1024),
      );
      final message = await client.sendMlsMessage(
        'token',
        'conv_1',
        kind: 'application',
        payload: const <int>[1, 2, 3],
        idempotencyKey: 'idem_1',
      );
      expect(message.payload, hasLength(4 * 1024 * 1024));
    });

    test('a reply above the ciphertext cap still fails', () async {
      final (client, _) = await _client(
        (_) => _mlsMessage(_cap),
      );
      await expectLater(
        client.sendMlsMessage(
          'token',
          'conv_1',
          kind: 'application',
          payload: const <int>[1, 2, 3],
          idempotencyKey: 'idem_1',
        ),
        throwsA(isA<ApiResponseTooLargeException>()),
      );
    });
  });
}
