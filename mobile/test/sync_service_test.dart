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

  WebSocketSyncService service({Duration? pingInterval}) =>
      WebSocketSyncService(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: 'session-token',
        pingInterval: pingInterval,
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

  test('a redirect is refused, so the token never follows it', () async {
    // dart:io copies Authorization to a redirect on the same host (and on
    // subdomains), so a 3xx would hand the bearer token to wherever the
    // server, or a proxy in front of it, points.
    final sync = service();
    final paths = <String>[];
    final failed = Completer<Object>();
    final subscription = sync.events.listen((_) {}, onError: (Object err) {
      if (!failed.isCompleted) failed.complete(err);
    });
    final served = requests.stream.listen((request) async {
      paths
          .add('${request.uri.path} ${request.headers.value('authorization')}');
      if (request.uri.path == '/api/v1/sync/ws') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/elsewhere');
        await request.response.close();
        return;
      }
      // The redirect target would accept the upgrade.
      final socket = await WebSocketTransformer.upgrade(request);
      unawaited(socket.drain<void>());
    });
    await sync.connect();
    final error = await failed.future.timeout(const Duration(seconds: 5));
    expect(error, isA<WebSocketException>());
    await sync.dispose();
    await subscription.cancel();
    await served.cancel();
    expect(paths, <String>['/api/v1/sync/ws Bearer session-token']);
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

  test(
      'a connection that goes silent after the handshake is dropped and '
      'reopened', () async {
    // Nothing closes the socket from the other side (no FIN, no reset): the
    // server upgrades, then stops reading, so a ping is never answered.
    final sync = service(pingInterval: const Duration(milliseconds: 300));
    final connected = <DateTime>[];
    final second = Completer<void>();
    final subscription = sync.events.listen((event) {
      if (event['type'] != 'sync.connected') return;
      connected.add(DateTime.now());
      if (connected.length == 2 && !second.isCompleted) second.complete();
    }, onError: (_) {});
    final silent = <WebSocket>[];
    final seen = requests.stream.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      if (silent.isEmpty) {
        // The first connection stops reading: pings go unanswered.
        silent.add(socket);
        socket.listen((_) {}).pause();
      } else {
        socket.drain<void>().ignore();
      }
    });
    addTearDown(seen.cancel);

    await sync.connect();
    await second.future.timeout(const Duration(seconds: 8),
        onTimeout: () => fail('the silent connection was never replaced'));
    expect(connected, hasLength(2));
    // The ping interval and one backoff, not the 60 s a half-open TCP
    // connection would otherwise keep the loop parked.
    expect(connected[1].difference(connected[0]),
        lessThan(const Duration(seconds: 6)));
    await sync.dispose();
    await subscription.cancel();
    for (final socket in silent) {
      await socket
          .close()
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
    }
  });

  test('a healthy connection that answers pings stays open', () async {
    final sync = service(pingInterval: const Duration(milliseconds: 200));
    var connectedEvents = 0;
    final subscription = sync.events.listen((event) {
      if (event['type'] == 'sync.connected') connectedEvents++;
    }, onError: (_) {});
    final seen = requests.stream.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      // dart:io answers pings by itself while the socket is read.
      socket.drain<void>().ignore();
    });
    addTearDown(seen.cancel);
    await sync.connect();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(connectedEvents, 1, reason: 'no needless reconnect');
    await sync.dispose();
    await subscription.cancel();
  });
}
