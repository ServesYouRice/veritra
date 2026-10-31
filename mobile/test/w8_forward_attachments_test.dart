import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  for (final race in ['none', 'after-first', 'during-load']) {
    test('attachment forward memory privacy and session ownership: $race',
        () async {
      final dir = await Directory.systemTemp.createTemp('veritra-w8-forward-');
      final service = _MemoryOnlyAttachmentCrypto(
          NativeCryptoBindings.open(
              library ?? fail('CI must supply VERITRA_CRYPTO_LIBRARY')),
          dir);
      final input = File('${dir.path}/source.txt');
      final words = Uint8List.fromList(
          List.generate(attachmentChunkSize + 123, (i) => i % 251));
      words.setRange(0, 28, utf8.encode('private forwarded attachment'));
      await input.writeAsBytes(words);
      final source = await service.encryptFile(
          sourcePath: input.path,
          conversationId: 'source',
          attachmentActionId: 'source-action',
          fileName: 'source.txt',
          mediaType: 'text/plain');
      final originalCiphertext =
          await File(source.ciphertextPath).readAsBytes();
      final api = _ForwardApi(originalCiphertext),
          mls = _CapturingMls(),
          store = MemoryLocalStore();
      final state = AppState(
          apiClientFactory: (_) => api,
          cryptoService: mls,
          localStore: store,
          syncServiceFactory: (_, __) => _QuietSync(),
          attachmentService: service);
      addTearDown(() async {
        state.dispose();
        await source.cleanup();
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      state.session = const Session(
          baseUrl: 'https://example.test',
          token: 'token',
          accountId: 'alice',
          deviceId: 'dev');
      state.api = api;
      state.conversations = [
        for (final id in ['source', 'dest1', 'dest2'])
          Conversation(id: id, kind: 'group', createdBy: 'alice')
      ];
      await store.saveCryptoState(
          StoredCryptoState(
              counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
          0);
      await store.commitMlsTransition(MlsStateTransition(
          messageId: 'seed',
          conversationId: 'source',
          expectedCounter: 1,
          expectedCursor: 0,
          state: StoredCryptoState(
              counter: 2, stateKey: List.filled(32, 1), sealedState: [2]),
          cursor: 1,
          messageEffects: [
            InsertMessageEffect(
                key: 'dev:source',
                conversationId: 'source',
                senderAccountId: 'alice',
                senderDeviceId: 'dev',
                kind: LocalMessageKind.attachment,
                body: jsonEncode([
                  {
                    ...source.manifest,
                    'id': 'original',
                    'ciphertext_size': source.ciphertextLength
                  }
                ]),
                createdAt: 1,
                state: LocalMessageState.received),
          ]));
      await state.refreshHistory('source');
      void switchSession() {
        state.session = const Session(
            baseUrl: 'https://example.test',
            token: 'different-token',
            accountId: 'mallory',
            deviceId: 'different-device');
      }

      if (race == 'after-first') api.afterFirstSend = switchSession;
      if (race == 'during-load') service.afterDecrypt = switchSession;
      service.memoryForwardOnly = true;
      expect(
          await state.forwardMessage(
              state.historyFor('source').forKey('dev:source')!,
              ['dest1', 'dest2']),
          race == 'none');
      final count = race == 'none'
          ? 2
          : race == 'after-first'
              ? 1
              : 0;
      expect(service.encryptMemoryCalls, count);
      expect(service.decryptMemoryCalls, race == 'during-load' ? 1 : count);
      expect(
          service.buffers.every((buffer) => buffer.every((byte) => byte == 0)),
          true,
          reason: 'forwarded plaintext buffers must be wiped');
      service.memoryForwardOnly = false;
      expect(api.uploads, hasLength(count));
      expect(mls.bodies, hasLength(count));
      expect(api.tokens.every((token) => token == 'token'), true);
      if (race != 'none') return;
      final keys = <String>{source.manifest['key'] as String};
      for (var i = 0; i < 2; i++) {
        final body = mls.bodies[i];
        expect(body.keys.toSet(), {'attachments', 'forwarded'});
        expect(body['forwarded'], {'hops': 1});
        final manifest = Map<String, Object?>.from(
            (body['attachments'] as List).single as Map);
        expect(keys.add(manifest['key'] as String), true);
        expect(manifest['conversation_id'], 'dest${i + 1}');
        expect(manifest['id'], 'new-${i + 1}');
        expect(api.uploads[i], isNot(originalCiphertext));
        expect(latin1.decode(api.uploads[i]),
            isNot(contains('private forwarded attachment')));
        final ciphertext = File('${dir.path}/check-$i.ciphertext')
          ..writeAsBytesSync(api.uploads[i]);
        final plaintext = File('${dir.path}/check-$i.plaintext');
        await service.decryptFile(
            ciphertextPath: ciphertext.path,
            destinationPath: plaintext.path,
            manifest: manifest);
        expect(await plaintext.readAsBytes(), words);
      }
      expect(api.uploads[0], isNot(api.uploads[1]));
      final tampered = List<int>.of(api.uploads.first)
        ..[api.uploads.first.length - 1] ^= 1;
      final tamperedFile = File('${dir.path}/tampered.ciphertext')
        ..writeAsBytesSync(tampered);
      final manifest = Map<String, Object?>.from(
          (mls.bodies.first['attachments'] as List).single as Map);
      await expectLater(
          service.decryptBytes(
              ciphertextPath: tamperedFile.path, manifest: manifest),
          throwsA(isA<NativeCryptoException>()));
      final beforeCancel =
          (await dir.list().map((f) => f.path).toList()).toSet();
      final canceled = AttachmentCancellationToken()..cancel();
      await expectLater(
          service.encryptBytes(
              plaintext: Uint8List.fromList(words),
              conversationId: 'dest1',
              attachmentActionId: 'canceled',
              fileName: 'source.txt',
              mediaType: 'text/plain',
              cancellation: canceled),
          throwsA(isA<FileSystemException>()));
      expect(
          (await dir.list().map((f) => f.path).toList()).toSet(), beforeCancel);
      expect(
          await dir
              .list()
              .where((f) => f.path.contains('.veritra-forward-'))
              .toList(),
          isEmpty);
    },
        skip: library == null && Platform.environment['CI'] != 'true'
            ? 'set VERITRA_CRYPTO_LIBRARY to exercise real attachment encryption'
            : false);
  }
}

class _MemoryOnlyAttachmentCrypto extends AttachmentCryptoService {
  _MemoryOnlyAttachmentCrypto(super.bindings, this.directory)
      : super(directoryProvider: () async => directory);
  final Directory directory;
  bool memoryForwardOnly = false;
  int encryptMemoryCalls = 0, decryptMemoryCalls = 0;
  final List<Uint8List> buffers = [];
  void Function()? afterDecrypt;
  Future<void> _audit() async {
    final files = await directory.list().toList();
    expect(
        files.where((f) =>
            !f.path.endsWith('.ciphertext') && !f.path.endsWith('source.txt')),
        isEmpty,
        reason: 'forwarding may create ciphertext temporary files only');
  }

  @override
  Future<PreparedEncryptedAttachment> encryptFile(
      {required String sourcePath,
      required String conversationId,
      required String attachmentActionId,
      required String fileName,
      required String mediaType,
      AttachmentCancellationToken? cancellation,
      int paddingLimit = maxPlaintextAttachmentBytes}) {
    expect(memoryForwardOnly, false,
        reason: 'forwarding must not create a plaintext source file');
    return super.encryptFile(
        sourcePath: sourcePath,
        conversationId: conversationId,
        attachmentActionId: attachmentActionId,
        fileName: fileName,
        mediaType: mediaType,
        cancellation: cancellation,
        paddingLimit: paddingLimit);
  }

  @override
  Future<void> decryptFile(
      {required String ciphertextPath,
      required String destinationPath,
      required Map<String, Object?> manifest,
      AttachmentCancellationToken? cancellation}) {
    expect(memoryForwardOnly, false,
        reason: 'forwarding must decrypt directly into memory');
    return super.decryptFile(
        ciphertextPath: ciphertextPath,
        destinationPath: destinationPath,
        manifest: manifest,
        cancellation: cancellation);
  }

  @override
  Future<PreparedEncryptedAttachment> encryptBytes(
      {required Uint8List plaintext,
      required String conversationId,
      required String attachmentActionId,
      required String fileName,
      required String mediaType,
      AttachmentCancellationToken? cancellation,
      int paddingLimit = maxPlaintextAttachmentBytes}) async {
    encryptMemoryCalls++;
    buffers.add(plaintext);
    if (memoryForwardOnly) await _audit();
    final result = await super.encryptBytes(
        plaintext: plaintext,
        conversationId: conversationId,
        attachmentActionId: attachmentActionId,
        fileName: fileName,
        mediaType: mediaType,
        cancellation: cancellation,
        paddingLimit: paddingLimit);
    if (memoryForwardOnly) await _audit();
    return result;
  }

  @override
  Future<Uint8List> decryptBytes(
      {required String ciphertextPath,
      required Map<String, Object?> manifest,
      AttachmentCancellationToken? cancellation}) async {
    decryptMemoryCalls++;
    if (memoryForwardOnly) await _audit();
    final result = await super.decryptBytes(
        ciphertextPath: ciphertextPath,
        manifest: manifest,
        cancellation: cancellation);
    if (memoryForwardOnly) await _audit();
    buffers.add(result);
    afterDecrypt?.call();
    return result;
  }
}

class _ForwardApi extends ApiClient {
  _ForwardApi(this.original) : super(baseUrl: 'https://example.test');
  final List<int> original;
  final List<List<int>> uploads = [];
  final List<String> tokens = [];
  void Function()? afterFirstSend;
  @override
  Future<Stream<List<int>>> downloadEncryptedAttachment(
          String token, String attachmentId) async =>
      Stream.value(original);
  @override
  Future<AttachmentEnvelope> uploadEncryptedAttachment(
      String token, String conversationId, Stream<List<int>> ciphertext,
      {required int ciphertextLength,
      required Map<String, Object?> cryptoMetadata}) async {
    tokens.add(token);
    uploads.add([await for (final chunk in ciphertext) ...chunk]);
    expect(cryptoMetadata.keys.toSet(), {'version', 'algorithm', 'chunk_size'});
    return AttachmentEnvelope(
        id: 'new-${uploads.length}',
        ownerAccountId: 'alice',
        conversationId: conversationId,
        storageKey: 'opaque',
        ciphertextSha256: 'unused',
        sizeBytes: ciphertextLength,
        createdAt: DateTime.now());
  }

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    tokens.add(token);
    if (uploads.length == 1) afterFirstSend?.call();
  }
}

class _CapturingMls implements MlsConversationCryptoService {
  final List<Map<String, Object?>> bodies = [];
  @override
  Future<MessageEnvelope> encryptPayload(
      String conversationId, AppPayloadType type, Map<String, Object?> body,
      {List<String> attachmentRefs = const [], String? draftText}) async {
    expect(type, AppPayloadType.attachmentManifest);
    bodies.add(body);
    return MessageEnvelope(
        conversationId: conversationId,
        idempotencyKey: 'new-${bodies.length}',
        ciphertext: [1],
        cryptoProtocol: 'mls10-openmls-v1',
        attachmentRefs: attachmentRefs);
  }

  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}
