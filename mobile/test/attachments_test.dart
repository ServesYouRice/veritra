import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/attachments.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// Stage 1: encrypted attachments in demo builds.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('attachments_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => tempDir.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('manifest entries', () {
    test('a valid entry parses and names its file safely', () {
      final entry = AttachmentEntry.tryParse(
        _entry(name: '../../etc/pass\u0007wd.png'),
        conversationId: 'conv_1',
      );
      expect(entry, isNotNull);
      expect(entry!.fileName, 'passwd.png');
      expect(entry.isImage, isTrue);
      expect(entry.id, 'att_1');
    });

    test('an entry for another conversation is refused', () {
      expect(AttachmentEntry.tryParse(_entry(), conversationId: 'conv_other'),
          isNull);
    });

    test('malformed sizes, ids and bodies are refused', () {
      expect(AttachmentEntry.tryParse(_entry(plain: 0)), isNull);
      expect(
          AttachmentEntry.tryParse(
              _entry(plain: maxPlaintextAttachmentBytes + 1)),
          isNull);
      expect(AttachmentEntry.tryParse(_entry(cipher: 10, plain: 10)), isNull);
      expect(AttachmentEntry.tryParse(<String, Object?>{..._entry(), 'id': ''}),
          isNull);
      expect(AttachmentEntry.tryParse('not a map'), isNull);
      expect(AttachmentEntry.listFromBody('{not json'), isEmpty);
      expect(AttachmentEntry.listFromBody(jsonEncode(<Object?>[_entry(), 3])),
          hasLength(1));
    });

    test('media types come from the picker or a known extension', () {
      expect(attachmentMediaType('a.JPG', null), 'image/jpeg');
      expect(attachmentMediaType('a.bin', ''), 'application/octet-stream');
      expect(attachmentMediaType('a.png', 'Image/PNG'), 'image/png');
      expect(safeAttachmentName('...'), 'attachment');
      expect(safeAttachmentName('x' * 200 + '.pdf').length, 120);
      expect(safeAttachmentName('x' * 200 + '.pdf'), endsWith('.pdf'));
    });
  });

  test('a received manifest becomes an attachment row, not an action', () {
    final effects = messageEffectsFor(
      DecryptedAppPayload(
        type: AppPayloadType.attachmentManifest,
        actionId: 'action_1',
        body: <String, Object?>{
          'attachments': <Object?>[_entry()],
        },
      ),
      conversationId: 'conv_1',
      senderAccountId: 'acct_peer',
      senderDeviceId: 'dev_peer',
      createdAt: 1,
      state: LocalMessageState.received,
    );
    final row = effects.single as InsertMessageEffect;
    expect(row.kind, LocalMessageKind.attachment);
    expect(AttachmentEntry.listFromBody(row.body, conversationId: 'conv_1'),
        hasLength(1));
  });

  test('sending uploads ciphertext only and sends the key over MLS', () async {
    final api = _AttachmentApi();
    final mls = _FakeMls();
    final crypto = _FakeAttachmentCrypto(tempDir);
    final state = _state(api, mls, crypto);
    final source = File('${tempDir.path}/photo.png')
      ..writeAsBytesSync(List<int>.filled(40, 7));

    final sent = await state.sendAttachment('conv_1',
        path: source.path, fileName: 'photo.png', mediaType: 'image/png');

    expect(sent, isTrue);
    expect(api.uploadedBytes, crypto.ciphertext);
    // The server sees the scheme only: no key, name or size.
    expect(api.uploadMetadata, attachmentUploadMetadata);
    expect(mls.type, AppPayloadType.attachmentManifest);
    expect(mls.attachmentRefs, <String>['att_server_1']);
    final entry = (mls.body!['attachments'] as List).single as Map;
    expect(entry['id'], 'att_server_1');
    expect(entry['key'], 'secret-key');
    expect(entry['ciphertext_size'], crypto.ciphertext.length);
    expect(entry['file_name'], 'photo.png');
    // The temporary ciphertext is gone once the manifest is queued.
    expect(File(crypto.lastCiphertextPath!).existsSync(), isFalse);
    expect(state.isBusy(Ops.attachment), isFalse);
    state.dispose();
  });

  test('a failed upload sends nothing and reports the error', () async {
    final api = _AttachmentApi()..uploadFailure = ApiException(413, '');
    final mls = _FakeMls();
    final crypto = _FakeAttachmentCrypto(tempDir);
    final state = _state(api, mls, crypto);
    final source = File('${tempDir.path}/big.bin')..writeAsBytesSync(<int>[1]);

    final sent = await state.sendAttachment('conv_1',
        path: source.path, fileName: 'big.bin');

    expect(sent, isFalse);
    expect(mls.type, isNull);
    expect(state.errorFor(Ops.attachment), isNotNull);
    expect(File(crypto.lastCiphertextPath!).existsSync(), isFalse);
    state.dispose();
  });

  test('loading downloads, decrypts in memory and leaves no files', () async {
    final api = _AttachmentApi();
    final crypto = _FakeAttachmentCrypto(tempDir);
    final state = _state(api, _FakeMls(), crypto);
    final entry = AttachmentEntry.tryParse(
        _entry(cipher: api.download.length, plain: 5))!;

    final bytes = await state.loadAttachment(entry);

    expect(bytes, <int>[104, 101, 108, 108, 111]);
    expect(crypto.decryptedCiphertext, api.download);
    expect(tempDir.listSync().where((item) => item.path.contains('.veritra-')),
        isEmpty);
    state.dispose();
  });

  test('a download of the wrong size is refused before decryption', () async {
    final api = _AttachmentApi();
    final crypto = _FakeAttachmentCrypto(tempDir);
    final state = _state(api, _FakeMls(), crypto);
    final entry = AttachmentEntry.tryParse(
        _entry(cipher: api.download.length + 1, plain: 5))!;

    await expectLater(state.loadAttachment(entry), throwsFormatException);
    expect(crypto.decryptedCiphertext, isNull);
    expect(tempDir.listSync().where((item) => item.path.contains('.veritra-')),
        isEmpty);
    state.dispose();
  });

  test('without the attachment service nothing is offered', () {
    final state = AppState(
      apiClientFactory: (url) => ApiClient(baseUrl: url),
      cryptoService: _FakeMls(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _QuietSync(),
    );
    expect(state.attachmentsAvailable, isFalse);
    state.dispose();
  });
}

