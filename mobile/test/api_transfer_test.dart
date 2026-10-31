// Streamed uploads and downloads are bounded by progress, not by a fixed
// whole-body deadline (TASK-023), and a resumed backup download is checked
// against the range it asked for (TASK-024).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';

const _idle = Duration(milliseconds: 400);
const _chunk = 64 * 1024;
final _token = List<int>.filled(32, 1);

const _attachmentJson = '{"id":"att_1","owner_account_id":"acc_1",'
    '"conversation_id":"conv_1","storage_key":"k","ciphertext_sha256":"h",'
    '"size_bytes":1,"created_at":"2026-01-01T00:00:00Z"}';

/// A body of [chunks] chunks produced on demand, [gap] apart. [pulled]
/// counts the chunks the request actually took.
class _Body {
  _Body(this.chunks, {this.gap = Duration.zero});

  final int chunks;
  final Duration gap;
  int pulled = 0;

  int get length => chunks * _chunk;

  Stream<List<int>> get stream async* {
    for (var i = 0; i < chunks; i++) {
      if (gap > Duration.zero) await Future<void>.delayed(gap);
      pulled++;
      yield Uint8List(_chunk);
    }
  }
}

/// A raw TCP server for the cases that need control over the socket. It
/// records when a connection ends, which is how a test sees an aborted
/// request or a cancelled download.
class _RawServer {
  _RawServer._(this.socket);

  final ServerSocket socket;
  final Completer<void> closed = Completer<void>();
  final List<StreamSubscription<Uint8List>> _inputs =
      <StreamSubscription<Uint8List>>[];

  Uri get uri => Uri.parse('http://127.0.0.1:${socket.port}');

  /// [onConnection] gets the socket and its (already listening) data stream
  /// handle so it can pause, answer or ignore the request.
  static Future<_RawServer> start(
    void Function(Socket socket, StreamSubscription<Uint8List> input)
        onConnection,
  ) async {
    final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = _RawServer._(raw);
    raw.listen((client) {
      void end() {
        if (!server.closed.isCompleted) server.closed.complete();
      }

      final input = client.listen(
        (_) {},
        onDone: end,
        onError: (_) => end(),
        cancelOnError: true,
      );
      server._inputs.add(input);
      onConnection(client, input);
    });
    addTearDown(() => raw.close());
    return server;
  }

  /// A paused reader only learns that the peer hung up once it reads again,
  /// so resume first; a connection the client left open stays open.
  Future<void> expectEnded() {
    for (final input in _inputs) {
      if (input.isPaused) input.resume();
    }
    return closed.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('the connection was left open'),
    );
  }
}

Future<HttpServer> _httpServer(
  FutureOr<void> Function(HttpRequest request) handle,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      await handle(request);
    } catch (_) {
      // The client may hang up on purpose.
    }
  });
  addTearDown(() => server.close(force: true));
  return server;
}

ApiClient _client(Uri origin, {Duration idle = _idle}) {
  final client = ApiClient(
    baseUrl: origin.toString(),
    transferIdleTimeout: idle,
  );
  addTearDown(client.close);
  return client;
}

Matcher get _timesOut => throwsA(isA<TimeoutException>());

