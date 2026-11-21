import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Serves one decrypted clip from memory to the platform audio player over
/// loopback HTTP (D134), for platforms whose player plugin cannot play bytes
/// directly (iOS, macOS, Linux).
///
/// The clip never touches disk. The server:
/// - binds to 127.0.0.1 only, on a random port;
/// - serves exactly one path, `/<32 random bytes, base64url>.<ext>`, which
///   lives as long as this server (a player makes several range requests, so
///   "one time" means one clip, not one request); every other path is 404;
/// - compares that path in constant time;
/// - refuses a request whose `Host` is not exactly that 127.0.0.1 port (DNS
///   rebinding) or whose peer is not loopback;
/// - sends `Cache-Control: no-store`, answers GET and HEAD, and supports one
///   byte range per request (AVPlayer requires ranges);
/// - slices the caller's bytes with views and keeps no copy of its own, so
///   wiping them wipes what it serves. What was already sent still sits in
///   dart:io and kernel socket buffers and in the player's own buffers.
///
/// On Apple platforms this needs the `NSAllowsLocalNetworking` ATS key (iOS
/// and macOS) and the macOS `com.apple.security.network.server` sandbox
/// entitlement.
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
    final hosts = request.headers[HttpHeaders.hostHeader];
    if (peer == null ||
        !peer.isLoopback ||
        hosts == null ||
        hosts.length != 1 ||
        hosts.single != expectedHost) {
      response.statusCode = HttpStatus.forbidden;
      return;
    }
    if (!_sameSecret(request.uri.path, _path) || request.uri.hasQuery) {
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
    final range = parseRange(request.headers[HttpHeaders.rangeHeader], total);
    if (identical(range, unsatisfiableRange)) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
      return;
    }
    if (range != null) {
      (start, end) = range;
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

  /// Compares the requested path with the secret one without stopping at the
  /// first difference, so response timing does not reveal the token. The
  /// length is not secret.
  static bool _sameSecret(String given, String secret) {
    if (given.length != secret.length) return false;
    var diff = 0;
    for (var i = 0; i < secret.length; i++) {
      diff |= given.codeUnitAt(i) ^ secret.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// What [parseRange] returns for a range that cannot be satisfied (416).
  @visibleForTesting
  static const (int, int) unsatisfiableRange = (-1, -1);

  /// Larger than any clip; stands for a position too long to parse.
  static const int _huge = 1 << 52;

  /// The inclusive byte range to send for the `Range` header [values]
  /// (RFC 9110 section 14.2), for a clip of [total] bytes:
  /// - null to ignore the header and send the whole clip: no header, more
  ///   than one, no unit or one other than `bytes` (which must be ignored),
  ///   or a multi-range request;
  /// - [unsatisfiableRange] for a malformed or unsatisfiable `bytes` range;
  /// - otherwise `(start, end)`, with an end past the clip clamped to it and
  ///   a suffix longer than the clip meaning all of it.
  @visibleForTesting
  static (int, int)? parseRange(List<String>? values, int total) {
    if (values == null || values.length != 1) return null;
    final header = values.single.trim();
    final eq = header.indexOf('=');
    if (eq < 0) return null;
    if (header.substring(0, eq).trim().toLowerCase() != 'bytes') return null;
    final spec = header.substring(eq + 1).trim();
    if (spec.contains(',')) return null;
    final match = RegExp(r'^(\d*)-(\d*)$').firstMatch(spec);
    if (match == null || total <= 0) return unsatisfiableRange;
    final from = match.group(1)!;
    final to = match.group(2)!;
    if (from.isEmpty && to.isEmpty) return unsatisfiableRange;
    if (from.isEmpty) {
      final suffix = _number(to);
      if (suffix == 0) return unsatisfiableRange;
      return (max(0, total - suffix), total - 1);
    }
    final start = _number(from);
    if (start >= total) return unsatisfiableRange;
    final end = to.isEmpty ? total - 1 : _number(to);
    if (end < start) return unsatisfiableRange;
    return (start, min(end, total - 1));
  }

  /// A run of ASCII digits as a number, or [_huge] when it is too long for
  /// an exact int: such a position is past any clip either way.
  static int _number(String digits) {
    var i = 0;
    while (i < digits.length - 1 && digits.codeUnitAt(i) == 0x30) {
      i++;
    }
    final significant = digits.substring(i);
    return significant.length > 15 ? _huge : int.parse(significant);
  }
}
