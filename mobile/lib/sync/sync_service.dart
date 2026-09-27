import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

abstract class SyncService {
  Stream<Map<String, Object?>> get events;
  Future<void> connect();

  /// Stops reconnecting and closes the socket. Completes once no
  /// authenticated socket remains open, including one whose handshake was
  /// still in flight.
  Future<void> dispose();
}

typedef SyncOwnerWork = Future<void> Function();

/// Serializes all event catch-up requests for one authenticated account.
///
/// The owner is deliberately transport-agnostic: realtime, foreground resume
/// and persisted push wakes all submit work here, while the callback performs
/// the ordered event/crypto/storage transaction. A request arriving during a
/// run is coalesced into one follow-up pass instead of starting a second owner.
class AccountSyncEngine {
  AccountSyncEngine({
    required this.isOwner,
    required this.work,
  });

  final bool Function() isOwner;
  final SyncOwnerWork work;
  bool _running = false;
  bool _requested = false;
  bool _disposed = false;
  Future<void>? _active;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  Future<void> request() {
    if (_disposed || !isOwner()) return Future<void>.value();
    final waiter = Completer<void>();
    _waiters.add(waiter);
    if (_running) {
      _requested = true;
      return waiter.future;
    }
    final active = _run();
    _active = active;
    unawaited(active);
    return waiter.future;
  }

  /// Requests one follow-up pass without making the current owner wait on
  /// itself. This is used when a newer durable wake arrives mid-pass.
  void markRequested() {
    if (!_disposed && isOwner()) _requested = true;
  }

  Future<void> _run() async {
    _running = true;
    Object? failure;
    StackTrace? failureStack;
    try {
      do {
        _requested = false;
        if (_disposed || !isOwner()) break;
        await work();
      } while (_requested && !_disposed && isOwner());
    } catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    } finally {
      _running = false;
      final waiters = List<Completer<void>>.from(_waiters);
      _waiters.clear();
      for (final waiter in waiters) {
        if (waiter.isCompleted) continue;
        if (failure != null) {
          waiter.completeError(failure, failureStack);
        } else {
          waiter.complete();
        }
      }
    }
  }

  void dispose() {
    _disposed = true;
    _requested = false;
    if (!_running) {
      for (final waiter in _waiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _waiters.clear();
    }
  }

  Future<void> cancelAndDrain() async {
    dispose();
    await _active;
  }
}

class WebSocketSyncService implements SyncService {
  WebSocketSyncService({required this.baseUrl, required this.token});

  final String baseUrl;
  final String token;
  final _controller = StreamController<Map<String, Object?>>.broadcast();
  final _stopped = Completer<void>();
  WebSocket? _socket;
  HttpClient? _handshakeClient;
  bool _disposed = false;
  Future<void>? _connectLoop;
  Future<void>? _disposal;

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  /// Starts the reconnect loop and returns without waiting for a socket;
  /// connection progress is reported on [events].
  @override
  Future<void> connect() {
    if (!_disposed) _connectLoop ??= _runConnectLoop();
    return Future<void>.value();
  }

  Future<void> _runConnectLoop() async {
    var delay = const Duration(seconds: 1);
    final random = Random.secure();
    while (!_disposed) {
      try {
        final connectedFor = await _connectOnce();
        if (connectedFor >= const Duration(seconds: 30)) {
          delay = const Duration(seconds: 1);
        }
      } catch (err, stackTrace) {
        if (!_disposed && !_controller.isClosed) {
          _controller.addError(err, stackTrace);
        }
      }
      if (!_disposed) {
        final jitter = Duration(milliseconds: random.nextInt(750));
        // Wake early on dispose so teardown never waits out a backoff.
        await Future.any(<Future<void>>[
          Future<void>.delayed(delay + jitter),
          _stopped.future,
        ]);
        final nextSeconds = delay.inSeconds * 2;
        delay = Duration(seconds: nextSeconds > 30 ? 30 : nextSeconds);
      }
    }
  }

  Future<Duration> _connectOnce() async {
    final base = Uri.parse(baseUrl);
    final uri = base.resolve('/api/v1/sync/ws').replace(
          scheme: base.scheme == 'https' ? 'wss' : 'ws',
          query: null,
          fragment: null,
        );
    // A dedicated client lets dispose and the handshake timeout abort a
    // connect that is still in flight, so it cannot finish later and leave an
    // authenticated socket nobody listens to.
    final client = HttpClient();
    _handshakeClient = client;
    final WebSocket socket;
    try {
      // Send the token via the Authorization header so it never lands in
      // URLs, server access logs, or reverse-proxy logs.
      socket = await WebSocket.connect(
        uri.toString(),
        headers: <String, dynamic>{'Authorization': 'Bearer $token'},
        customClient: client,
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      client.close(force: true);
      rethrow;
    } finally {
      if (identical(_handshakeClient, client)) _handshakeClient = null;
    }
    // The upgraded socket is detached from the client; this only releases it.
    client.close();
    if (_disposed) {
      await _closeSocket(socket);
      return Duration.zero;
    }
    _socket = socket;
    final connectedAt = DateTime.now();
    // Events sent while the socket was down are not replayed over it. Tell
    // listeners a (re)connect happened so they catch up from their cursor.
    if (!_disposed && !_controller.isClosed) {
      _controller.add(const <String, Object?>{'type': 'sync.connected'});
    }
    final done = Completer<void>();
    socket.listen((data) {
      if (!_disposed && !_controller.isClosed && data is String) {
        try {
          _controller.add(Map<String, Object?>.from(jsonDecode(data) as Map));
        } catch (err, stackTrace) {
          _controller.addError(err, stackTrace);
        }
      }
    }, onDone: () {
      if (!done.isCompleted) {
        done.complete();
      }
    }, onError: (Object err, StackTrace stackTrace) {
      if (!_disposed && !_controller.isClosed) {
        _controller.addError(err, stackTrace);
      }
      if (!done.isCompleted) {
        done.complete();
      }
    }, cancelOnError: true);
    await done.future;
    _socket = null;
    return DateTime.now().difference(connectedAt);
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    if (!_stopped.isCompleted) _stopped.complete();
    _handshakeClient?.close(force: true);
    final socket = _socket;
    _socket = null;
    if (socket != null) await _closeSocket(socket);
    try {
      await _connectLoop;
    } catch (_) {
      // The loop reports failures on [events]; nothing is left to clean up.
    }
    await _controller.close();
  }

  /// Sends a normal-closure frame. dart:io destroys the connection itself if
  /// the server never answers; the timeout only bounds how long we wait.
  static Future<void> _closeSocket(WebSocket socket) async {
    try {
      await socket
          .close(WebSocketStatus.normalClosure)
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      // Already closed or the peer vanished; either way it is no longer open.
    }
  }
}
