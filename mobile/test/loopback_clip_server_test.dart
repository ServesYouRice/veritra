// The loopback server that plays a small voice note from memory on iOS, macOS
// and Linux (D134): loopback only, one unguessable path, ranges, no caching,
// gone after close. These tests use real sockets.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/chat/loopback_clip_server.dart';

Future<(int, HttpHeaders, List<int>)> _fetch(
  Uri url, {
  String method = 'GET',
  Map<String, String> headers = const <String, String>{},
  String? host,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, url);
    headers.forEach(request.headers.set);
    if (host != null) request.headers.host = host;
    final response = await request.close();
    final body = <int>[];
    await for (final chunk in response) {
      body.addAll(chunk);
    }
    return (response.statusCode, response.headers, body);
  } finally {
    client.close(force: true);
  }
}

/// Sends [head] as raw request bytes, for requests `HttpClient` will not
/// make (two Host headers, none at all), and returns the status code.
Future<int> _rawStatus(Uri url, String head) async {
  final socket = await Socket.connect(url.host, url.port);
  try {
    socket.write(head);
    await socket.flush();
    final reply = await socket
        .cast<List<int>>()
        .transform(latin1.decoder)
        .join()
        .timeout(const Duration(seconds: 5));
    return int.parse(reply.split(' ')[1]);
  } finally {
    socket.destroy();
  }
}

