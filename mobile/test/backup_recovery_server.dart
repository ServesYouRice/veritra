import 'dart:io';
import 'dart:typed_data';

/// Plays the server's backup and recovery routes, including its range
/// rules: a range that starts at or past the end is refused with 416, and a
/// missing backup or a wrong token is a 404. Mirrors the private server in
/// backup_resume_test.dart for the newer backup tests.
class BackupRecoveryServer {
  BackupRecoveryServer._(this._server);

  final HttpServer _server;
  List<int>? stored;
  String? token;
  final List<int> rangeStarts = <int>[];

  /// Clears [stored] once a transfer reaches its end, as the server uses up
  /// the recovery code.
  bool consumeOnComplete = false;

  /// Answers every recovery request with this status instead.
  int? recoveryStatus;

  /// Answers a range request with a 206 that lacks its Content-Range, as a
  /// broken proxy might.
  bool omitContentRange = false;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<BackupRecoveryServer> start() async {
    final server = BackupRecoveryServer._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    server._server.listen(server._handle);
    return server;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (request.method == 'POST' && path == '/api/v1/backups') {
      final body = BytesBuilder(copy: false);
      await for (final chunk in request) {
        body.add(chunk);
      }
      stored = body.takeBytes();
      token = request.headers.value('X-Recovery-Token');
      request.response
        ..statusCode = 201
        ..headers.contentType = ContentType.json
        ..write('{"backup":{}}');
      await request.response.close();
      return;
    }
    if (request.method == 'GET' && path == '/api/v1/recovery') {
      final data = stored;
      var start = 0;
      final range = request.headers.value('Range');
      if (range != null) {
        start = int.parse(range.substring(6).split('-').first);
      }
      rangeStarts.add(start);
      final forced = recoveryStatus;
      if (forced != null) {
        request.response.statusCode = forced;
        await request.response.close();
        return;
      }
      if (data == null || request.headers.value('X-Recovery-Token') != token) {
        request.response
          ..statusCode = 404
          ..write('{"error":"not_found"}');
        await request.response.close();
        return;
      }
      if (start >= data.length && range != null) {
        request.response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..write('{"error":"invalid_recovery_range"}');
        await request.response.close();
        return;
      }
      final part = data.sublist(start);
      request.response.statusCode = start == 0 ? 200 : 206;
      if (start != 0 && !omitContentRange) {
        request.response.headers.set(
            'Content-Range', 'bytes $start-${data.length - 1}/${data.length}');
      }
      request.response
        ..contentLength = part.length
        ..add(part);
      await request.response.close();
      if (consumeOnComplete) stored = null;
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }
}
