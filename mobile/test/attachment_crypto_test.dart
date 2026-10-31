import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
    final valid = _manifest(plaintextSize: 10);
    final invalid = <Map<String, Object?>>[
      {...valid, 'version': 2},
      {...valid, 'version': 1.0},
      {...valid, 'algorithm': 'ChaCha20-Poly1305'},
      {...valid, 'algorithm': 1},
      {...valid, 'key': 'not-base64!'},
      {...valid, 'key': base64Encode(List<int>.filled(16, 0))},
      {...valid, 'nonce_prefix': base64Encode(List<int>.filled(7, 0))},
      {...valid, 'chunk_size': attachmentChunkSize - 1},
      {...valid, 'chunk_count': 2},
      {...valid, 'chunk_count': 1.0},
      {...valid, 'plaintext_size': 0},
      {...valid, 'plaintext_size': maxPlaintextAttachmentBytes + 1},
      {...valid, 'conversation_id': 'conv\u0000ambiguous'},
      {...valid, 'action_id': ''},
      {...valid, 'conversation_id': List<String>.filled(512, 'c').join()},
      // Version 1 has no padding; version 2 must state it, within bounds.
      {...valid, 'padded_size': 10},
      {...valid, 'padded_size': 541},
      {...valid, 'version': 2, 'padded_size': 9},
      {...valid, 'version': 2, 'padded_size': '541'},
      {...valid, 'version': 2, 'padded_size': maxPlaintextAttachmentBytes + 1},
      {
        ...valid,
        'version': 2,
        'padded_size': attachmentChunkSize + 1,
        'chunk_count': 1,
      },
    ];

    for (final manifest in invalid) {
      await expectLater(
        service.decryptFile(
          ciphertextPath: '${tempDir.path}/missing.bin',
          destinationPath: destPath,
          manifest: manifest,
        ),
        throwsA(isA<FormatException>()),
      );
    }
    expect(await File(destPath).exists(), isFalse);
  });

  test('encryptFile rejects size, context, and pre-cancellation bounds',
      () async {
    final service = AttachmentCryptoService(_DummyBindings());
    final empty = File('${tempDir.path}/empty.bin');
    await empty.create();
    await expectLater(
      service.encryptFile(
        sourcePath: empty.path,
        conversationId: 'conv',
        attachmentActionId: 'action',
        fileName: 'empty.bin',
        mediaType: 'application/octet-stream',
      ),
      throwsA(isA<FileSystemException>()),
    );

    final oversized = File('${tempDir.path}/oversized.bin');
    final oversizedHandle = await oversized.open(mode: FileMode.write);
    await oversizedHandle.truncate(maxPlaintextAttachmentBytes + 1);
    await oversizedHandle.close();
    await expectLater(
      service.encryptFile(
        sourcePath: oversized.path,
        conversationId: 'conv',
        attachmentActionId: 'action',
        fileName: 'oversized.bin',
        mediaType: 'application/octet-stream',
      ),
      throwsA(isA<FileSystemException>()),
    );

    final source = File('${tempDir.path}/source.bin');
    await source.writeAsBytes([1]);
    await expectLater(
      service.encryptFile(
        sourcePath: source.path,
        conversationId: 'conv\u0000ambiguous',
        attachmentActionId: 'action',
        fileName: 'source.bin',
        mediaType: 'application/octet-stream',
      ),
      throwsA(isA<FormatException>()),
    );
    final cancelled = AttachmentCancellationToken()..cancel();
    await expectLater(
      service.encryptFile(
        sourcePath: source.path,
        conversationId: 'conv',
        attachmentActionId: 'action',
        fileName: 'source.bin',
        mediaType: 'application/octet-stream',
        cancellation: cancelled,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await _attachmentArtifacts(tempDir), isEmpty);
  });

  group('padding buckets', () {
    // Signal's formula, PaddingInputStream.getPaddedSize.
    int signal(int size) =>
        max(541, pow(1.05, (log(size) / log(1.05)).ceil()).floor());

    test('small files pad to the 541-byte minimum', () {
      for (final size in <int>[1, 2, 100, 540, 541]) {
        expect(paddedAttachmentSize(size), 541, reason: '$size');
      }
      expect(paddedAttachmentSize(542), greaterThan(541));
      expect(() => paddedAttachmentSize(0), throwsArgumentError);
    });

    test(
        'every bucket up to the cap holds itself, costs at most 5%, '
        'and the next byte moves up', () {
      final buckets = _buckets();
      expect(buckets.first, 541);
      expect(buckets.last, maxPlaintextAttachmentBytes);
      for (var i = 0; i < buckets.length; i++) {
        final bucket = buckets[i];
        expect(paddedAttachmentSize(bucket), bucket);
        if (i > 0) {
          final first = buckets[i - 1] + 1;
          expect(paddedAttachmentSize(first), bucket, reason: '$first');
          // At most 5% above the file it pads.
          expect(bucket, lessThanOrEqualTo(first * 1.05), reason: '$first');
        }
      }
    });

    test('is monotonic and never below the size', () {
      var previous = 0;
      for (var size = 1; size < 3 * attachmentChunkSize; size += 997) {
        final padded = paddedAttachmentSize(size);
        expect(padded, greaterThanOrEqualTo(size));
        expect(padded, greaterThanOrEqualTo(previous));
        previous = padded;
      }
    });

    test('matches Signal away from float edges', () {
      for (final size in <int>[600, 1000, 4096, 65536, 1000000, 20000000]) {
        expect(paddedAttachmentSize(size), signal(size), reason: '$size');
      }
    });

    test('stops at the server cap and never pads below the size', () {
      const limit = 10 * 1024 * 1024;
      const size = limit - 1000;
      expect(paddedAttachmentSize(size), greaterThan(limit));
      expect(paddedAttachmentSize(size, limit: limit), limit);
      expect(paddedAttachmentSize(limit, limit: limit), limit);
      // Over the cap: unpadded, and refused by the size checks as before.
      expect(paddedAttachmentSize(limit + 5, limit: limit), limit + 5);
      expect(paddedAttachmentSize(maxPlaintextAttachmentBytes - 1),
          maxPlaintextAttachmentBytes);
      expect(paddedAttachmentSize(1000, limit: 2 * maxPlaintextAttachmentBytes),
          paddedAttachmentSize(1000));
    });
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

    test('round-trips one byte and the one-MiB boundaries canonically',
        () async {
      for (final size in <int>[
        1,
        attachmentChunkSize - 1,
        attachmentChunkSize,
        attachmentChunkSize + 1,
      ]) {
        final sourceFile = File('${tempDir.path}/source_$size.bin');
        final plaintext = _patternBytes(size);
        await sourceFile.writeAsBytes(plaintext);
        final destFile = File('${tempDir.path}/decrypted_$size.bin');

        final encrypted = await service.encryptFile(
          sourcePath: sourceFile.path,
          conversationId: 'conv_boundary',
          attachmentActionId: 'action_$size',
          fileName: 'source_$size.bin',
          mediaType: 'application/octet-stream',
        );
        final padded = paddedAttachmentSize(size);
        final expectedChunks =
            (padded + attachmentChunkSize - 1) ~/ attachmentChunkSize;
        expect(encrypted.manifest['version'], 2);
        expect(encrypted.manifest['algorithm'], 'AES-256-GCM-chunked');
        expect(encrypted.manifest['chunk_size'], attachmentChunkSize);
        expect(encrypted.manifest['chunk_count'], expectedChunks);
        expect(encrypted.manifest['plaintext_size'], size);
        expect(encrypted.manifest['padded_size'], padded);
        expect(encrypted.ciphertextLength, padded + expectedChunks * 20);

        await service.decryptFile(
          ciphertextPath: encrypted.ciphertextPath,
          destinationPath: destFile.path,
          manifest: encrypted.manifest,
        );
        expect(await destFile.readAsBytes(), plaintext);
        await encrypted.cleanup();
      }
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
        throwsA(isA<NativeCryptoException>()),
      );

      expect(await destFile.exists(), isFalse);
      expect(await File('${destFile.path}.part').exists(), isFalse);

      await encrypted.cleanup();
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);

    test('wrong key, conversation, and action fail authentication', () async {
      final sourceFile = File('${tempDir.path}/context_source.bin');
      await sourceFile.writeAsBytes([1, 2, 3, 4, 5]);
      final encrypted = await service.encryptFile(
        sourcePath: sourceFile.path,
        conversationId: 'conv_correct',
        attachmentActionId: 'action_correct',
        fileName: 'context.bin',
        mediaType: 'application/octet-stream',
      );
      final wrongKey = base64Decode(encrypted.manifest['key']! as String);
      wrongKey[0] ^= 0xff;
      final mutations = <Map<String, Object?>>[
        {...encrypted.manifest, 'key': base64Encode(wrongKey)},
        {...encrypted.manifest, 'conversation_id': 'conv_wrong'},
        {...encrypted.manifest, 'action_id': 'action_wrong'},
      ];
      for (var index = 0; index < mutations.length; index++) {
        final destFile = File('${tempDir.path}/auth_dest_$index.bin');
        await expectLater(
          service.decryptFile(
            ciphertextPath: encrypted.ciphertextPath,
            destinationPath: destFile.path,
            manifest: mutations[index],
          ),
          throwsA(isA<NativeCryptoException>()),
        );
        expect(await destFile.exists(), isFalse);
        expect(await File('${destFile.path}.part').exists(), isFalse);
      }
      await encrypted.cleanup();
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);

    test('wrong chunk count and plaintext size fail closed', () async {
      final encrypted = await _encryptBytes(
        service,
        tempDir,
        'manifest_bounds',
        [1, 2, 3, 4, 5],
      );
      final mutations = <Map<String, Object?>>[
        {...encrypted.manifest, 'chunk_count': 2},
        // Shorter than the file: its last byte (5) would be padding.
        {...encrypted.manifest, 'plaintext_size': 4},
        {...encrypted.manifest, 'padded_size': 542},
        {...encrypted.manifest, 'plaintext_size': 542},
        {...encrypted.manifest, 'version': 1},
      ];
      for (var index = 0; index < mutations.length; index++) {
        final destination = '${tempDir.path}/manifest_dest_$index.bin';
        await expectLater(
          service.decryptFile(
            ciphertextPath: encrypted.ciphertextPath,
            destinationPath: destination,
            manifest: mutations[index],
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await File(destination).exists(), isFalse);
        expect(await File('$destination.part').exists(), isFalse);
      }
      await encrypted.cleanup();
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);

    test('truncation, extension, and non-canonical headers fail framing',
        () async {
      final encrypted = await _encryptBytes(
        service,
        tempDir,
        'framing',
        [1, 2, 3, 4, 5],
      );
      final ciphertext = await File(encrypted.ciphertextPath).readAsBytes();
      final badHeader = Uint8List.fromList(ciphertext);
      ByteData.sublistView(badHeader).setUint32(0, 22, Endian.big);
      final variants = <List<int>>[
        ciphertext.sublist(0, ciphertext.length - 1),
        <int>[...ciphertext, 0],
        badHeader,
      ];
      for (var index = 0; index < variants.length; index++) {
        final badFile = File('${tempDir.path}/bad_framing_$index.bin');
        await badFile.writeAsBytes(variants[index]);
        final destination = '${tempDir.path}/framing_dest_$index.bin';
        await expectLater(
          service.decryptFile(
            ciphertextPath: badFile.path,
            destinationPath: destination,
            manifest: encrypted.manifest,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await File(destination).exists(), isFalse);
        expect(await File('$destination.part').exists(), isFalse);
      }
      await encrypted.cleanup();
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);

    test('cancellation cleans only files owned by the operation', () async {
      final source = File('${tempDir.path}/cancel_source.bin');
      await source.writeAsBytes(_patternBytes(attachmentChunkSize + 1));
      final encryptToken = AttachmentCancellationToken();
      final cancellingEncrypt = AttachmentCryptoService(_CancellingBindings(
        delegate: service.bindings,
        token: encryptToken,
        cancelOnEncrypt: true,
      ));
      await expectLater(
        cancellingEncrypt.encryptFile(
          sourcePath: source.path,
          conversationId: 'conv_cancel',
          attachmentActionId: 'action_cancel_encrypt',
          fileName: 'cancel.bin',
          mediaType: 'application/octet-stream',
          cancellation: encryptToken,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await _attachmentArtifacts(tempDir), isEmpty);

      final encrypted = await _encryptBytes(
        service,
        tempDir,
        'cancel_decrypt',
        _patternBytes(attachmentChunkSize + 1),
      );
      final decryptToken = AttachmentCancellationToken();
      final cancellingDecrypt = AttachmentCryptoService(_CancellingBindings(
        delegate: service.bindings,
        token: decryptToken,
        cancelOnDecrypt: true,
      ));
      final destination = '${tempDir.path}/cancel_dest.bin';
      await expectLater(
        cancellingDecrypt.decryptFile(
          ciphertextPath: encrypted.ciphertextPath,
          destinationPath: destination,
          manifest: encrypted.manifest,
          cancellation: decryptToken,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(destination).exists(), isFalse);
      expect(await File('$destination.part').exists(), isFalse);

      final publicationDestination =
          File('${tempDir.path}/publication_cancel_dest.bin');
      final publicationToken =
          _CancelWhenDestinationExists(publicationDestination);
      await expectLater(
        service.decryptFile(
          ciphertextPath: encrypted.ciphertextPath,
          destinationPath: publicationDestination.path,
          manifest: encrypted.manifest,
          cancellation: publicationToken,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await publicationDestination.exists(), isFalse);
      expect(
        await File('${publicationDestination.path}.part').exists(),
        isFalse,
      );
      await encrypted.cleanup();
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);

    test('pre-existing destination and part files are preserved', () async {
      final encrypted = await _encryptBytes(
        service,
        tempDir,
        'existing',
        [1, 2, 3, 4, 5],
      );
      final destination = File('${tempDir.path}/existing_dest.bin');
      await destination.writeAsBytes([9, 8, 7]);
      await expectLater(
        service.decryptFile(
          ciphertextPath: encrypted.ciphertextPath,
          destinationPath: destination.path,
          manifest: encrypted.manifest,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await destination.readAsBytes(), [9, 8, 7]);

      final secondDestination = File('${tempDir.path}/part_dest.bin');
      final existingPart = File('${secondDestination.path}.part');
      await existingPart.writeAsBytes([6, 5, 4]);
      await expectLater(
        service.decryptFile(
          ciphertextPath: encrypted.ciphertextPath,
          destinationPath: secondDestination.path,
          manifest: encrypted.manifest,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await secondDestination.exists(), isFalse);
      expect(await existingPart.readAsBytes(), [6, 5, 4]);
      await encrypted.cleanup();
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);

    test('ciphertext length shows the bucket, not the file size', () async {
      // Without padding these lengths would all differ.
      final lengths = <int>[];
      for (final size in <int>[1, 300, 540, 541]) {
        final encrypted = await _encryptBytes(
            service, tempDir, 'bucket_$size', _patternBytes(size));
        lengths.add(encrypted.ciphertextLength);
        await encrypted.cleanup();
      }
      expect(lengths.toSet(), {541 + 20});

      final a = await _encryptBytes(
          service, tempDir, 'bucket_a', _patternBytes(100000));
      final b = await _encryptBytes(
          service, tempDir, 'bucket_b', _patternBytes(100001));
      expect(a.ciphertextLength, b.ciphertextLength);
      expect(a.ciphertextLength, paddedAttachmentSize(100000) + 20);
      await a.cleanup();
      await b.cleanup();
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);

    test('padded files round-trip exactly through files and memory', () async {
      for (final size in <int>[
        1,
        541,
        542,
        attachmentChunkSize - 3,
        attachmentChunkSize + 1,
      ]) {
        final plaintext = _patternBytes(size);
        final encrypted =
            await _encryptBytes(service, tempDir, 'exact_$size', plaintext);
        expect(encrypted.manifest['padded_size'], paddedAttachmentSize(size));
        final dest = File('${tempDir.path}/exact_dest_$size.bin');
        await service.decryptFile(
          ciphertextPath: encrypted.ciphertextPath,
          destinationPath: dest.path,
          manifest: encrypted.manifest,
        );
        expect(await dest.readAsBytes(), plaintext);
        expect(
          await service.decryptBytes(
              ciphertextPath: encrypted.ciphertextPath,
              manifest: encrypted.manifest),
          plaintext,
        );
        await encrypted.cleanup();
      }
      // From memory (forwarding) as well.
      final bytes = _patternBytes(70000);
      final forwarded = await service.encryptBytes(
        plaintext: bytes,
        conversationId: 'conv_forward',
        attachmentActionId: 'action_forward',
        fileName: 'forward.bin',
        mediaType: 'application/octet-stream',
      );
      expect(forwarded.ciphertextLength, paddedAttachmentSize(70000) + 20);
      expect(
        await service.decryptBytes(
            ciphertextPath: forwarded.ciphertextPath,
            manifest: forwarded.manifest),
        bytes,
      );
      await forwarded.cleanup();
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);

    test('padding stops at the server cap, inside its upload limit', () async {
      // A lower operator cap: a file just under it would pad past it.
      const limit = 2 * attachmentChunkSize;
      const size = limit - 100;
      expect(paddedAttachmentSize(size), greaterThan(limit));
      final source = File('${tempDir.path}/cap.bin');
      final plaintext = _patternBytes(size);
      await source.writeAsBytes(plaintext);
      final encrypted = await service.encryptFile(
        sourcePath: source.path,
        conversationId: 'conv_cap',
        attachmentActionId: 'action_cap',
        fileName: 'cap.bin',
        mediaType: 'application/octet-stream',
        paddingLimit: limit,
      );
      expect(encrypted.manifest['padded_size'], limit);
      // server/internal/config/limits.go MaxAttachmentCiphertext(limit).
      expect(encrypted.ciphertextLength,
          lessThanOrEqualTo(limit + (limit ~/ attachmentChunkSize) * 20));
      expect(
        await service.decryptBytes(
            ciphertextPath: encrypted.ciphertextPath,
            manifest: encrypted.manifest),
        plaintext,
      );
      await encrypted.cleanup();
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);

    test('old version 1 attachments still decrypt', () async {
      // Written the way the version 1 sender did: no padding at all.
      for (final size in <int>[5, attachmentChunkSize + 7]) {
        final plaintext = _patternBytes(size);
        final v1 = await _writeManifestV1(
            service.bindings, tempDir, 'v1_$size', plaintext);
        expect(v1.manifest.containsKey('padded_size'), isFalse);
        final dest = File('${tempDir.path}/v1_dest_$size.bin');
        await service.decryptFile(
          ciphertextPath: v1.path,
          destinationPath: dest.path,
          manifest: v1.manifest,
        );
        expect(await dest.readAsBytes(), plaintext);
        expect(
          await service.decryptBytes(
              ciphertextPath: v1.path, manifest: v1.manifest),
          plaintext,
        );
      }
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);

    test('non-zero padding fails closed', () async {
      // A version 2 file whose padding is not zero, sealed with a valid key.
      final v1 = await _writeManifestV1(
          service.bindings, tempDir, 'dirty', _patternBytes(600));
      final manifest = <String, Object?>{
        ...v1.manifest,
        'version': 2,
        'plaintext_size': 500,
        'padded_size': 600,
      };
      final dest = '${tempDir.path}/dirty_dest.bin';
      await expectLater(
        service.decryptFile(
            ciphertextPath: v1.path, destinationPath: dest, manifest: manifest),
        throwsA(isA<FormatException>()),
      );
      expect(await File(dest).exists(), isFalse);
      expect(await File('$dest.part').exists(), isFalse);
      await expectLater(
        service.decryptBytes(ciphertextPath: v1.path, manifest: manifest),
        throwsA(isA<FormatException>()),
      );
    }, skip: libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false);
  });
}

Map<String, Object?> _manifest({required int plaintextSize}) =>
    <String, Object?>{
      'version': 1,
      'algorithm': 'AES-256-GCM-chunked',
      'key': base64Encode(List<int>.filled(32, 0)),
      'nonce_prefix': base64Encode(List<int>.filled(8, 0)),
      'chunk_size': attachmentChunkSize,
      'chunk_count':
          (plaintextSize + attachmentChunkSize - 1) ~/ attachmentChunkSize,
      'plaintext_size': plaintextSize,
      'conversation_id': 'conv_1',
      'action_id': 'action_1',
    };

/// Every padded size up to the app's cap, in order.
List<int> _buckets() {
  final result = <int>[];
  var size = 1;
  while (true) {
    final bucket = paddedAttachmentSize(size);
    result.add(bucket);
    if (bucket >= maxPlaintextAttachmentBytes) return result;
    size = bucket + 1;
  }
}

/// A version 1 attachment as the pre-padding sender wrote it: the exact
/// bytes in 1 MiB chunks, each `u32 length || AES-GCM(chunk)`.
Future<({String path, Map<String, Object?> manifest})> _writeManifestV1(
  NativeCryptoBindings bindings,
  Directory tempDir,
  String name,
  List<int> plaintext,
) async {
  final key = List<int>.generate(32, (i) => i + 1);
  final nonce = List<int>.generate(8, (i) => 0xa0 + i);
  final conversationId = 'conv_$name';
  final actionId = 'action_$name';
  final context = utf8.encode('$conversationId\u0000$actionId');
  final out = BytesBuilder();
  var chunks = 0;
  for (var offset = 0; offset < plaintext.length;) {
    final end = min(offset + attachmentChunkSize, plaintext.length);
    final sealed = bindings.encryptAttachmentChunk(
      key: key,
      noncePrefix: nonce,
      chunkIndex: chunks,
      context: context,
      plaintext: plaintext.sublist(offset, end),
    );
    out.add((ByteData(4)..setUint32(0, sealed.length, Endian.big))
        .buffer
        .asUint8List());
    out.add(sealed);
    offset = end;
    chunks++;
  }
  final file = File('${tempDir.path}/$name.v1.ciphertext');
  await file.writeAsBytes(out.takeBytes());
  return (
    path: file.path,
    manifest: <String, Object?>{
      'version': 1,
      'algorithm': 'AES-256-GCM-chunked',
      'key': base64Encode(key),
      'nonce_prefix': base64Encode(nonce),
      'chunk_size': attachmentChunkSize,
      'chunk_count': chunks,
      'plaintext_size': plaintext.length,
      'conversation_id': conversationId,
      'action_id': actionId,
      'file_name': '$name.bin',
      'media_type': 'application/octet-stream',
    },
  );
}

Uint8List _patternBytes(int length) => Uint8List.fromList(
      List<int>.generate(length, (index) => index % 251, growable: false),
    );

Future<PreparedEncryptedAttachment> _encryptBytes(
  AttachmentCryptoService service,
  Directory tempDir,
  String name,
  List<int> bytes,
) async {
  final source = File('${tempDir.path}/$name.bin');
  await source.writeAsBytes(bytes);
  return service.encryptFile(
    sourcePath: source.path,
    conversationId: 'conv_$name',
    attachmentActionId: 'action_$name',
    fileName: '$name.bin',
    mediaType: 'application/octet-stream',
  );
}

Future<List<FileSystemEntity>> _attachmentArtifacts(Directory directory) =>
    directory
        .list()
        .where((entity) => entity.path.contains('.attachment-'))
        .toList();

class _CancellingBindings implements NativeCryptoBindings {
  _CancellingBindings({
    required this.delegate,
    required this.token,
    this.cancelOnEncrypt = false,
    this.cancelOnDecrypt = false,
  });

  final NativeCryptoBindings delegate;
  final AttachmentCancellationToken token;
  final bool cancelOnEncrypt;
  final bool cancelOnDecrypt;

  @override
  Uint8List encryptAttachmentChunk({
    required List<int> key,
    required List<int> noncePrefix,
    required int chunkIndex,
    required List<int> context,
    required List<int> plaintext,
  }) {
    final result = delegate.encryptAttachmentChunk(
      key: key,
      noncePrefix: noncePrefix,
      chunkIndex: chunkIndex,
      context: context,
      plaintext: plaintext,
    );
    if (cancelOnEncrypt) token.cancel();
    return Uint8List.fromList(result);
  }

  @override
  Uint8List decryptAttachmentChunk({
    required List<int> key,
    required List<int> noncePrefix,
    required int chunkIndex,
    required List<int> context,
    required List<int> ciphertext,
  }) {
    final result = delegate.decryptAttachmentChunk(
      key: key,
      noncePrefix: noncePrefix,
      chunkIndex: chunkIndex,
      context: context,
      ciphertext: ciphertext,
    );
    if (cancelOnDecrypt) token.cancel();
    return Uint8List.fromList(result);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CancelWhenDestinationExists extends AttachmentCancellationToken {
  _CancelWhenDestinationExists(this.destination);

  final File destination;

  @override
  void throwIfCancelled() {
    if (destination.existsSync()) cancel();
    super.throwIfCancelled();
  }
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