Map<String, Object?> _entry({
  String name = 'photo.png',
  int plain = 1000,
  int cipher = 1020,
}) =>
    <String, Object?>{
      'version': 1,
      'algorithm': 'AES-256-GCM-chunked',
      'key': 'secret-key',
      'nonce_prefix': 'AAAAAAAAAAA=',
      'chunk_size': 1024 * 1024,
      'chunk_count': 1,
      'plaintext_size': plain,
      'conversation_id': 'conv_1',
      'action_id': 'action_att',
      'file_name': name,
      'media_type': 'image/png',
      'id': 'att_1',
      'ciphertext_size': cipher,
    };

AppState _state(
        _AttachmentApi api, _FakeMls mls, _FakeAttachmentCrypto crypto) =>
    AppState(
      apiClientFactory: (_) => api,
      cryptoService: mls,
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _QuietSync(),
      attachmentService: crypto,
    )
      ..session = const Session(
        baseUrl: 'https://chat.example.org',
        token: 'token',
        accountId: 'acct_me',
        deviceId: 'dev_me',
      )
      ..api = api
      ..conversations = <Conversation>[Conversation(id: 'conv_1', kind: 'dm')];

class _AttachmentApi extends ApiClient {
  _AttachmentApi() : super(baseUrl: 'https://chat.example.org');

  Object? uploadFailure;
  List<int>? uploadedBytes;
  Map<String, Object?>? uploadMetadata;
  final List<int> download = List<int>.generate(21, (index) => index);

  @override
  Future<AttachmentEnvelope> uploadEncryptedAttachment(
    String token,
    String conversationId,
    Stream<List<int>> ciphertext, {
    required int ciphertextLength,
    required Map<String, Object?> cryptoMetadata,
  }) async {
    final failure = uploadFailure;
    if (failure != null) throw failure;
    uploadedBytes = <int>[await for (final chunk in ciphertext) ...chunk];
    uploadMetadata = cryptoMetadata;
    return AttachmentEnvelope(
      id: 'att_server_1',
      ownerAccountId: 'acct_me',
      conversationId: conversationId,
      storageKey: 'blob',
      ciphertextSha256: 'sha',
      sizeBytes: ciphertextLength,
      createdAt: DateTime.utc(2026, 9, 25),
    );
  }

  @override
  Future<Stream<List<int>>> downloadEncryptedAttachment(
          String token, String attachmentId) async =>
      Stream<List<int>>.fromIterable(
          <List<int>>[download.sublist(0, 10), download.sublist(10)]);

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {}
}

class _FakeAttachmentCrypto implements AttachmentCryptoService {
  _FakeAttachmentCrypto(this.dir);

  final Directory dir;
  final List<int> ciphertext = List<int>.filled(56, 3);
  String? lastCiphertextPath;
  List<int>? decryptedCiphertext;

  @override
  Future<PreparedEncryptedAttachment> encryptFile({
    required String sourcePath,
    required String conversationId,
    required String attachmentActionId,
    required String fileName,
    required String mediaType,
    AttachmentCancellationToken? cancellation,
  }) async {
    final file = File('${dir.path}/$attachmentActionId.ciphertext')
      ..writeAsBytesSync(ciphertext);
    lastCiphertextPath = file.path;
    return PreparedEncryptedAttachment(
      ciphertextPath: file.path,
      ciphertextLength: ciphertext.length,
      manifest: <String, Object?>{
        'version': 1,
        'key': 'secret-key',
        'conversation_id': conversationId,
        'action_id': attachmentActionId,
        'plaintext_size': await File(sourcePath).length(),
        'file_name': fileName,
        'media_type': mediaType,
      },
    );
  }

  @override
  Future<Directory> workingDirectory() async => dir;

  @override
  Future<void> decryptFile({
    required String ciphertextPath,
    required String destinationPath,
    required Map<String, Object?> manifest,
    AttachmentCancellationToken? cancellation,
  }) async {
    decryptedCiphertext = await File(ciphertextPath).readAsBytes();
    await File(destinationPath).writeAsString('hello');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeMls implements MlsConversationCryptoService {
  AppPayloadType? type;
  Map<String, Object?>? body;
  List<String>? attachmentRefs;

  @override
  Future<MessageEnvelope> encryptPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    List<String> attachmentRefs = const <String>[],
  }) async {
    this.type = type;
    this.body = body;
    this.attachmentRefs = attachmentRefs;
    return MessageEnvelope(
      conversationId: conversationId,
      idempotencyKey: 'key_1',
      ciphertext: const <int>[1],
      cryptoProtocol: 'mls10-openmls-v1',
      attachmentRefs: attachmentRefs,
    );
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  void dispose() => _controller.close();
}
