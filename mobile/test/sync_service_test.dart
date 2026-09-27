import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/sync/sync_service.dart';

void main() {
  late HttpServer server;
  late StreamController<HttpRequest> requests;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = StreamController<HttpRequest>();
    server.listen(requests.add);
  });

  tearDown(() async {
    await requests.close();
    await server.close(force: true);
  });

  WebSocketSyncService service() => WebSocketSyncService(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: 'session-token',
      );

  test('authenticates by header and closes with a normal-closure frame',
      () async {
    final sync = service();
    final connected = sync.events.firstWhere(
      (event) => event['type'] == 'sync.connected',
    );
    await sync.connect();
    final request = await requests.stream.first;
    expect(request.uri.path, '/api/v1/sync/ws');
    expect(request.uri.query, isEmpty);
    expect(request.headers.value('authorization'), 'Bearer session-token');
    final socket = await WebSocketTransformer.upgrade(request);
    final serverDone = socket.drain<void>();
    await connected;

    await sync.dispose();

    await serverDone.timeout(const Duration(seconds: 5));
    expect(socket.closeCode, WebSocketStatus.normalClosure);
  });

  test('dispose during an in-flight handshake leaves no open socket', () async {
    final sync = service();
    var connectedEvents = 0;
    final subscription = sync.events.listen(
      (event) {
        if (event['type'] == 'sync.connected') connectedEvents++;
      },
      onError: (_) {},
    );
    await sync.connect();
    final request = await requests.stream.first;

    final stopwatch = Stopwatch()..start();
    await sync.dispose();
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));

    // The server finishes the upgrade only after the client gave up. The
    // aborted connection must never surface as a live socket.
    WebSocket? upgraded;
    try {
      upgraded = await WebSocketTransformer.upgrade(request);
    } on Object {
      upgraded = null;
    }
    if (upgraded != null) {
      await upgraded.drain<void>().timeout(const Duration(seconds: 5));
    }
    expect(connectedEvents, 0);
    await subscription.cancel();
  });

  test('dispose does not wait out the reconnect backoff', () async {
    final sync = service();
    final failed = Completer<void>();
    final subscription = sync.events.listen((_) {}, onError: (_) {
      if (!failed.isCompleted) failed.complete();
    });
    await sync.connect();
    final request = await requests.stream.first;
    request.response.statusCode = HttpStatus.unauthorized;
    await request.response.close();
    await failed.future.timeout(const Duration(seconds: 5));

    final stopwatch = Stopwatch()..start();
    await sync.dispose();
    // The first backoff is at least one second.
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 800)));
    await subscription.cancel();
  });

  test('dispose is idempotent and connect after dispose is inert', () async {
    final sync = service();
    await sync.dispose();
    await sync.dispose();
    await sync.connect();
    final arrived = await requests.stream
        .map((_) => true)
        .first
        .timeout(const Duration(milliseconds: 300), onTimeout: () => false);
    expect(arrived, isFalse);
  });
}