void main() {
  group('uploads are bounded by progress', () {
    test('a steady upload longer than the idle bound succeeds', () async {
      final server = await _httpServer((request) async {
        await request.drain<void>();
        request.response
          ..headers.contentType = ContentType.json
          ..write(_attachmentJson);
        await request.response.close();
      });
      final client = _client(Uri.parse('http://127.0.0.1:${server.port}'));
      // 10 chunks, 150 ms apart: 1.5 s in all against a 0.4 s idle bound.
      final body = _Body(10, gap: const Duration(milliseconds: 150));
      final envelope = await client.uploadEncryptedAttachment(
        'token',
        'conv_1',
        body.stream,
        ciphertextLength: body.length,
        cryptoMetadata: const <String, Object?>{},
      );
      expect(envelope.id, 'att_1');
      expect(body.pulled, 10);
    });

    test('a steady backup upload longer than the idle bound succeeds',
        () async {
      final server = await _httpServer((request) async {
        await request.drain<void>();
        request.response.write('{}');
        await request.response.close();
      });
      final client = _client(Uri.parse('http://127.0.0.1:${server.port}'));
      final body = _Body(10, gap: const Duration(milliseconds: 150));
      await client.uploadEncryptedBackup(
        'token',
        body.stream,
        ciphertextLength: body.length,
        recoveryToken: _token,
        cryptoMetadata: const <String, Object?>{},
      );
      expect(body.pulled, 10);
    });

    test('an upload whose server stops reading is aborted', () async {
      // The server never reads the body, so the kernel buffers fill and the
      // request stops taking chunks from the source.
      final server = await _RawServer.start((socket, input) => input.pause());
      final client = _client(server.uri);
      final body = _Body(600); // 37.5 MiB, below the 50 MiB cap.
      final started = DateTime.now();
      await expectLater(
        client.uploadEncryptedAttachment(
          'token',
          'conv_1',
          body.stream,
          ciphertextLength: body.length,
          cryptoMetadata: const <String, Object?>{},
        ),
        _timesOut,
      );
      expect(DateTime.now().difference(started), lessThan(_idle * 12));
      expect(body.pulled, lessThan(body.chunks));
      await server.expectEnded();
    });

    test('a backup upload whose server stops reading is aborted', () async {
      final server = await _RawServer.start((socket, input) => input.pause());
      final client = _client(server.uri);
      final body = _Body(600);
      await expectLater(
        client.uploadEncryptedBackup(
          'token',
          body.stream,
          ciphertextLength: body.length,
          recoveryToken: _token,
          cryptoMetadata: const <String, Object?>{},
        ),
        _timesOut,
      );
      await server.expectEnded();
    });

    test('a source that stops producing is aborted', () async {
      final server = await _RawServer.start((socket, input) {});
      final client = _client(server.uri);
      final controller = StreamController<List<int>>();
      addTearDown(controller.close);
      controller.add(Uint8List(_chunk));
      await expectLater(
        client.uploadEncryptedAttachment(
          'token',
          'conv_1',
          controller.stream,
          ciphertextLength: 2 * _chunk,
          cryptoMetadata: const <String, Object?>{},
        ),
        _timesOut,
      );
      await server.expectEnded();
    });

    test('a server that never answers the finished body is aborted', () async {
      // Reads everything and then says nothing.
      final server = await _RawServer.start((socket, input) {});
      final client = _client(server.uri);
      final body = _Body(2);
      await expectLater(
        client.uploadEncryptedAttachment(
          'token',
          'conv_1',
          body.stream,
          ciphertextLength: body.length,
          cryptoMetadata: const <String, Object?>{},
        ),
        _timesOut,
      );
      expect(body.pulled, 2);
      await server.expectEnded();
    });
  });

  group('download bodies fail when they go idle', () {
    /// Answers with headers and 1 KiB of a [total]-byte body, then stalls.
    Future<_RawServer> stallingServer({int total = 1024 * 1024}) {
      return _RawServer.start((socket, input) {
        socket.add(ascii.encode('HTTP/1.1 200 OK\r\n'
            'content-length: $total\r\n\r\n'));
        socket.add(Uint8List(1024));
      });
    }

    test('downloadEncryptedAttachment', () async {
      final server = await stallingServer();
      final client = _client(server.uri);
      final stream = await client.downloadEncryptedAttachment('token', 'att_1');
      await expectLater(stream.drain<void>(), _timesOut);
      await server.expectEnded();
    });

    test('recoverEncryptedBackup', () async {
      final server = await stallingServer();
      final client = _client(server.uri);
      final stream = await client.recoverEncryptedBackup(_token);
      await expectLater(stream.drain<void>(), _timesOut);
      await server.expectEnded();
    });

    test('a slow body that keeps moving is not cut', () async {
      // 8 KiB in eight pieces, 150 ms apart: 1.2 s against a 0.4 s bound.
      final server = await _RawServer.start((socket, input) async {
        socket.add(ascii.encode('HTTP/1.1 200 OK\r\n'
            'content-length: 8192\r\n\r\n'));
        for (var i = 0; i < 8; i++) {
          socket.add(Uint8List(1024));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      });
      final client = _client(server.uri);
      final stream = await client.downloadEncryptedAttachment('token', 'att_1');
      var received = 0;
      await for (final chunk in stream) {
        received += chunk.length;
      }
      expect(received, 8 * 1024);
    });

    test('a consumer that pauses longer than the bound is not timed out',
        () async {
      final payload = Uint8List(256 * 1024);
      final server = await _httpServer((request) async {
        request.response.add(payload);
        await request.response.close();
      });
      final client = _client(Uri.parse('http://127.0.0.1:${server.port}'));
      final stream = await client.downloadEncryptedAttachment('token', 'att_1');
      var received = 0;
      final done = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      subscription = stream.listen(
        (chunk) {
          received += chunk.length;
          if (!subscription.isPaused && received == chunk.length) {
            // Pause after the first chunk for three times the bound.
            subscription.pause(Future<void>.delayed(_idle * 3));
          }
        },
        onError: done.completeError,
        onDone: done.complete,
      );
      await done.future;
      expect(received, payload.length);
    });
  });
}
