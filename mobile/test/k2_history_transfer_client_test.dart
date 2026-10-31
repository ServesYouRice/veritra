import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_errors.dart';
import 'package:private_messenger/core/history_transfer_client.dart';

final digest = 'c' * 64;
final transfer = 'a' * 64;
final claimHash = 'b' * 64;
final body = Uint8List.fromList(List.generate(70000, (i) => i % 251));

HistoryTransferMetadata metadata({int? size, String? sha}) =>
    HistoryTransferMetadata(
        transferId: transfer,
        claimRequestHash: claimHash,
        transcriptHash: List.filled(32, 7),
        ciphertextSha256: sha ?? digest,
        sizeBytes: size ?? body.length,
        handoff: [1, 2, 3]);

Map<String, Object?> receipt(
        {String state = 'active',
        String? sha,
        int? size,
        List<int>? handoff}) =>
    {
      'transfer': {
        'transfer_id': transfer,
        'link_id': 'link-1',
        'account_id': 'alice',
        'source_device_id': 'old',
        'recipient_device_id': 'new',
        'claim_request_hash': claimHash,
        'transcript_hash': base64Encode(List.filled(32, 7)),
        'ciphertext_sha256': sha ?? digest,
        'size_bytes': size ?? body.length,
        'state': state,
        if (handoff != null) 'handoff': base64Encode(handoff),
        'created_at': '2026-10-31T10:00:00Z',
        'expires_at': '2026-11-07T10:00:00Z',
      }
    };

/// A loopback server whose handler each test replaces.
class Loopback {
  late HttpServer server;
  late Future<void> Function(HttpRequest) handler;
  final requests = <HttpRequest>[];
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request);
      await handler(request);
    });
  }

  String get origin => 'http://127.0.0.1:${server.port}';
}

Future<void> sendJson(HttpRequest r, int status, Object body) async {
  r.response.statusCode = status;
  r.response.headers.contentType = ContentType.json;
  r.response.write(jsonEncode(body));
  await r.response.close();
}

/// The source's status lookup before its first upload: no transfer yet.
Future<bool> notYet(HttpRequest r) async {
  if (r.method != 'GET') return false;
  await sendJson(r, 404, {'error': 'not_found'});
  return true;
}

/// Serves [content] like `serveEncryptedBlob`: ETag, ranges and If-Range.
Future<void> serveBlob(HttpRequest r, List<int> content,
    {String? etag, int? cutAt}) async {
  final tag = etag ?? '"sha256-$digest"';
  r.response.headers.set(HttpHeaders.etagHeader, tag);
  final range = r.headers.value(HttpHeaders.rangeHeader);
  final ifRange = r.headers.value(HttpHeaders.ifRangeHeader);
  var start = 0;
  if (range != null && (ifRange == null || ifRange == tag)) {
    start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
    r.response.statusCode = 206;
    r.response.headers.set(HttpHeaders.contentRangeHeader,
        'bytes $start-${content.length - 1}/${content.length}');
  }
  final slice = content.sublist(start, cutAt ?? content.length);
  if (cutAt == null) r.response.contentLength = slice.length;
  r.response.add(slice);
  await r.response.close();
}

