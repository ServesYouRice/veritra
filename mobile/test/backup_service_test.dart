import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/backup_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// Card I45 (T45C, QA05): the mobile backup pipeline with the real native
/// library and a loopback server: create, upload, restore, and the ways a
/// restore can fail without touching the device.
void main() {
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final skip = libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false;

  late _BackupServer server;
  late Directory scratch;
  late NativeCryptoBindings bindings;

  setUp(() async {
    if (libraryPath == null) return;
    bindings = NativeCryptoBindings.open(libraryPath);
    server = await _BackupServer.start();
    scratch = await Directory.systemTemp.createTemp('veritra-backup-');
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

  Future<String> makeBackup() async {
    final source = await _seededStore();
    final client = ApiClient(baseUrl: server.baseUrl);
    addTearDown(client.close);
    return serviceFor(source).createAndUpload(client, 'token');
  }

  Matcher failure(BackupFailureKind kind) =>
      isA<BackupException>().having((error) => error.kind, 'kind', kind);

  test('a backup restores identity, MLS state and decrypted history', () async {
    final code = await makeBackup();
    expect(code, startsWith('v1.'));
    final target = MemoryLocalStore();
    await serviceFor(target).recover(code);

    final session = await target.loadSession();
    expect(session?.accountId, 'acct_1');
    expect(session?.deviceId, 'dev_1');
    expect((await target.loadCryptoState())?.counter, 2);
    expect(await target.loadSyncCursor(), 7);
    final history = await target.loadMessages('conv_1');
    expect(history.single.body, 'kept across devices');
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('a wrong recovery code leaves the device untouched', () async {
    final code = await makeBackup();
    final parts = code.split('.');
    final wrongKey = '${parts[0]}.${parts[1]}.${parts[2]}.'
        '${'A' * parts[3].length}';
    final target = MemoryLocalStore();
    await expectLater(serviceFor(target).recover(wrongKey),
        throwsA(failure(BackupFailureKind.wrongKey)));
    expect(await target.loadSession(), isNull);
    await expectLater(serviceFor(target).recover('not a code'),
        throwsA(failure(BackupFailureKind.wrongKey)));
  }, skip: skip);

  test('a damaged backup is refused', () async {
    final code = await makeBackup();
    server.stored![0] ^= 0xff; // magic
    final target = MemoryLocalStore();
    await expectLater(serviceFor(target).recover(code),
        throwsA(failure(BackupFailureKind.corrupt)));
    expect(await target.loadSession(), isNull);
  }, skip: skip);

  test('a truncated backup is refused', () async {
    final code = await makeBackup();
    server.stored = server.stored!.sublist(0, server.stored!.length - 10);
    final target = MemoryLocalStore();
    await expectLater(serviceFor(target).recover(code),
        throwsA(failure(BackupFailureKind.corrupt)));
    expect(await target.loadSession(), isNull);
  }, skip: skip);

  test('an unknown or used code reports not found', () async {
    final code = await makeBackup();
    server.stored = null;
    await expectLater(serviceFor(MemoryLocalStore()).recover(code),
        throwsA(failure(BackupFailureKind.notFound)));
  }, skip: skip);

  test('an interrupted download continues after a restart', () async {
    final code = await makeBackup();
    server.dropAfterBytes = 40;
    final target = MemoryLocalStore();
    await expectLater(serviceFor(target).recover(code),
        throwsA(failure(BackupFailureKind.network)));
    expect(await target.loadSession(), isNull);
    // The partial download is kept for the next attempt.
    expect(scratch.listSync().whereType<File>(), isNotEmpty);

    server.dropAfterBytes = null;
    // A new service instance, as after an app restart.
    await serviceFor(target).recover(code);
    expect(server.rangeStarts.last, greaterThan(0));
    expect((await target.loadMessages('conv_1')).single.body,
        'kept across devices');
    expect(scratch.listSync(), isEmpty);
  }, skip: skip);

  test('a device that already has an account is not overwritten', () async {
    final code = await makeBackup();
    final target = MemoryLocalStore();
    await target.saveSession(const Session(
      baseUrl: 'https://chat.example.org',
      token: 'other',
      accountId: 'acct_other',
      deviceId: 'dev_other',
    ));
    await expectLater(serviceFor(target).recover(code),
        throwsA(failure(BackupFailureKind.deviceNotEmpty)));
    expect((await target.loadSession())?.accountId, 'acct_other');
  }, skip: skip);
}

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
  await store.commitMlsTransition(MlsStateTransition(
    messageId: 'application:7:srv_1',
    conversationId: 'conv_1',
    expectedCounter: 1,
    expectedCursor: 6,
    state: StoredCryptoState(
      counter: 2,
      stateKey: List<int>.filled(32, 3),
      sealedState: const <int>[4, 5, 6],
    ),
    cursor: 7,
    messageEffects: const <MessageEffect>[
      InsertMessageEffect(
        key: 'dev_2:action_1',
        serverMessageId: 'srv_1',
        conversationId: 'conv_1',
        senderAccountId: 'acct_2',
        senderDeviceId: 'dev_2',
        kind: LocalMessageKind.text,
        body: 'kept across devices',
        createdAt: 1,
        state: LocalMessageState.received,
      ),
    ],
  ));
  return store;
}

/// Plays the backup and recovery routes of the server.
class _BackupServer {
  _BackupServer._(this._server);

  final HttpServer _server;
  List<int>? stored;
  String? token;
  int? dropAfterBytes;
  final List<int> rangeStarts = <int>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_BackupServer> start() async {
    final server =
        _BackupServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
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
      if (data == null || request.headers.value('X-Recovery-Token') != token) {
        request.response
          ..statusCode = 404
          ..write('{"error":"not_found"}');
        await request.response.close();
        return;
      }
      var start = 0;
      final range = request.headers.value('Range');
      if (range != null) {
        start = int.parse(range.substring(6).split('-').first);
      }
      rangeStarts.add(start);
      final part = data.sublist(start);
      request.response.statusCode = start == 0 ? 200 : 206;
      request.response.contentLength = part.length;
      final drop = dropAfterBytes;
      if (drop != null && drop < part.length) {
        final socket = await request.response.detachSocket(writeHeaders: true);
        socket.add(part.sublist(0, drop));
        await socket.flush();
        socket.destroy();
        return;
      }
      request.response.add(part);
      await request.response.close();
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }
}