void main() {
  late Uint8List audio;
  late LoopbackClipServer server;

  setUp(() async {
    audio = Uint8List.fromList(List<int>.generate(100, (i) => i + 1));
    server = await LoopbackClipServer.start(audio, mimeType: 'audio/mp4');
  });

  tearDown(() => server.close());

  test('listens on 127.0.0.1 only, on one random path with an extension', () {
    expect(server.url.scheme, 'http');
    expect(server.url.host, '127.0.0.1');
    expect(server.url.port, greaterThan(0));
    final name = server.url.path.substring(1);
    expect(name, endsWith('.m4a'));
    // 32 random bytes, base64url without padding, is 43 characters.
    expect(name.length, 43 + '.m4a'.length);
    expect(
      base64Url.decode(base64Url.normalize(name.substring(0, 43))).length,
      32,
    );
  });

  test('two servers get different ports-and-paths (tokens are random)',
      () async {
    final other = await LoopbackClipServer.start(audio);
    addTearDown(other.close);
    expect(other.url.path, isNot(server.url.path));
  });

  test('serves the whole clip with type, length and no caching', () async {
    final (status, headers, body) = await _fetch(server.url);
    expect(status, 200);
    expect(body, audio);
    expect(headers.contentType?.mimeType, 'audio/mp4');
    expect(headers.contentLength, 100);
    expect(headers.value('accept-ranges'), 'bytes');
    expect(headers.value('cache-control'), 'no-store');
  });

  test('HEAD gives the headers and no body', () async {
    final (status, headers, body) = await _fetch(server.url, method: 'HEAD');
    expect(status, 200);
    expect(body, isEmpty);
    expect(headers.contentLength, 100);
  });

  test('a range gets 206 with exactly that slice', () async {
    final (status, headers, body) = await _fetch(
      server.url,
      headers: <String, String>{'Range': 'bytes=10-19'},
    );
    expect(status, 206);
    expect(body, audio.sublist(10, 20));
    expect(headers.value('content-range'), 'bytes 10-19/100');
    expect(headers.contentLength, 10);
  });

  test('AVPlayer style probes: bytes=0-1, open-ended and suffix ranges',
      () async {
    final probe = await _fetch(
      server.url,
      headers: <String, String>{'Range': 'bytes=0-1'},
    );
    expect(probe.$1, 206);
    expect(probe.$3, <int>[1, 2]);
    final open = await _fetch(
      server.url,
      headers: <String, String>{'Range': 'bytes=90-'},
    );
    expect(open.$3, audio.sublist(90));
    final suffix = await _fetch(
      server.url,
      headers: <String, String>{'Range': 'bytes=-5'},
    );
    expect(suffix.$3, audio.sublist(95));
    final past = await _fetch(
      server.url,
      headers: <String, String>{'Range': 'bytes=50-5000'},
    );
    expect(past.$3, audio.sublist(50));
  });

  test('a malformed or unsatisfiable bytes range is 416', () async {
    for (final range in <String>[
      'bytes=100-',
      'bytes=5-2',
      'bytes=-0',
      'bytes=-',
      'bytes=a-b',
      'bytes=99999999999999999999-',
    ]) {
      final (status, headers, _) = await _fetch(
        server.url,
        headers: <String, String>{'Range': range},
      );
      expect(status, 416, reason: range);
      expect(headers.value('content-range'), 'bytes */100');
    }
  });

  test('a range in another unit, or several ranges, is ignored: 200, whole',
      () async {
    for (final range in <String>['x', 'items=0-1', 'bytes=0-1,5-6']) {
      final (status, headers, body) = await _fetch(
        server.url,
        headers: <String, String>{'Range': range},
      );
      expect(status, 200, reason: range);
      expect(body, audio, reason: range);
      expect(headers.value('content-range'), isNull, reason: range);
    }
  });

  test('range positions too long for an int are clamped, not rejected', () {
    const parse = LoopbackClipServer.parseRange;
    expect(parse(<String>['bytes=0-99999999999999999999'], 100), (0, 99));
    expect(parse(<String>['bytes=-99999999999999999999'], 100), (0, 99));
    expect(parse(<String>['bytes=00000000000000000000010-11'], 100), (10, 11));
    expect(parse(<String>['bytes=0-0'], 100), (0, 0));
    expect(parse(<String>['bytes=99-'], 100), (99, 99));
    expect(parse(<String>[' BYTES = 1-2 '], 100), (1, 2));
    expect(parse(null, 100), isNull);
    expect(parse(<String>['bytes=0-1', 'bytes=2-3'], 100), isNull);
    expect(
      parse(<String>['bytes=0-'], 0),
      same(LoopbackClipServer.unsatisfiableRange),
    );
  });

  test('any other path, a query or a guess is 404 and leaks nothing', () async {
    final base = server.url;
    for (final url in <Uri>[
      base.replace(path: '/'),
      base.replace(path: '/wrong.m4a'),
      base.replace(path: '${base.path}x'),
      base.replace(path: base.path.replaceFirst('.m4a', '')),
      base.replace(query: 'a=1'),
    ]) {
      final (status, _, body) = await _fetch(url);
      expect(status, 404, reason: '$url');
      expect(body, isEmpty);
    }
  });

  test('a request for another host name is refused (DNS rebinding)', () async {
    for (final host in <String>[
      'evil.example',
      'localhost',
      '127.0.0.2',
    ]) {
      final (status, _, body) = await _fetch(server.url, host: host);
      expect(status, 403, reason: host);
      expect(body, isEmpty, reason: host);
    }
  });

  test('no Host, or two Host headers, is refused', () async {
    final url = server.url;
    final good = 'Host: 127.0.0.1:${url.port}\r\n';
    expect(
      await _rawStatus(
          url, 'GET ${url.path} HTTP/1.1\r\n${good}Connection: close\r\n\r\n'),
      200,
    );
    expect(
      await _rawStatus(url, 'GET ${url.path} HTTP/1.0\r\n\r\n'),
      403,
    );
    // The right address without the port is still not this server's origin.
    expect(
      await _rawStatus(
        url,
        'GET ${url.path} HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        'Connection: close\r\n\r\n',
      ),
      403,
    );
    expect(
      await _rawStatus(
        url,
        'GET ${url.path} HTTP/1.1\r\n${good}Host: evil.example\r\n'
        'Connection: close\r\n\r\n',
      ),
      anyOf(400, 403),
    );
  });

  test('only GET and HEAD are served', () async {
    final (status, _, _) = await _fetch(server.url, method: 'POST');
    expect(status, 405);
  });

  test('the same bytes are served by a view, so wiping them wipes the source',
      () async {
    audio.fillRange(0, audio.length, 0);
    final (_, _, body) = await _fetch(server.url);
    expect(body, everyElement(0));
  });

  test('close stops the listener, and closing twice is fine', () async {
    final url = server.url;
    await server.close();
    await server.close();
    expect(server.isClosed, isTrue);
    await expectLater(_fetch(url), throwsA(isA<SocketException>()));
  });
}
