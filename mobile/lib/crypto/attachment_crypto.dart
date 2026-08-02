import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'native_crypto_bindings.dart';

const int attachmentChunkSize = 1024 * 1024;
const int maxPlaintextAttachmentBytes = 48 * 1024 * 1024;

class AttachmentCancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
  void throwIfCancelled() {
    if (_cancelled)
      throw const FileSystemException('attachment operation cancelled');
  }
}

class PreparedEncryptedAttachment {
  const PreparedEncryptedAttachment({
    required this.ciphertextPath,
    required this.ciphertextLength,
    required this.manifest,
  });

  final String ciphertextPath;
  final int ciphertextLength;
  final Map<String, Object?> manifest;

  Stream<List<int>> openRead() => File(ciphertextPath).openRead();
  Future<void> cleanup() async {
    final file = File(ciphertextPath);
    if (await file.exists()) await file.delete();
  }
}

class AttachmentCryptoService {
  AttachmentCryptoService(this.bindings);

  final NativeCryptoBindings bindings;

  Future<PreparedEncryptedAttachment> encryptFile({
    required String sourcePath,
    required String conversationId,
    required String attachmentActionId,
    required String fileName,
    required String mediaType,
    AttachmentCancellationToken? cancellation,
  }) async {
    final source = File(sourcePath);
    final size = await source.length();
    if (size <= 0 || size > maxPlaintextAttachmentBytes) {
      throw const FileSystemException(
          'attachment size is outside allowed bounds');
    }
    final key = _randomBytes(32);
    final nonce = _randomBytes(8);
    final context = utf8.encode('$conversationId\u0000$attachmentActionId');
    if (context.length > 512)
      throw const FormatException('attachment context is too long');
    final directory = await getApplicationSupportDirectory();
    final output = File('${directory.path}${Platform.pathSeparator}'
        '.attachment-${_randomHex(16)}.ciphertext');
    RandomAccessFile? sink;
    var chunks = 0;
    try {
      sink = await output.open(mode: FileMode.writeOnly);
      await for (final plaintext in source.openRead(0, size)) {
        cancellation?.throwIfCancelled();
        // File.openRead may emit smaller blocks; coalesce to the reviewed chunk
        // bound so framing is stable across platforms.
        for (var offset = 0;
            offset < plaintext.length;
            offset += attachmentChunkSize) {
          final end = min(offset + attachmentChunkSize, plaintext.length);
          final encrypted = bindings.encryptAttachmentChunk(
            key: key,
            noncePrefix: nonce,
            chunkIndex: chunks,
            context: context,
            plaintext: plaintext.sublist(offset, end),
          );
          final length = ByteData(4)
            ..setUint32(0, encrypted.length, Endian.big);
          await sink.writeFrom(length.buffer.asUint8List());
          await sink.writeFrom(encrypted);
          chunks++;
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final ciphertextLength = await output.length();
      return PreparedEncryptedAttachment(
        ciphertextPath: output.path,
        ciphertextLength: ciphertextLength,
        manifest: <String, Object?>{
          'version': 1,
          'algorithm': 'AES-256-GCM-chunked',
          'key': base64Encode(key),
          'nonce_prefix': base64Encode(nonce),
          'chunk_size': attachmentChunkSize,
          'chunk_count': chunks,
          'plaintext_size': size,
          'conversation_id': conversationId,
          'action_id': attachmentActionId,
          'file_name': fileName,
          'media_type': mediaType,
        },
      );
    } catch (_) {
      await sink?.close();
      if (await output.exists()) await output.delete();
      rethrow;
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  Future<void> decryptFile({
    required String ciphertextPath,
    required String destinationPath,
    required Map<String, Object?> manifest,
    AttachmentCancellationToken? cancellation,
  }) async {
    if (manifest['version'] != 1 ||
        manifest['algorithm'] != 'AES-256-GCM-chunked') {
      throw const FormatException('unsupported attachment manifest');
    }
    final key = base64Decode(manifest['key'] as String);
    final nonce = base64Decode(manifest['nonce_prefix'] as String);
    final conversationId = manifest['conversation_id'] as String;
    final actionId = manifest['action_id'] as String;
    final expectedChunks = (manifest['chunk_count'] as num).toInt();
    final expectedSize = (manifest['plaintext_size'] as num).toInt();
    if (key.length != 32 ||
        nonce.length != 8 ||
        expectedChunks <= 0 ||
        expectedSize <= 0 ||
        expectedSize > maxPlaintextAttachmentBytes) {
      throw const FormatException('invalid attachment manifest');
    }
    final context = utf8.encode('$conversationId\u0000$actionId');
    final input = await File(ciphertextPath).open();
    final partial = File('$destinationPath.part');
    RandomAccessFile? output;
    var written = 0;
    try {
      output = await partial.open(mode: FileMode.writeOnly);
      for (var index = 0; index < expectedChunks; index++) {
        cancellation?.throwIfCancelled();
        final header = await input.read(4);
        if (header.length != 4)
          throw const FormatException('truncated attachment');
        final length = ByteData.sublistView(Uint8List.fromList(header))
            .getUint32(0, Endian.big);
        if (length <= 16 || length > attachmentChunkSize + 16) {
          throw const FormatException('invalid attachment chunk length');
        }
        final encrypted = await input.read(length);
        if (encrypted.length != length)
          throw const FormatException('truncated attachment');
        final plaintext = bindings.decryptAttachmentChunk(
          key: key,
          noncePrefix: nonce,
          chunkIndex: index,
          context: context,
          ciphertext: encrypted,
        );
        written += plaintext.length;
        if (written > expectedSize)
          throw const FormatException('attachment size mismatch');
        await output.writeFrom(plaintext);
      }
      if ((await input.readByte()) != -1 || written != expectedSize) {
        throw const FormatException('attachment framing mismatch');
      }
      await output.flush();
      await output.close();
      output = null;
      await partial.rename(destinationPath);
    } catch (_) {
      await output?.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    } finally {
      await input.close();
      key.fillRange(0, key.length, 0);
    }
  }
}

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

String _randomHex(int bytes) => _randomBytes(bytes)
    .map((value) => value.toRadixString(16).padLeft(2, '0'))
    .join();
