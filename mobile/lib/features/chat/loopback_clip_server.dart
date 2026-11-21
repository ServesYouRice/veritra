import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Serves one decrypted clip from memory to the platform audio player over
/// loopback HTTP (D134), for platforms whose player plugin cannot play bytes
/// directly (iOS, macOS, Linux).
///
/// The clip never touches disk. The server:
/// - binds to 127.0.0.1 only, on a random port;
/// - serves exactly one path, `/<32 random bytes, base64url>.<ext>`, which
///   lives as long as this server (a player makes several range requests, so
///   "one time" means one clip, not one request); every other path is 404;
/// - refuses a request whose `Host` is not that 127.0.0.1 port (DNS rebinding)
///   or whose peer is not loopback;
/// - sends `Cache-Control: no-store`, answers GET and HEAD, and supports byte
///   ranges (AVPlayer requires them);
/// - slices the bytes with views, so wiping them leaves no copy behind.
///
/// Call [close] as soon as playback ends, before wiping the bytes.
class LoopbackClipServer {
  LoopbackClipServer._(this._server, this._bytes, this._mimeType, this._path) {
    _sub = _server.listen(_handle, onError: (Object _) {});
  }

  /// Binds the server. Throws a [SocketException] where the platform refuses
  /// to listen (for example a sandbox without the server entitlement).
  static Future<LoopbackClipServer> start(
    Uint8List bytes, {
    String? mimeType,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = base64UrlEncode(
      Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256))),
    ).replaceAll('=', '');
    return LoopbackClipServer._(
      server,
      bytes,
      mimeType,
      '/$token${_extensionFor(mimeType)}',
    );
  }

  final HttpServer _server;
  final Uint8List _bytes;
  final String? _mimeType;
  final String _path;
  late final StreamSubscription<HttpRequest> _sub;
  bool _closed = false;

  /// Where the player fetches the clip.
  Uri get url => Uri(
        scheme: 'http',
        host: _server.address.address,
        port: _server.port,
        path: _path,
      );

  bool get isClosed => _closed;

  /// Stops listening and drops open connections. Safe to call twice.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    await _server.close(force: true);
  }

  static String _extensionFor(String? mimeType) {
    switch (mimeType?.toLowerCase()) {
      case 'audio/mp4':
      case 'audio/m4a':
      case 'audio/x-m4a':
        return '.m4a';
      case 'audio/wav':
      case 'audio/x-wav':
      case 'audio/wave':
        return '.wav';
      case 'audio/mpeg':
        return '.mp3';
      case 'audio/aac':
        return '.aac';
      case 'audio/ogg':
        return '.ogg';
      default:
        return '';
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      await _respond(request);
    } catch (_) {
      // A dropped connection is the player's seek or stop, not an error.
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _respond(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    final peer = request.connectionInfo?.remoteAddress;
    final expectedHost = '${_server.address.address}:${_server.port}';
    final host = request.headers.value(HttpHeaders.hostHeader);
    if (peer == null || !peer.isLoopback || host != expectedHost) {
      response.statusCode = HttpStatus.forbidden;
      return;
    }
    if (request.uri.path != _path || request.uri.hasQuery) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    final isHead = request.method == 'HEAD';
    if (!isHead && request.method != 'GET') {
      response.statusCode = HttpStatus.methodNotAllowed;
      response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      return;
    }
    final total = _bytes.length;
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(
        HttpHeaders.contentTypeHeader,
        _mimeType ?? 'application/octet-stream',
      );
    var start = 0;
    var end = total - 1;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final parsed = _parseRange(range, total);
      if (parsed == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        return;
      }
      start = parsed.$1;
      end = parsed.$2;
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$total',
      );
    }
    final length = end - start + 1;
    response.contentLength = length;
    if (isHead || length <= 0) return;
    response.add(Uint8List.sublistView(_bytes, start, end + 1));
  }

  /// A single `bytes=a-b`, `bytes=a-` or `bytes=-n` range, or null when it
  /// cannot be satisfied or is not understood.
  static (int, int)? _parseRange(String header, int total) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (match == null || total == 0) return null;
    final from = match.group(1)!;
    final to = match.group(2)!;
    if (from.isEmpty && to.isEmpty) return null;
    if (from.isEmpty) {
      final suffix = int.tryParse(to);
      if (suffix == null || suffix == 0) return null;
      return (max(0, total - suffix), total - 1);
    }
    final start = int.tryParse(from);
    if (start == null || start >= total) return null;
    final end = to.isEmpty ? total - 1 : int.tryParse(to);
    if (end == null || end < start) return null;
    return (start, min(end, total - 1));
  }
}
