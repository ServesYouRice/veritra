import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';

// C3 info routes from the app's side: paths, preconditions, the key id
// header, a 404 as "none", and a 412 as an ApiException.

void main() {
  late HttpServer server;
  late ApiClient client;
  final seen = <HttpRequest>[];
  final bodies = <List<int>>[];

  setUp(() async {
    seen.clear();
    bodies.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      seen.add(request);
      final body = <int>[];
      await for (final chunk in request) {
        body.addAll(chunk);
      }
      bodies.add(body);
      final res = request.response;
      final path = request.uri.path;
      if (request.method == 'PUT' && path.endsWith('/stale/info')) {
        res.statusCode = 412;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'error': 'version_conflict'}));
      } else if (request.method == 'PUT') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'version': 3}));
      } else if (request.method == 'GET' && path.contains('missing')) {
        res.statusCode = 404;
        res.write(jsonEncode({'error': 'not_found'}));
      } else if (request.method == 'GET') {
        res.headers
          ..set(HttpHeaders.etagHeader, '"7"')
          ..set('X-Profile-Key-Id', 'a' * 32);
        res.add(List<int>.filled(4124, 1));
      } else {
        final sent = jsonDecode(utf8.decode(body)) as Map;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'versions': [
            for (final id in sent['channel_ids'] as List)
              {'kind': 'channel', 'id': id, 'version': 2, 'key_id': 'b' * 32},
            {'kind': 'bad'},
          ]
        }));
      }
      await res.close();
    });
    client =
        ApiClient(baseUrl: 'http://${server.address.address}:${server.port}');
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  test('put: first write, then If-Match, with the key id and the blob',
      () async {
    expect(
        await client.putInfoRecord('t',
            kind: 'category',
            subjectId: 'cat_1',
            communityId: 'comm_1',
            keyId: 'c' * 32,
            blob: const [1, 2, 3],
            expectedVersion: 0),
        3);
    expect(seen.last.uri.path, '/api/v1/communities/comm_1/categories/cat_1');
    expect(seen.last.headers.value('If-None-Match'), '*');
    expect(seen.last.headers.value('X-Profile-Key-Id'), 'c' * 32);
    expect(seen.last.headers.value('X-Private-Messenger-Encrypted'), '1');
    expect(bodies.last, [1, 2, 3]);
    await client.putInfoRecord('t',
        kind: 'community',
        subjectId: 'comm_1',
        keyId: 'c' * 32,
        blob: const [1],
        expectedVersion: 2);
    expect(seen.last.uri.path, '/api/v1/communities/comm_1/info');
    expect(seen.last.headers.value('If-Match'), '"2"');
    expect(seen.last.headers.value('If-None-Match'), isNull);
  });

  test('put: a stale version is a 412 ApiException', () async {
    await expectLater(
        client.putInfoRecord('t',
            kind: 'channel',
            subjectId: 'stale',
            keyId: 'c' * 32,
            blob: const [1],
            expectedVersion: 1),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 412)));
  });

  test('get: version and key id from the headers; 404 is none', () async {
    final got =
        await client.getInfoRecord('t', kind: 'channel', subjectId: 'chan_1');
    expect(seen.last.uri.path, '/api/v1/channels/chan_1/info');
    expect(got!.version, 7);
    expect(got.keyId, 'a' * 32);
    expect(got.blob.length, 4124);
    expect(
        await client.getInfoRecord('t', kind: 'channel', subjectId: 'missing'),
        isNull);
  });

  test('versions: three lists, malformed rows dropped', () async {
    final versions =
        await client.infoVersions('t', channelIds: const ['chan_x']);
    final sent = jsonDecode(utf8.decode(bodies.last)) as Map;
    expect(sent['channel_ids'], ['chan_x']);
    expect(sent['community_ids'], isEmpty);
    expect(versions.single.id, 'chan_x');
    expect(versions.single.version, 2);
  });

  test('versions: all 500 channels are queried in bounded batches', () async {
    final ids = List.generate(500, (index) => 'chan_$index');
    final versions = await client.infoVersions('t',
        communityIds: const ['comm_1'],
        categoryIds: const ['cat_1'],
        channelIds: ids);
    expect(versions.map((v) => v.id), ids);
    expect(bodies, hasLength(3));
    final batches =
        bodies.map((b) => jsonDecode(utf8.decode(b)) as Map).toList();
    expect(
        batches.map((b) => (b['channel_ids'] as List).length), [200, 200, 100]);
    expect(batches.first['community_ids'], ['comm_1']);
    expect(batches.first['category_ids'], ['cat_1']);
    expect(batches.last['community_ids'], isEmpty);
  });
}