void main() {
  late Loopback server;
  late HistoryTransferClient client;
  late Directory dir;
  setUp(() async {
    server = Loopback();
    await server.start();
    client = HistoryTransferClient(baseUrl: server.origin);
    dir = await Directory.systemTemp.createTemp('veritra-k2-transfer-');
  });
  tearDown(() async {
    client.close();
    await server.server.close(force: true);
    await dir.delete(recursive: true);
  });

  test('upload streams metadata then exactly the ciphertext, in order',
      () async {
    late List<int> raw;
    late String? auth, type;
    server.handler = (r) async {
      if (await notYet(r)) return;
      auth = r.headers.value(HttpHeaders.authorizationHeader);
      type = r.headers.value(HttpHeaders.contentTypeHeader);
      raw = await r.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(r.headers.contentLength, raw.length);
      await sendJson(r, 201, receipt());
    };
    final result = await client.upload(
        token: 'source-token',
        linkId: 'link-1',
        metadata: metadata(),
        ciphertext: () =>
            Stream.fromIterable([body.sublist(0, 1000), body.sublist(1000)]));
    expect(result.transferId, transfer);
    expect(result.handoff, isNull);
    expect(server.requests.map((r) => r.method), ['GET', 'POST']);
    expect(server.requests.last.uri.path,
        '/api/v1/device-links/v3/link-1/history');
    expect(auth, 'Bearer source-token');
    final boundary = RegExp(r'boundary=(.+)$').firstMatch(type!)!.group(1)!;
    final text = latin1.decode(raw);
    final parts = text.split('--$boundary');
    expect(parts, hasLength(4), reason: 'preamble, two parts, closing');
    expect(parts[1], contains('name="metadata"'));
    expect(parts[1], contains('Content-Type: application/json'));
    final meta = jsonDecode(parts[1].split('\r\n\r\n')[1].trim()) as Map;
    expect(meta.keys.toSet(), {
      'protocol_version',
      'transfer_id',
      'claim_request_hash',
      'transcript_hash',
      'ciphertext_sha256',
      'size_bytes',
      'handoff'
    });
    expect(meta['protocol_version'], 'veritra-device-link-v3');
    expect(base64Decode(meta['handoff'] as String), [1, 2, 3]);
    expect(parts[2], contains('name="ciphertext"'));
    expect(parts[2], contains('Content-Type: application/octet-stream'));
    final payload = parts[2].substring(parts[2].indexOf('\r\n\r\n') + 4);
    expect(latin1.encode(payload.substring(0, payload.length - 2)), body);
    expect(parts[3], '--\r\n');
  });

  test(
      'an existing transfer is looked up first: the same one is returned '
      'without resending, a different one is refused', () async {
    server.handler = (r) async => sendJson(r, 200, receipt());
    Future<HistoryTransferReceipt> send() => client.upload(
        token: 't',
        linkId: 'link-1',
        metadata: metadata(),
        ciphertext: () => Stream.value(body));
    expect((await send()).state, 'active');
    server.handler = (r) async => sendJson(r, 200, receipt(sha: 'd' * 64));
    await expectLater(send(), throwsA(isA<ApiResponseException>()));
    expect(server.requests.map((r) => r.method), ['GET', 'GET'],
        reason: 'the body is never sent again for an existing transfer');

    // A POST answered with a different receipt is refused too.
    server.handler = (r) async {
      if (await notYet(r)) return;
      await r.drain<void>();
      await sendJson(r, 201, receipt(sha: 'd' * 64));
    };
    await expectLater(send(), throwsA(isA<ApiResponseException>()));

    // Any status other than 404 stops before the POST.
    server.handler = (r) async => sendJson(r, 403, {'error': 'forbidden'});
    await expectLater(send(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 's', 403)));
    expect(server.requests.where((r) => r.method == 'POST'), hasLength(1));
  });

  test('a ciphertext source of the wrong length never completes an upload',
      () async {
    server.handler = (r) async {
      if (await notYet(r)) return;
      try {
        await r.drain<void>();
      } catch (_) {}
      await sendJson(r, 201, receipt());
    };
    await expectLater(
        client.upload(
            token: 't',
            linkId: 'link-1',
            metadata: metadata(),
            ciphertext: () => Stream.value(body.sublist(1))),
        throwsA(anything));
    await expectLater(
        client.upload(
            token: 't',
            linkId: 'link-1',
            metadata: metadata(),
            ciphertext: () => Stream.value([...body, 0])),
        throwsA(isA<HistoryTransferMismatch>()));
  });

  test('redirects are never followed, so no credential leaves the origin',
      () async {
    final other = Loopback();
    await other.start();
    other.handler = (r) async => sendJson(r, 200, receipt());
    server.handler = (r) async {
      await r.drain<void>();
      r.response.statusCode = 307;
      r.response.headers.set(HttpHeaders.locationHeader,
          '${other.origin}/api/v1/device-links/v3/link-1/history');
      await r.response.close();
    };
    final claim = HistoryClaimAuth(List.filled(32, 9));
    await expectLater(
        client.status('link-1', claim),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 307)));
    await expectLater(
        client.download(
            linkId: 'link-1',
            auth: claim,
            expectedSha256: digest,
            expectedSize: body.length,
            target: File('${dir.path}/c')),
        throwsA(isA<ApiException>()));
    await expectLater(
        client.upload(
            token: 'secret',
            linkId: 'link-1',
            metadata: metadata(),
            ciphertext: () => Stream.value(body)),
        throwsA(isA<ApiException>()));
    expect(other.requests, isEmpty);
    await other.server.close(force: true);
  });

  test('the claim token header is canonical and the handoff is decoded',
      () async {
    String? header, auth;
    server.handler = (r) async {
      header = r.headers.value('X-Veritra-Claim-Token');
      auth = r.headers.value(HttpHeaders.authorizationHeader);
      await sendJson(r, 200, receipt(handoff: [4, 5, 6]));
    };
    final status =
        await client.status('link-1', HistoryClaimAuth(List.filled(32, 255)));
    expect(header, base64Url.encode(List.filled(32, 255)).replaceAll('=', ''));
    expect(auth, isNull);
    expect(status.handoff, [4, 5, 6]);
    expect(() => HistoryClaimAuth([1]), throwsArgumentError);
  });

  test('malformed receipts are one typed failure', () async {
    for (final bad in <Object>[
      {'transfer': {}},
      receipt(size: 0),
      {
        'transfer': {...(receipt()['transfer'] as Map), 'transfer_id': 'XYZ'}
      },
      [1, 2],
    ]) {
      server.handler = (r) async => sendJson(r, 200, bad);
      await expectLater(client.status('link-1', const HistorySessionAuth('t')),
          throwsA(isA<ApiResponseException>()));
    }
  });

  test('download resumes the same body and restarts a changed one', () async {
    final target = File('${dir.path}/content');
    var cut = 30000;
    server.handler = (r) => serveBlob(r, body, cutAt: cut);
    final claim = HistoryClaimAuth(List.filled(32, 1));
    Future<int> fetch() => client.download(
        linkId: 'link-1',
        auth: claim,
        expectedSha256: digest,
        expectedSize: body.length,
        target: target);
    // A cut connection keeps its prefix.
    await expectLater(fetch(), throwsA(anything));
    expect(await target.length(), 30000);
    server.handler = (r) => serveBlob(r, body);
    expect(await fetch(), body.length);
    final resumed = server.requests.last;
    expect(resumed.headers.value(HttpHeaders.rangeHeader), 'bytes=30000-');
    expect(
        resumed.headers.value(HttpHeaders.ifRangeHeader), '"sha256-$digest"');
    expect(await target.readAsBytes(), body);

    // Already complete: no request at all.
    final count = server.requests.length;
    expect(await fetch(), body.length);
    expect(server.requests.length, count);

    // The server ignores the range (If-Range failed): start over.
    await target.writeAsBytes(List.filled(100, 0));
    server.handler = (r) async {
      r.response.headers.set(HttpHeaders.etagHeader, '"sha256-$digest"');
      r.response.contentLength = body.length;
      r.response.add(body);
      await r.response.close();
    };
    expect(await fetch(), body.length);
    expect(await target.readAsBytes(), body);
    cut = 0;
  });

  test('a different ETag or range never mixes bodies', () async {
    final target = File('${dir.path}/content');
    final claim = HistoryClaimAuth(List.filled(32, 1));
    Future<int> fetch() => client.download(
        linkId: 'link-1',
        auth: claim,
        expectedSha256: digest,
        expectedSize: body.length,
        target: target);
    server.handler = (r) => serveBlob(r, body, etag: '"sha256-${'e' * 64}"');
    await target.writeAsBytes(body.sublist(0, 10));
    await expectLater(fetch(), throwsA(isA<HistoryTransferMismatch>()));
    expect(await target.exists(), isFalse);

    server.handler = (r) async {
      r.response.statusCode = 206;
      r.response.headers.set(HttpHeaders.etagHeader, '"sha256-$digest"');
      r.response.headers.set(HttpHeaders.contentRangeHeader,
          'bytes 5-${body.length - 1}/${body.length}');
      r.response.add(body.sublist(5));
      await r.response.close();
    };
    await target.writeAsBytes(body.sublist(0, 10));
    await expectLater(fetch(), throwsA(isA<HistoryTransferMismatch>()));
    expect(await target.exists(), isFalse);

    // More bytes than expected.
    server.handler = (r) async {
      r.response.headers.set(HttpHeaders.etagHeader, '"sha256-$digest"');
      r.response.add([...body, 1, 2]);
      await r.response.close();
    };
    await expectLater(fetch(), throwsA(isA<HistoryTransferMismatch>()));
    expect(await target.exists(), isFalse);

    server.handler = (r) async => sendJson(r, 410, {'error': 'gone'});
    await expectLater(
        fetch(),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 410)));
  });

  test('acknowledge sends only identity and digest and requires the ack state',
      () async {
    Map<String, Object?>? sent;
    server.handler = (r) async {
      sent = jsonDecode(await utf8.decodeStream(r)) as Map<String, Object?>;
      await sendJson(r, 200, receipt(state: 'acknowledged'));
    };
    final ack = await client.acknowledge(
        linkId: 'link-1',
        auth: const HistorySessionAuth('new-session'),
        transferId: transfer,
        ciphertextSha256: digest);
    expect(ack.state, 'acknowledged');
    expect(sent, {
      'protocol_version': 'veritra-device-link-v3',
      'transfer_id': transfer,
      'ciphertext_sha256': digest
    });
    expect(server.requests.last.uri.path,
        '/api/v1/device-links/v3/link-1/history/ack');
    server.handler = (r) async {
      await r.drain<void>();
      await sendJson(r, 200, receipt());
    };
    await expectLater(
        client.acknowledge(
            linkId: 'link-1',
            auth: const HistorySessionAuth('t'),
            transferId: transfer,
            ciphertextSha256: digest),
        throwsA(isA<ApiResponseException>()));

    server.handler = (r) async => sendJson(r, 200, {'state': 'cancelled'});
    await client.cancel('link-1', const HistorySessionAuth('t'));
    expect(server.requests.last.method, 'DELETE');
  });

  test('metadata outside the server limits is refused before any request', () {
    expect(() => metadata(size: 0), throwsArgumentError);
    expect(() => metadata(size: maxHistoryCiphertextBytes + 1),
        throwsArgumentError);
    expect(() => metadata(sha: 'C' * 64), throwsArgumentError);
    expect(
        () => HistoryTransferMetadata(
            transferId: transfer,
            claimRequestHash: claimHash,
            transcriptHash: List.filled(31, 0),
            ciphertextSha256: digest,
            sizeBytes: 1,
            handoff: [1]),
        throwsArgumentError);
    expect(
        () => HistoryTransferMetadata(
            transferId: transfer,
            claimRequestHash: claimHash,
            transcriptHash: List.filled(32, 0),
            ciphertextSha256: digest,
            sizeBytes: 1,
            handoff: List.filled(maxHistoryHandoffBytes + 1, 0)),
        throwsArgumentError);
    expect(server.requests, isEmpty);
  });
}
