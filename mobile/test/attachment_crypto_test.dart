import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('attachment_crypto_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (MethodCall methodCall) async {
      return tempDir.path;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('PreparedEncryptedAttachment cleanup deletes ciphertext file', () async {
    final file = File('${tempDir.path}/test_cleanup.ciphertext');
    await file.writeAsBytes([1, 2, 3, 4]);
    expect(await file.exists(), isTrue);

    final prepared = PreparedEncryptedAttachment(
      ciphertextPath: file.path,
      ciphertextLength: 4,
      manifest: const {'version': 1},
    );
    await prepared.cleanup();
    expect(await file.exists(), isFalse);
  });

  test('AttachmentCancellationToken cancellation state and throwing', () {
    final token = AttachmentCancellationToken();
    expect(token.isCancelled, isFalse);
    token.throwIfCancelled(); // does not throw

    token.cancel();
    expect(token.isCancelled, isTrue);
    expect(() => token.throwIfCancelled(), throwsA(isA<FileSystemException>()));
  });

  test('decryptFile rejects invalid manifests before reading files', () async {
    final service = AttachmentCryptoService(_DummyBindings());
    final destPath = '${tempDir.path}/dest.txt';

    // Unsupported version
    await expectLater(
      service.decryptFile(
        ciphertextPath: '${tempDir.path}/missing.bin',
        destinationPath: destPath,
        manifest: {
          'version': 2,
          'algorithm': 'AES-256-GCM-chunked',
        },
      ),
      throwsA(isA<FormatException>()),
    );

    // Unsupported algorithm
    await expectLater(
      service.decryptFile(
        ciphertextPath: '${tempDir.path}/missing.bin',
        destinationPath: destPath,
        manifest: {
          'version': 1,
          'algorithm': 'ChaCha20-Poly1305',
        },
      ),
      throwsA(isA<FormatException>()),
    );

    // Invalid key length (not 32 bytes)
    await expectLater(
      service.decryptFile(
        ciphertextPath: '${tempDir.path}/missing.bin',
        destinationPath: destPath,
        manifest: {
          'version': 1,
          'algorithm': 'AES-256-GCM-chunked',
          'key': base64Encode(List.filled(16, 0)),
          'nonce_prefix': base64Encode(List.filled(8, 0)),
          'conversation_id': 'conv_1',
          'action_id': 'action_1',
          'chunk_count': 1,
          'plaintext_size': 10,
        },
      ),
      throwsA(isA<FormatException>()),
    );
  });

  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];

  group('real native attachment crypto pipeline', () {
    late AttachmentCryptoService service;

    setUp(() {
      if (libraryPath != null) {
        service =
            AttachmentCryptoService(NativeCryptoBindings.open(libraryPath));
      }
    });

    test('round-trip 1 byte plaintext encrypt and decrypt', () async {
      final sourceFile = File('${tempDir.path}/1byte.txt');
      await sourceFile.writeAsBytes([0x42]);
      final destFile = File('${tempDir.path}/1byte_decrypted.txt');

      final encrypted = await service.encryptFile(
        sourcePath: sourceFile.path,
        conversationId: 'conv_test_1',
        attachmentActionId: 'action_1',
        fileName: '1byte.txt',
        mediaType: 'text/plain',
      );

      expect(encrypted.ciphertextLength, greaterThan(1));
      expect(encrypted.manifest['version'], 1);
      expect(encrypted.manifest['algorithm'], 'AES-256-GCM-chunked');
      expect(encrypted.manifest['chunk_count'], 1);
      expect(encrypted.manifest['plaintext_size'], 1);

      await service.decryptFile(
        ciphertextPath: encrypted.ciphertextPath,
        destinationPath: destFile.path,
        manifest: encrypted.manifest,
      );

      expect(await destFile.exists(), isTrue);
      expect(await destFile.readAsBytes(), [0x42]);

      await encrypted.cleanup();
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);

    test(
        'tampered ciphertext fails decryption and leaves no destination or part file',
        () async {
      final sourceFile = File('${tempDir.path}/tamper_source.bin');
      await sourceFile.writeAsBytes(List.generate(100, (i) => i % 256));
      final destFile = File('${tempDir.path}/tamper_dest.bin');

      final encrypted = await service.encryptFile(
        sourcePath: sourceFile.path,
        conversationId: 'conv_tamper',
        attachmentActionId: 'action_tamper',
        fileName: 'tamper.bin',
        mediaType: 'application/octet-stream',
      );

      final ciphertextBytes =
          await File(encrypted.ciphertextPath).readAsBytes();
      // Tamper one byte in the payload
      ciphertextBytes[ciphertextBytes.length - 1] ^= 0xFF;
      final tamperedFile = File('${tempDir.path}/tampered.ciphertext');
      await tamperedFile.writeAsBytes(ciphertextBytes);

      await expectLater(
        service.decryptFile(
          ciphertextPath: tamperedFile.path,
          destinationPath: destFile.path,
          manifest: encrypted.manifest,
        ),
        throwsA(anything),
      );

      expect(await destFile.exists(), isFalse);
      expect(await File('${destFile.path}.part').exists(), isFalse);

      await encrypted.cleanup();
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);

    test('context mismatch fails decryption without destination file',
        () async {
      final sourceFile = File('${tempDir.path}/context_source.bin');
      await sourceFile.writeAsBytes([1, 2, 3, 4, 5]);
      final destFile = File('${tempDir.path}/context_dest.bin');

      final encrypted = await service.encryptFile(
        sourcePath: sourceFile.path,
        conversationId: 'conv_correct',
        attachmentActionId: 'action_correct',
        fileName: 'context.bin',
        mediaType: 'application/octet-stream',
      );

      // Wrong conversation_id in manifest
      final wrongManifest = Map<String, Object?>.from(encrypted.manifest);
      wrongManifest['conversation_id'] = 'conv_wrong';

      await expectLater(
        service.decryptFile(
          ciphertextPath: encrypted.ciphertextPath,
          destinationPath: destFile.path,
          manifest: wrongManifest,
        ),
        throwsA(anything),
      );

      expect(await destFile.exists(), isFalse);
      await encrypted.cleanup();
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);
  });
}

class _DummyBindings implements NativeCryptoBindings {
  @override
  Uint8List decryptAttachmentChunk({
    required List<int> key,
    required List<int> noncePrefix,
    required int chunkIndex,
    required List<int> context,
    required List<int> ciphertext,
  }) =>
      Uint8List(0);

  @override
  Uint8List encryptAttachmentChunk({
    required List<int> key,
    required List<int> noncePrefix,
    required int chunkIndex,
    required List<int> context,
    required List<int> plaintext,
  }) =>
      Uint8List(0);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
