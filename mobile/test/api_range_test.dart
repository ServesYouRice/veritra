// A resumed backup download only continues from the byte it asked for when
// the server proves it with a matching 206 Content-Range (TASK-024). A 200
// carries the whole object from byte 0 and must never be appended at an
// offset.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';

final _token = List<int>.filled(32, 1);

class _Reply {
  const _Reply(this.status, {this.contentRange, this.bodyLength = 10});

  final int status;
  final String? contentRange;
  final int bodyLength;
}

/// A loopback server that answers every request with [reply] and records the
/// Range header it was sent.
Future<(ApiClient, List<String?>)> _client(_Reply reply) async {
  final ranges = <String?>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    ranges.add(request.headers.value(HttpHeaders.rangeHeader));
    try {
      await request.drain<void>();
      request.response.statusCode = reply.status;
      if (reply.contentRange != null) {
        request.response.headers.set('Content-Range', reply.contentRange!);
      }
      request.response.add(Uint8List(reply.bodyLength));
      await request.response.close();
    } catch (_) {
      // The client may stop reading early on purpose.
    }
  });
  addTearDown(() => server.close(force: true));
  final client = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
  addTearDown(client.close);
  return (client, ranges);
}

Future<int> _read(Future<Stream<List<int>>> pending) async {
  final stream = await pending;
  var bytes = 0;
  await for (final chunk in stream) {
    bytes += chunk.length;
  }
  return bytes;
}

void main() {
  test('a 206 that starts at the requested offset is accepted', () async {
    final (client, ranges) = await _client(
      const _Reply(206, contentRange: 'bytes 100-109/500'),
    );
    expect(
      await _read(client.recoverEncryptedBackup(_token, startOffset: 100)),
      10,
    );
    expect(ranges, <String?>['bytes=100-']);
  });

  test('a 206 inside the requested end offset is accepted', () async {
    final (client, ranges) = await _client(
      const _Reply(206, contentRange: 'bytes 100-109/500'),
    );
    expect(
      await _read(client.recoverEncryptedBackup(
        _token,
        startOffset: 100,
        endOffset: 109,
      )),
      10,
    );
    expect(ranges, <String?>['bytes=100-109']);
  });

  test('a 206 body longer than its range is refused while streaming', () async {
    final (client, _) = await _client(
      const _Reply(206, contentRange: 'bytes 100-103/500', bodyLength: 10),
    );
    await expectLater(
      _read(client.recoverEncryptedBackup(_token, startOffset: 100)),
      throwsA(isA<ApiResponseTooLargeException>()),
    );
  });

  group('is rejected before any byte is returned', () {
    final cases = <String, _Reply>{
      'the first byte is not the requested offset':
          const _Reply(206, contentRange: 'bytes 0-9/500'),
      'the range starts after the requested offset':
          const _Reply(206, contentRange: 'bytes 101-110/500'),
      'it runs past the requested end offset':
          const _Reply(206, contentRange: 'bytes 100-120/500'),
      'Content-Range is missing': const _Reply(206),
      'the range is unsatisfied (bytes */500)':
          const _Reply(206, contentRange: 'bytes */500'),
      'the dash is missing': const _Reply(206, contentRange: 'bytes 100/500'),
      'a field is not a number':
          const _Reply(206, contentRange: 'bytes 100-1x9/500'),
      'the last byte is before the first':
          const _Reply(206, contentRange: 'bytes 100-99/500'),
      'the complete length ends before the range':
          const _Reply(206, contentRange: 'bytes 100-109/105'),
      'the unit is not bytes':
          const _Reply(206, contentRange: 'items 100-109/500'),
      'trailing text follows the range':
          const _Reply(206, contentRange: 'bytes 100-109/500 extra'),
    };
    for (final entry in cases.entries) {
      test('a 206 where ${entry.key}', () async {
        final (client, _) = await _client(entry.value);
        await expectLater(
          client.recoverEncryptedBackup(
            _token,
            startOffset: 100,
            endOffset: 109,
          ),
          throwsA(isA<ApiResponseException>()),
        );
      });
    }
  });

  test('a 206 that ends past the backup cap is refused', () async {
    final cap = ApiClient.maxBackupCiphertextBytes;
    final (client, _) = await _client(
      _Reply(206, contentRange: 'bytes ${cap - 5}-${cap + 4}/${cap + 5}'),
    );
    await expectLater(
      client.recoverEncryptedBackup(_token, startOffset: cap - 5),
      throwsA(isA<ApiResponseTooLargeException>()),
    );
  });

  test('a 200 to a ranged request is never returned as the offset bytes',
      () async {
    final (client, ranges) = await _client(const _Reply(200));
    await expectLater(
      client.recoverEncryptedBackup(_token, startOffset: 100),
      throwsA(isA<RangeNotHonoredException>()),
    );
    expect(ranges, <String?>['bytes=100-']);
  });

  test('a 200 answers a request without an offset', () async {
    final (client, ranges) = await _client(const _Reply(200));
    expect(await _read(client.recoverEncryptedBackup(_token)), 10);
    expect(ranges, <String?>[null]);
  });

  test('a 206 without an offset in the request is refused', () async {
    final (client, _) = await _client(
      const _Reply(206, contentRange: 'bytes 0-9/10'),
    );
    await expectLater(
      client.recoverEncryptedBackup(_token),
      throwsA(isA<ApiResponseException>()),
    );
  });

  test('a 204 to a ranged request is not accepted', () async {
    final (client, _) = await _client(const _Reply(204, bodyLength: 0));
    await expectLater(
      client.recoverEncryptedBackup(_token, startOffset: 100),
      throwsA(isA<ApiResponseException>()),
    );
  });

  test('errors never carry the recovery token', () async {
    final (client, _) = await _client(const _Reply(200));
    Object? error;
    try {
      await client.recoverEncryptedBackup(_token, startOffset: 7);
    } catch (e) {
      error = e;
    }
    expect(error, isA<RangeNotHonoredException>());
    expect(error.toString(), isNot(contains('AQEBAQEB')));
  });

  test('the response is cancelled when the range is refused', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final hungUp = Completer<void>();
    server.listen((socket) {
      void end() {
        if (!hungUp.isCompleted) hungUp.complete();
      }

      socket.listen((_) {}, onDone: end, onError: (_) => end());
      socket.add(ascii.encode('HTTP/1.1 200 OK\r\n'
          'content-length: 1048576\r\n\r\n'));
      socket.add(Uint8List(1024));
    });
    addTearDown(() => server.close());
    final client = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
    addTearDown(client.close);
    await expectLater(
      client.recoverEncryptedBackup(_token, startOffset: 100),
      throwsA(isA<RangeNotHonoredException>()),
    );
    await hungUp.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('the refused body was not cancelled'),
    );
  });
}
