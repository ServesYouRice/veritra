import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/backup_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/local_store.dart';

/// A recovery whose saved download the server will not continue (416, or
/// 404 once a finished transfer used up the code) first tries the saved
/// file, which may already be the whole backup, and only then downloads
/// once from the start (TASK-045).

const _partialName = '.veritra-recovery.partial';

Future<MemoryLocalStore> _seededStore() async {
  final store = MemoryLocalStore();
  await store.saveSession(const Session(
    baseUrl: 'https://chat.example.org',
    token: 'token',
    accountId: 'acct_1',
    deviceId: 'dev_1',
    deviceSecret: 'secret',
  ));
  await store.saveCryptoState(
    StoredCryptoState(
      counter: 1,
      stateKey: List<int>.filled(32, 3),
      sealedState: const <int>[1, 2, 3],
    ),
    6,
  );
  return store;
}

void main() {
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final skip = libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false;

  late _RecoveryServer server;
  late Directory scratch;
  late NativeCryptoBindings bindings;

  setUp(() async {
    if (libraryPath == null) return;
    bindings = NativeCryptoBindings.open(libraryPath);
    server = await _RecoveryServer.start();
    scratch = await Directory.systemTemp.createTemp('veritra-backup-resume-');
  });

  tearDown(() async {
    if (libraryPath == null) return;
    await server.close();
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  BackupService serviceFor(LocalStore store) => BackupService(
        bindings: bindings,
        localStore: store,
        directoryProvider: () async => scratch,
      );

  Matcher failure(BackupFailureKind kind) =>
      isA<BackupException>().having((error) => error.kind, 'kind', kind);

  Future<(String, List<int>)> makeBackup() async {
    final client = ApiClient(baseUrl: server.baseUrl);
    addTearDown(client.close);
    final code =
        await serviceFor(await _seededStore()).createAndUpload(client, 't');
    return (code, List<int>.from(server.stored!));
  }

  File partial() => File('${scratch.path}/$_partialName');

  test('a saved file that is already complete restores after a 416', () async {
    final (code, ciphertext) = await makeBackup();
    // A download that finished before the app stopped, restore not done.
    partial().writeAsBytesSync(ciphertext);
    final target = MemoryLocalStore();
    await serviceFor(target).recover(code);
    expect((await target.loadSession())?.deviceId, 'dev_1');
    // The one request asked to continue past the end; nothing downloaded
    // again.
    expect(server.rangeStarts, <int>[ciphertext.length]);
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('a saved complete file restores after its transfer used up the code',
      () async {
    final (code, ciphertext) = await makeBackup();
    partial().writeAsBytesSync(ciphertext);
    // The server cleared the capability when that transfer reached the end.
    server.stored = null;
    final target = MemoryLocalStore();
    await serviceFor(target).recover(code);
    expect((await target.loadSession())?.deviceId, 'dev_1');
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('a longer stale prefix from another backup is replaced once', () async {
    final (_, other) = await makeBackup();
    final (code, ciphertext) = await makeBackup();
    final stale = <int>[...other, ...List<int>.filled(64, 7)];
    expect(stale.length, greaterThan(ciphertext.length));
    partial().writeAsBytesSync(stale);
    final target = MemoryLocalStore();
    await serviceFor(target).recover(code);
    expect((await target.loadSession())?.deviceId, 'dev_1');
    // Refused past the end, then exactly one download from the start.
    expect(server.rangeStarts, <int>[stale.length, 0]);
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('an incomplete saved file with a used-up code is reported not found',
      () async {
    final (code, ciphertext) = await makeBackup();
    partial().writeAsBytesSync(ciphertext.sublist(0, 40));
    server.stored = null;
    final target = MemoryLocalStore();
    await expectLater(serviceFor(target).recover(code),
        throwsA(failure(BackupFailureKind.notFound)));
    expect(await target.loadSession(), isNull);
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('a saved file for a device that already has an account is kept',
      () async {
    final (code, ciphertext) = await makeBackup();
    partial().writeAsBytesSync(ciphertext);
    final target = await _seededStore();
    await expectLater(serviceFor(target).recover(code),
        throwsA(failure(BackupFailureKind.deviceNotEmpty)));
    expect(server.rangeStarts, isEmpty);
    expect(partial().existsSync(), isTrue);
  }, skip: skip);
}

/// Plays the server's backup and recovery routes, including its range
/// rules: a range that starts at or past the end is refused with 416.
class _RecoveryServer {
  _RecoveryServer._(this._server);

  final HttpServer _server;
  List<int>? stored;
  String? token;
  final List<int> rangeStarts = <int>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_RecoveryServer> start() async {
    final server = _RecoveryServer._(
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
      if (start != 0) {
        request.response.headers.set(
            'Content-Range', 'bytes $start-${data.length - 1}/${data.length}');
      }
      request.response
        ..contentLength = part.length
        ..add(part);
      await request.response.close();
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }
}
