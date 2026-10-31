import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/crypto/backup_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/local_store.dart';

/// The encrypted backup file authenticates its header and its last chunk
/// (TASK-044, D55): a file cut at a chunk boundary, with or without a
/// rewritten header, never reaches the store, and the legacy VBK1 format is
/// refused. See "Encrypted backup file (VBK2)" in docs/crypto.md.

const _chunk = 1024 * 1024;

/// Exports a fixed plaintext and records what a restore hands it.
class _PlainStore extends MemoryLocalStore {
  _PlainStore(this.plaintext);

  final List<int> plaintext;
  final List<List<int>> restored = <List<int>>[];

  @override
  Future<List<int>> exportBackup() async => List<int>.from(plaintext);

  @override
  Future<void> restoreBackup(List<int> encoded) async {
    restored.add(List<int>.from(encoded));
  }
}

List<int> _pattern(int length) =>
    List<int>.generate(length, (index) => (index * 31 + 7) & 0xff);

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
    scratch = await Directory.systemTemp.createTemp('veritra-backup-format-');
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

  /// Makes a backup of [size] plaintext bytes and returns its code.
  Future<(String, List<int>)> makeBackup(int size) async {
    final plaintext = _pattern(size);
    final source = _PlainStore(plaintext);
    await source.saveCryptoState(
      StoredCryptoState(
          counter: 3, stateKey: List<int>.filled(32, 3), sealedState: [1]),
      1,
    );
    final client = ApiClient(baseUrl: server.baseUrl);
    addTearDown(client.close);
    return (
      await serviceFor(source).createAndUpload(client, 'token'),
      plaintext
    );
  }

  ByteData header() =>
      ByteData.sublistView(Uint8List.fromList(server.stored!.sublist(0, 24)));

  test('a backup of several chunks restores byte for byte', () async {
    final (code, plaintext) = await makeBackup(2 * _chunk + 12345);
    expect(utf8.decode(server.stored!.sublist(0, 4)), 'VBK2');
    expect(header().getUint32(12), 3);
    expect(header().getUint64(16), plaintext.length);
    final target = _PlainStore(const <int>[]);
    await serviceFor(target).recover(code);
    expect(target.restored.single, plaintext);
  }, skip: skip);

  /// Byte offsets of each frame (its 4-byte length) after the header.
  List<int> frameStarts() {
    final data = server.stored!;
    final starts = <int>[];
    var offset = 24;
    while (offset < data.length) {
      starts.add(offset);
      final length = ByteData.sublistView(
              Uint8List.fromList(data.sublist(offset, offset + 4)))
          .getUint32(0);
      offset += 4 + length;
    }
    expect(offset, data.length);
    return starts;
  }

  test('a backup cut at a chunk boundary with a rewritten header is refused',
      () async {
    final (code, _) = await makeBackup(2 * _chunk + 12345);
    final starts = frameStarts();
    // Header frame, then three data frames: keep the first two data frames.
    expect(starts, hasLength(4));
    final cut = Uint8List.fromList(server.stored!.sublist(0, starts[3]));
    ByteData.sublistView(cut)
      ..setUint32(12, 2)
      ..setUint64(16, 2 * _chunk);
    server.stored = cut;
    final target = _PlainStore(const <int>[]);
    await expectLater(serviceFor(target).recover(code),
        throwsA(failure(BackupFailureKind.corrupt)));
    expect(target.restored, isEmpty);
  }, skip: skip);

  test('a backup missing its last chunk is refused', () async {
    final (code, _) = await makeBackup(2 * _chunk + 12345);
    server.stored = server.stored!.sublist(0, frameStarts()[3]);
    final target = _PlainStore(const <int>[]);
    await expectLater(serviceFor(target).recover(code),
        throwsA(failure(BackupFailureKind.corrupt)));
    expect(target.restored, isEmpty);
  }, skip: skip);

  test('any changed header byte makes the restore fail', () async {
    final (code, _) = await makeBackup(_chunk + 10);
    final original = List<int>.from(server.stored!);
    // magic, nonce, chunk count and plaintext size.
    for (final (offset, kind) in <(int, BackupFailureKind)>[
      (3, BackupFailureKind.corrupt),
      (4, BackupFailureKind.wrongKey),
      (11, BackupFailureKind.wrongKey),
      (15, BackupFailureKind.corrupt),
      (23, BackupFailureKind.corrupt),
    ]) {
      server.stored = List<int>.from(original)..[offset] ^= 0x01;
      final target = _PlainStore(const <int>[]);
      await expectLater(
          serviceFor(target).recover(code), throwsA(failure(kind)),
          reason: 'header byte $offset');
      expect(target.restored, isEmpty, reason: 'header byte $offset');
    }
    server.stored = original;
    final target = _PlainStore(const <int>[]);
    await serviceFor(target).recover(code);
    expect(target.restored, hasLength(1));
  }, skip: skip);

  test('a wrong recovery code is still told apart from a damaged file',
      () async {
    final (code, _) = await makeBackup(100);
    final parts = code.split('.');
    final wrongKey = '${parts[0]}.${parts[1]}.${parts[2]}.'
        '${'A' * parts[3].length}';
    final target = _PlainStore(const <int>[]);
    await expectLater(serviceFor(target).recover(wrongKey),
        throwsA(failure(BackupFailureKind.wrongKey)));
    expect(target.restored, isEmpty);
  }, skip: skip);

  test('the legacy VBK1 format is refused (D55)', () async {
    final (code, plaintext) = await makeBackup(100);
    final parts = code.split('.');
    final token = base64Url.decode(base64Url.normalize(parts[2]));
    final key = base64Url.decode(base64Url.normalize(parts[3]));
    // The VBK1 layout: magic, nonce, count and size in the clear, then each
    // chunk bound only to 'veritra-backup-v1' and the recovery token.
    final nonce = List<int>.filled(8, 9);
    final file = BytesBuilder()
      ..add(ascii.encode('VBK1'))
      ..add(nonce)
      ..add((ByteData(12)
            ..setUint32(0, 1)
            ..setUint64(4, plaintext.length))
          .buffer
          .asUint8List());
    final sealed = bindings.encryptAttachmentChunk(
      key: key,
      noncePrefix: nonce,
      chunkIndex: 0,
      context: <int>[...utf8.encode('veritra-backup-v1'), ...token],
      plaintext: plaintext,
    );
    file
      ..add((ByteData(4)..setUint32(0, sealed.length)).buffer.asUint8List())
      ..add(sealed);
    server.stored = file.takeBytes();
    final target = _PlainStore(const <int>[]);
    await expectLater(serviceFor(target).recover(code),
        throwsA(failure(BackupFailureKind.corrupt)));
    expect(target.restored, isEmpty);
  }, skip: skip);

  /// Builds a VBK2 file from the written description, so the description
  /// and the code are checked against each other. [finalFlags] overrides
  /// each data frame's final-chunk byte.
  List<int> buildVbk2(List<int> key, List<int> token, List<int> plaintext,
      {List<int>? finalFlags}) {
    final nonce = List<int>.generate(8, (index) => index + 1);
    final count = (plaintext.length + _chunk - 1) ~/ _chunk;
    final head = BytesBuilder()
      ..add(ascii.encode('VBK2'))
      ..add(nonce)
      ..add((ByteData(12)
            ..setUint32(0, count)
            ..setUint64(4, plaintext.length))
          .buffer
          .asUint8List());
    final headerBytes = head.takeBytes();
    final file = BytesBuilder()..add(headerBytes);
    void frame(List<int> sealed) => file
      ..add((ByteData(4)..setUint32(0, sealed.length)).buffer.asUint8List())
      ..add(sealed);
    frame(bindings.encryptAttachmentChunk(
      key: key,
      noncePrefix: nonce,
      chunkIndex: 0,
      context: <int>[
        ...utf8.encode('veritra-backup-v2-header'),
        ...token,
        ...headerBytes.sublist(0, 12),
      ],
      plaintext: headerBytes.sublist(12),
    ));
    for (var index = 0; index < count; index++) {
      final end = (index + 1) * _chunk;
      frame(bindings.encryptAttachmentChunk(
        key: key,
        noncePrefix: nonce,
        chunkIndex: index + 1,
        context: <int>[
          ...utf8.encode('veritra-backup-v2'),
          ...token,
          ...headerBytes,
          finalFlags?[index] ?? (index == count - 1 ? 1 : 0),
        ],
        plaintext: plaintext.sublist(
            index * _chunk, end > plaintext.length ? plaintext.length : end),
      ));
    }
    return file.takeBytes();
  }

  test('a file built from the format description restores', () async {
    final (code, _) = await makeBackup(100);
    final parts = code.split('.');
    final token = base64Url.decode(base64Url.normalize(parts[2]));
    final key = base64Url.decode(base64Url.normalize(parts[3]));
    final plaintext = _pattern(_chunk + 77);
    server.stored = buildVbk2(key, token, plaintext);
    final target = _PlainStore(const <int>[]);
    await serviceFor(target).recover(code);
    expect(target.restored.single, plaintext);
  }, skip: skip);

  test('a last chunk not sealed as last is refused', () async {
    final (code, _) = await makeBackup(100);
    final parts = code.split('.');
    final token = base64Url.decode(base64Url.normalize(parts[2]));
    final key = base64Url.decode(base64Url.normalize(parts[3]));
    for (final flags in <List<int>>[
      <int>[0, 0],
      <int>[1, 1],
    ]) {
      server.stored =
          buildVbk2(key, token, _pattern(_chunk + 77), finalFlags: flags);
      final target = _PlainStore(const <int>[]);
      await expectLater(serviceFor(target).recover(code),
          throwsA(failure(BackupFailureKind.corrupt)),
          reason: 'flags $flags');
      expect(target.restored, isEmpty);
    }
  }, skip: skip);
}

/// Plays the backup and recovery routes of the server.
class _BackupServer {
  _BackupServer._(this._server);

  final HttpServer _server;
  List<int>? stored;
  String? token;

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
      request.response
        ..statusCode = 200
        ..contentLength = data.length
        ..add(data);
      await request.response.close();
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }
}
