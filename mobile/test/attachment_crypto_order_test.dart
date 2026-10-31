import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

/// The chunk index Dart passes to the bindings is the AEAD nonce suffix, so
/// the native tests cannot see a Dart bug that repeats it. These tests check
/// the index sequence, a fresh key and nonce prefix per attachment, and that
/// moved or repeated chunk frames do not decrypt (TASK-097).
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('attachment_order_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  const size = 2 * attachmentChunkSize + 1;
  final chunkCount =
      (paddedAttachmentSize(size) + attachmentChunkSize - 1) ~/
          attachmentChunkSize;

  AttachmentCryptoService serviceWith(NativeCryptoBindings bindings) =>
      AttachmentCryptoService(bindings, directoryProvider: () async => tempDir);

  Future<String> writeSource() async {
    final source = File('${tempDir.path}/source.bin');
    await source.writeAsBytes(
      Uint8List.fromList(List<int>.generate(size, (i) => (i * 31 + 7) & 0xff)),
    );
    return source.path;
  }

  Future<PreparedEncryptedAttachment> encrypt(
    AttachmentCryptoService service,
    String sourcePath,
  ) =>
      service.encryptFile(
        sourcePath: sourcePath,
        conversationId: 'conv_1',
        attachmentActionId: 'act_1',
        fileName: 'source.bin',
        mediaType: 'application/octet-stream',
      );

  /// Rewrites the ciphertext with frames 0 and 1 swapped, or with frame 0
  /// in place of frame 1.
  Future<void> rearrange(String path, {required bool swap}) async {
    final frames = _frames(await File(path).readAsBytes());
    expect(frames.length, chunkCount);
    final first = frames[0];
    frames[0] = swap ? frames[1] : frames[0];
    frames[1] = first;
    final out = BytesBuilder(copy: false);
    for (final frame in frames) {
      out.add((ByteData(4)..setUint32(0, frame.length)).buffer.asUint8List());
      out.add(frame);
    }
    await File(path).writeAsBytes(out.takeBytes());
  }

  Future<void> expectRefused(
    AttachmentCryptoService service,
    PreparedEncryptedAttachment prepared,
  ) async {
    final destination = '${tempDir.path}/out.bin';
    await expectLater(
      service.decryptFile(
        ciphertextPath: prepared.ciphertextPath,
        destinationPath: destination,
        manifest: prepared.manifest,
      ),
      throwsA(anything),
    );
    expect(File(destination).existsSync(), isFalse);
    expect(File('$destination.part').existsSync(), isFalse);
  }

  test('the test file spans three chunks', () {
    expect(chunkCount, 3);
  });

  test('chunks are encrypted and decrypted with indices 0..n-1 in order',
      () async {
    final bindings = _RecordingBindings();
    final service = serviceWith(bindings);
    final sourcePath = await writeSource();
    final prepared = await encrypt(service, sourcePath);
    expect(bindings.encrypted, List<int>.generate(chunkCount, (i) => i));
    expect(prepared.manifest['chunk_count'], chunkCount);

    final destination = '${tempDir.path}/out.bin';
    await service.decryptFile(
      ciphertextPath: prepared.ciphertextPath,
      destinationPath: destination,
      manifest: prepared.manifest,
    );
    expect(bindings.decrypted, List<int>.generate(chunkCount, (i) => i));
    expect(
      await File(destination).readAsBytes(),
      await File(sourcePath).readAsBytes(),
    );
  });

  test('each encryption uses a fresh key and nonce prefix', () async {
    final service = serviceWith(_RecordingBindings());
    final sourcePath = await writeSource();
    final first = await encrypt(service, sourcePath);
    final second = await encrypt(service, sourcePath);
    expect(base64Decode(first.manifest['key']! as String), hasLength(32));
    expect(base64Decode(first.manifest['nonce_prefix']! as String),
        hasLength(8));
    expect(first.manifest['key'], isNot(second.manifest['key']));
    expect(
        first.manifest['nonce_prefix'], isNot(second.manifest['nonce_prefix']));
    expect(first.ciphertextPath, isNot(second.ciphertextPath));
  });

  for (final swap in <bool>[true, false]) {
    final what = swap ? 'swapped' : 'duplicated';
    test('$what chunk frames do not decrypt', () async {
      final service = serviceWith(_RecordingBindings());
      final prepared = await encrypt(service, await writeSource());
      await rearrange(prepared.ciphertextPath, swap: swap);
      await expectRefused(service, prepared);
    });
  }

  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  group('with the native library', () {
    for (final swap in <bool>[true, false]) {
      final what = swap ? 'swapped' : 'duplicated';
      test('$what chunk frames do not decrypt', () async {
        final service = serviceWith(NativeCryptoBindings.open(libraryPath!));
        final sourcePath = await writeSource();
        final prepared = await encrypt(service, sourcePath);

        // Unchanged, it decrypts.
        final control = '${tempDir.path}/control.bin';
        await service.decryptFile(
          ciphertextPath: prepared.ciphertextPath,
          destinationPath: control,
          manifest: prepared.manifest,
        );
        expect(await File(control).readAsBytes(),
            await File(sourcePath).readAsBytes());

        await rearrange(prepared.ciphertextPath, swap: swap);
        await expectRefused(service, prepared);
      });
    }
  }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);
}

List<Uint8List> _frames(Uint8List bytes) {
  final frames = <Uint8List>[];
  var offset = 0;
  while (offset < bytes.length) {
    final length = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
    offset += 4;
    frames.add(Uint8List.fromList(bytes.sublist(offset, offset + length)));
    offset += length;
  }
  return frames;
}

/// A stand-in for AES-GCM that keeps its framing (16 bytes more than the
/// plaintext) and binds each frame to its key, nonce prefix, context and
/// chunk index, so a frame opens only at the index it was sealed with. It
/// records the indices in both directions.
class _RecordingBindings implements NativeCryptoBindings {
  final List<int> encrypted = <int>[];
  final List<int> decrypted = <int>[];

  static Uint8List _tag(
    List<int> key,
    List<int> noncePrefix,
    int chunkIndex,
    List<int> context,
  ) {
    int fingerprint(List<int> bytes) {
      var hash = 0x811c9dc5;
      for (final byte in bytes) {
        hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
      }
      return hash;
    }

    return (ByteData(16)
          ..setUint32(0, chunkIndex)
          ..setUint32(4, fingerprint(key))
          ..setUint32(8, fingerprint(noncePrefix))
          ..setUint32(12, fingerprint(context)))
        .buffer
        .asUint8List();
  }

  @override
  Uint8List encryptAttachmentChunk({
    required List<int> key,
    required List<int> noncePrefix,
    required int chunkIndex,
    required List<int> context,
    required List<int> plaintext,
  }) {
    encrypted.add(chunkIndex);
    return Uint8List.fromList(
      <int>[...plaintext, ..._tag(key, noncePrefix, chunkIndex, context)],
    );
  }

  @override
  Uint8List decryptAttachmentChunk({
    required List<int> key,
    required List<int> noncePrefix,
    required int chunkIndex,
    required List<int> context,
    required List<int> ciphertext,
  }) {
    decrypted.add(chunkIndex);
    if (ciphertext.length < 16) throw const FormatException('short frame');
    final body = ciphertext.length - 16;
    final expected = _tag(key, noncePrefix, chunkIndex, context);
    for (var i = 0; i < 16; i++) {
      if (ciphertext[body + i] != expected[i]) {
        throw const FormatException('attachment chunk authentication failed');
      }
    }
    return Uint8List.fromList(ciphertext.sublist(0, body));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
