import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'native_crypto_bindings.dart';

const int attachmentChunkSize = 1024 * 1024;
const int maxPlaintextAttachmentBytes = 48 * 1024 * 1024;

/// The manifest version this app writes: version 2 pads the plaintext with
/// zeros to [paddedAttachmentSize] inside the encrypted chunks. Version 1
/// (no padding) still decrypts.
const int attachmentManifestVersion = 2;

/// The smallest padded attachment, as in Signal's `PaddingInputStream`.
const int minimumPaddedAttachmentBytes = 541;

/// The size an attachment of [size] bytes is padded to before encryption,
/// so the server sees a size bucket rather than the exact file size.
///
/// Signal's buckets (`PaddingInputStream.getPaddedSize`):
/// `max(541, floor(1.05^ceil(log_1.05(size))))`, that is the smallest
/// `floor(1.05^k)` that holds [size]: at most 5% overhead above 541 bytes.
/// The power is built by repeated multiplication, which IEEE 754 rounds the
/// same way on every platform, so every client picks the same buckets.
///
/// The result never exceeds [limit] (the largest attachment the server
/// accepts), so a file just under the cap is never refused for its padding,
/// and is never below [size]: a file over [limit] is left unpadded and is
/// refused by the size checks as before.
int paddedAttachmentSize(int size, {int limit = maxPlaintextAttachmentBytes}) {
  if (size <= 0) throw ArgumentError.value(size, 'size');
  var bucket = minimumPaddedAttachmentBytes;
  if (size > bucket) {
    var power = 1.0;
    while (power.floor() < size) {
      power *= 1.05;
    }
    bucket = power.floor();
  }
  final ceiling = min(limit, maxPlaintextAttachmentBytes);
  return max(size, min(bucket, ceiling));
}

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
  AttachmentCryptoService(
    this.bindings, {
    Future<Directory> Function()? directoryProvider,
  }) : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final NativeCryptoBindings bindings;
  final Future<Directory> Function() _directoryProvider;

  /// The private directory that holds temporary ciphertext and plaintext
  /// files while an attachment is encrypted, uploaded or opened.
  Future<Directory> workingDirectory() => _directoryProvider();

  Future<PreparedEncryptedAttachment> encryptFile({
    required String sourcePath,
    required String conversationId,
    required String attachmentActionId,
    required String fileName,
    required String mediaType,
    AttachmentCancellationToken? cancellation,
    int paddingLimit = maxPlaintextAttachmentBytes,
  }) async {
    cancellation?.throwIfCancelled();
    final input = await File(sourcePath).open(mode: FileMode.read);
    try {
      return await _encryptChunks(
        size: await input.length(),
        readChunk: (length) => _readExact(
          input,
          length,
          'attachment source changed during encryption',
        ),
        atEnd: () async => await input.readByte() == -1,
        conversationId: conversationId,
        attachmentActionId: attachmentActionId,
        fileName: fileName,
        mediaType: mediaType,
        cancellation: cancellation,
        paddingLimit: paddingLimit,
      );
    } finally {
      await input.close();
    }
  }

  /// For a decrypted forward already held in memory. Only ciphertext is
  /// written to a temporary file; no plaintext source file is created.
  Future<PreparedEncryptedAttachment> encryptBytes({
    required Uint8List plaintext,
    required String conversationId,
    required String attachmentActionId,
    required String fileName,
    required String mediaType,
    AttachmentCancellationToken? cancellation,
    int paddingLimit = maxPlaintextAttachmentBytes,
  }) {
    var offset = 0;
    return _encryptChunks(
      size: plaintext.length,
      readChunk: (length) async {
        final chunk = Uint8List.sublistView(plaintext, offset, offset + length);
        offset += length;
        return chunk;
      },
      atEnd: () async => offset == plaintext.length,
      conversationId: conversationId,
      attachmentActionId: attachmentActionId,
      fileName: fileName,
      mediaType: mediaType,
      cancellation: cancellation,
      paddingLimit: paddingLimit,
    );
  }

  /// Encrypts [size] source bytes followed by zeros up to the padded size
  /// (manifest version 2). Only the padded size is visible outside the
  /// manifest: the ciphertext length is `padded + chunks * 20`.
  Future<PreparedEncryptedAttachment> _encryptChunks({
    required int size,
    required Future<List<int>> Function(int length) readChunk,
    required Future<bool> Function() atEnd,
    required String conversationId,
    required String attachmentActionId,
    required String fileName,
    required String mediaType,
    AttachmentCancellationToken? cancellation,
    required int paddingLimit,
  }) async {
    final context = _attachmentContext(conversationId, attachmentActionId);
    cancellation?.throwIfCancelled();
    RandomAccessFile? sink;
    File? output;
    var ownsOutput = false;
    List<int>? key;
    var chunks = 0;
    var total = 0;
    var read = 0;
    try {
      if (size <= 0 || size > maxPlaintextAttachmentBytes) {
        throw const FileSystemException(
          'attachment size is outside allowed bounds',
        );
      }
      if (paddingLimit <= 0) {
        throw ArgumentError.value(paddingLimit, 'paddingLimit');
      }
      final padded = paddedAttachmentSize(size, limit: paddingLimit);
      final expectedChunks = _expectedChunkCount(padded);
      key = _randomBytes(32);
      final nonce = _randomBytes(8);
      final directory = await workingDirectory();
      output = File(
        '${directory.path}${Platform.pathSeparator}'
        '.attachment-${_randomHex(16)}.ciphertext',
      );
      await output.create(exclusive: true);
      ownsOutput = true;
      sink = await output.open(mode: FileMode.writeOnly);
      while (total < padded) {
        cancellation?.throwIfCancelled();
        final expectedLength = min(attachmentChunkSize, padded - total);
        final sourceLength = max(0, min(expectedLength, size - total));
        final List<int> plaintext;
        if (sourceLength == expectedLength) {
          plaintext = await readChunk(sourceLength);
        } else {
          // The chunk that ends the file, or one of padding only: the
          // source bytes, then zeros.
          final source =
              sourceLength > 0 ? await readChunk(sourceLength) : const <int>[];
          if (source.length != sourceLength) {
            throw const FileSystemException(
              'attachment source changed during encryption',
            );
          }
          plaintext = Uint8List(expectedLength)
            ..setRange(0, sourceLength, source);
        }
        read += sourceLength;
        cancellation?.throwIfCancelled();
        final encrypted = bindings.encryptAttachmentChunk(
          key: key,
          noncePrefix: nonce,
          chunkIndex: chunks,
          context: context,
          plaintext: plaintext,
        );
        if (encrypted.length != plaintext.length + 16) {
          throw const FormatException('invalid encrypted attachment framing');
        }
        cancellation?.throwIfCancelled();
        final length = ByteData(4)..setUint32(0, encrypted.length, Endian.big);
        await sink.writeFrom(length.buffer.asUint8List());
        await sink.writeFrom(encrypted);
        total += plaintext.length;
        chunks++;
      }
      if (!await atEnd() ||
          read != size ||
          total != padded ||
          chunks != expectedChunks) {
        throw const FileSystemException(
          'attachment source changed during encryption',
        );
      }
      cancellation?.throwIfCancelled();
      await sink.flush();
      await sink.close();
      sink = null;
      cancellation?.throwIfCancelled();
      final ciphertextLength = await output.length();
      final prepared = PreparedEncryptedAttachment(
        ciphertextPath: output.path,
        ciphertextLength: ciphertextLength,
        manifest: <String, Object?>{
          'version': attachmentManifestVersion,
          'algorithm': 'AES-256-GCM-chunked',
          'key': base64Encode(key),
          'nonce_prefix': base64Encode(nonce),
          'chunk_size': attachmentChunkSize,
          'chunk_count': chunks,
          'plaintext_size': size,
          'padded_size': padded,
          'conversation_id': conversationId,
          'action_id': attachmentActionId,
          'file_name': fileName,
          'media_type': mediaType,
        },
      );
      ownsOutput = false;
      return prepared;
    } catch (_) {
      await sink?.close();
      if (ownsOutput && output != null && await output.exists()) {
        await output.delete();
      }
      rethrow;
    } finally {
      key?.fillRange(0, key.length, 0);
    }
  }

  Future<void> decryptFile({
    required String ciphertextPath,
    required String destinationPath,
    required Map<String, Object?> manifest,
    AttachmentCancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final parsed = _parseAttachmentManifest(manifest);
    final key = parsed.key;
    RandomAccessFile? output;
    RandomAccessFile? authenticatedInput;
    final partial = File('$destinationPath.part');
    final destination = File(destinationPath);
    var ownsPartial = false;
    var ownsDestination = false;
    try {
      await _requireAbsent(destination.path);
      await _requireAbsent(partial.path);
      await partial.create(exclusive: true);
      ownsPartial = true;
      output = await partial.open(mode: FileMode.write);
      await _decryptChunks(
        ciphertextPath: ciphertextPath,
        parsed: parsed,
        writeChunk: output.writeFrom,
        cancellation: cancellation,
      );
      cancellation?.throwIfCancelled();
      await output.flush();
      await output.setPosition(0);
      authenticatedInput = output;
      output = null;

      await destination.create(exclusive: true);
      ownsDestination = true;
      output = await destination.open(mode: FileMode.writeOnly);
      var published = 0;
      while (true) {
        cancellation?.throwIfCancelled();
        final bytes = await authenticatedInput.read(attachmentChunkSize);
        if (bytes.isEmpty) break;
        await output.writeFrom(bytes);
        published += bytes.length;
      }
      if (published != parsed.plaintextSize) {
        throw const FormatException('attachment publication size mismatch');
      }
      cancellation?.throwIfCancelled();
      await output.flush();
      await output.close();
      output = null;
      await authenticatedInput.close();
      authenticatedInput = null;
      await partial.delete();
      ownsPartial = false;
      ownsDestination = false;
    } catch (_) {
      await output?.close();
      await authenticatedInput?.close();
      if (ownsDestination && await destination.exists()) {
        await destination.delete();
      }
      if (ownsPartial && await partial.exists()) await partial.delete();
      rethrow;
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  /// Publishes an authenticated attachment directly into memory. A failure
  /// wipes the partial result, and no plaintext file is ever created.
  Future<Uint8List> decryptBytes({
    required String ciphertextPath,
    required Map<String, Object?> manifest,
    AttachmentCancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final parsed = _parseAttachmentManifest(manifest);
    final plaintext = Uint8List(parsed.plaintextSize);
    var offset = 0;
    try {
      await _decryptChunks(
        ciphertextPath: ciphertextPath,
        parsed: parsed,
        cancellation: cancellation,
        writeChunk: (chunk) async {
          plaintext.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        },
      );
      return plaintext;
    } catch (_) {
      plaintext.fillRange(0, plaintext.length, 0);
      rethrow;
    } finally {
      parsed.key.fillRange(0, parsed.key.length, 0);
    }
  }

  Future<void> _decryptChunks({
    required String ciphertextPath,
    required _AttachmentManifest parsed,
    required Future<void> Function(List<int>) writeChunk,
    AttachmentCancellationToken? cancellation,
  }) async {
    final input = await File(ciphertextPath).open(mode: FileMode.read);
    var written = 0;
    var processed = 0;
    try {
      if (await input.length() != parsed.ciphertextSize)
        throw const FormatException('attachment framing mismatch');
      for (var index = 0; index < parsed.chunkCount; index++) {
        cancellation?.throwIfCancelled();
        final expectedPlaintextLength = min(
          attachmentChunkSize,
          parsed.paddedSize - processed,
        );
        final header = await _readExact(input, 4, 'truncated attachment');
        final length = ByteData.sublistView(
          Uint8List.fromList(header),
        ).getUint32(0, Endian.big);
        if (length != expectedPlaintextLength + 16)
          throw const FormatException('invalid attachment chunk length');
        final encrypted = await _readExact(
          input,
          length,
          'truncated attachment',
        );
        cancellation?.throwIfCancelled();
        final plaintext = bindings.decryptAttachmentChunk(
          key: parsed.key,
          noncePrefix: parsed.noncePrefix,
          chunkIndex: index,
          context: parsed.context,
          ciphertext: encrypted,
        );
        try {
          if (plaintext.length != expectedPlaintextLength)
            throw const FormatException('attachment size mismatch');
          // Bytes past plaintext_size are padding: authenticated with the
          // chunk, required to be zero, and never published.
          final keep = max(
            0,
            min(plaintext.length, parsed.plaintextSize - processed),
          );
          for (var i = keep; i < plaintext.length; i++) {
            if (plaintext[i] != 0)
              throw const FormatException('invalid attachment padding');
          }
          cancellation?.throwIfCancelled();
          if (keep == plaintext.length) {
            await writeChunk(plaintext);
          } else if (keep > 0) {
            final part = plaintext is Uint8List
                ? Uint8List.sublistView(plaintext, 0, keep)
                : plaintext.sublist(0, keep);
            try {
              await writeChunk(part);
            } finally {
              part.fillRange(0, part.length, 0);
            }
          }
          written += keep;
          processed += plaintext.length;
        } finally {
          plaintext.fillRange(0, plaintext.length, 0);
        }
      }
      if (await input.readByte() != -1 ||
          written != parsed.plaintextSize ||
          processed != parsed.paddedSize)
        throw const FormatException('attachment framing mismatch');
      cancellation?.throwIfCancelled();
    } finally {
      await input.close();
    }
  }
}

class _AttachmentManifest {
  const _AttachmentManifest({
    required this.key,
    required this.noncePrefix,
    required this.context,
    required this.chunkCount,
    required this.plaintextSize,
    required this.paddedSize,
    required this.ciphertextSize,
  });

  final Uint8List key;
  final Uint8List noncePrefix;
  final List<int> context;
  final int chunkCount;
  final int plaintextSize;

  /// Bytes encrypted: [plaintextSize] plus zero padding (version 2), or
  /// exactly [plaintextSize] (version 1).
  final int paddedSize;
  final int ciphertextSize;
}

_AttachmentManifest _parseAttachmentManifest(Map<String, Object?> manifest) {
  final version = manifest['version'];
  final algorithm = manifest['algorithm'];
  if (version is! int ||
      (version != 1 && version != 2) ||
      algorithm is! String ||
      algorithm != 'AES-256-GCM-chunked') {
    throw const FormatException('unsupported attachment manifest');
  }
  final keyValue = manifest['key'];
  final nonceValue = manifest['nonce_prefix'];
  final conversationId = manifest['conversation_id'];
  final actionId = manifest['action_id'];
  final chunkSize = manifest['chunk_size'];
  final chunkCount = manifest['chunk_count'];
  final plaintextSize = manifest['plaintext_size'];
  // Version 1 has no padding and must not claim any; version 2 must say
  // how much it encrypted. The receiver does not recompute the bucket: the
  // sender clamps it to its server's cap, which the receiver cannot know.
  final paddedValue = version == 2
      ? manifest['padded_size']
      : (manifest.containsKey('padded_size') ? null : plaintextSize);
  if (keyValue is! String ||
      nonceValue is! String ||
      conversationId is! String ||
      actionId is! String ||
      chunkSize is! int ||
      chunkCount is! int ||
      plaintextSize is! int ||
      paddedValue is! int) {
    throw const FormatException('invalid attachment manifest');
  }
  final paddedSize = paddedValue;

  Uint8List? key;
  var transferredKey = false;
  try {
    key = base64Decode(keyValue);
    final nonce = base64Decode(nonceValue);
    final context = _attachmentContext(conversationId, actionId);
    if (key.length != 32 ||
        nonce.length != 8 ||
        chunkSize != attachmentChunkSize ||
        plaintextSize <= 0 ||
        plaintextSize > maxPlaintextAttachmentBytes ||
        paddedSize < plaintextSize ||
        paddedSize > maxPlaintextAttachmentBytes ||
        chunkCount != _expectedChunkCount(paddedSize)) {
      throw const FormatException('invalid attachment manifest');
    }
    transferredKey = true;
    return _AttachmentManifest(
      key: key,
      noncePrefix: nonce,
      context: context,
      chunkCount: chunkCount,
      plaintextSize: plaintextSize,
      paddedSize: paddedSize,
      ciphertextSize: paddedSize + chunkCount * (4 + 16),
    );
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('invalid attachment manifest');
  } finally {
    if (!transferredKey) key?.fillRange(0, key.length, 0);
  }
}

List<int> _attachmentContext(String conversationId, String actionId) {
  if (conversationId.isEmpty ||
      actionId.isEmpty ||
      conversationId.contains('\u0000') ||
      actionId.contains('\u0000')) {
    throw const FormatException('invalid attachment context');
  }
  final context = utf8.encode('$conversationId\u0000$actionId');
  if (context.length > 512) {
    throw const FormatException('attachment context is too long');
  }
  return context;
}

int _expectedChunkCount(int plaintextSize) =>
    (plaintextSize + attachmentChunkSize - 1) ~/ attachmentChunkSize;

Future<Uint8List> _readExact(
  RandomAccessFile input,
  int length,
  String error,
) async {
  final result = BytesBuilder(copy: false);
  while (result.length < length) {
    final bytes = await input.read(length - result.length);
    if (bytes.isEmpty) throw FormatException(error);
    result.add(bytes);
  }
  return result.takeBytes();
}

Future<void> _requireAbsent(String path) async {
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException('attachment destination already exists', path);
  }
}

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

String _randomHex(int bytes) => _randomBytes(
      bytes,
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
