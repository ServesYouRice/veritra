import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../core/api_client.dart';
import '../storage/local_store.dart';
import 'native_crypto_bindings.dart';

const int _backupChunkSize = 1024 * 1024;
const int _maxBackupPlaintext = 64 * 1024 * 1024;
const List<int> _backupMagic = <int>[0x56, 0x42, 0x4b, 0x31];

class BackupService {
  BackupService({required this.bindings, required this.localStore});

  final NativeCryptoBindings bindings;
  final LocalStore localStore;

  Future<String> createAndUpload(ApiClient client, String authToken) async {
    final state = await localStore.loadCryptoState();
    if (state == null) throw StateError('MLS state is unavailable');
    final plaintext = await localStore.exportBackup();
    if (plaintext.isEmpty || plaintext.length > _maxBackupPlaintext) {
      throw StateError('local backup exceeds the supported size');
    }
    final key = _randomBytes(32);
    final recoveryToken = _randomBytes(32);
    final nonce = _randomBytes(8);
    final context = <int>[
      ...utf8.encode('veritra-backup-v1'),
      ...recoveryToken
    ];
    final directory = await getApplicationSupportDirectory();
    await _cleanupOrphans(directory);
    final file = File('${directory.path}${Platform.pathSeparator}'
        '.${_randomHex(12)}.backup-ciphertext');
    RandomAccessFile? output;
    try {
      output = await file.open(mode: FileMode.writeOnly);
      await output.writeFrom(_backupMagic);
      await output.writeFrom(nonce);
      final chunkCount =
          (plaintext.length + _backupChunkSize - 1) ~/ _backupChunkSize;
      final metadata = ByteData(12)
        ..setUint32(0, chunkCount, Endian.big)
        ..setUint64(4, plaintext.length, Endian.big);
      await output.writeFrom(metadata.buffer.asUint8List());
      for (var index = 0; index < chunkCount; index++) {
        final start = index * _backupChunkSize;
        final end = min(start + _backupChunkSize, plaintext.length);
        final encrypted = bindings.encryptAttachmentChunk(
          key: key,
          noncePrefix: nonce,
          chunkIndex: index,
          context: context,
          plaintext: plaintext.sublist(start, end),
        );
        final length = ByteData(4)..setUint32(0, encrypted.length, Endian.big);
        await output.writeFrom(length.buffer.asUint8List());
        await output.writeFrom(encrypted);
      }
      await output.flush();
      await output.close();
      output = null;
      await client.uploadEncryptedBackup(
        authToken,
        file.openRead(),
        ciphertextLength: await file.length(),
        recoveryToken: recoveryToken,
        cryptoMetadata: <String, Object?>{
          'version': 1,
          'algorithm': 'AES-256-GCM-chunked',
          'chunk_size': _backupChunkSize,
          'state_counter': state.counter,
        },
      );
      final origin =
          base64Url.encode(utf8.encode(client.baseUrl)).replaceAll('=', '');
      final token = base64Url.encode(recoveryToken).replaceAll('=', '');
      final secret = base64Url.encode(key).replaceAll('=', '');
      return 'v1.$origin.$token.$secret';
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
      key.fillRange(0, key.length, 0);
      await output?.close();
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> recover(String recoveryCode) async {
    final parts = recoveryCode.trim().split('.');
    if (parts.length != 4 || parts[0] != 'v1') {
      throw const FormatException('invalid recovery code');
    }
    final baseUrl =
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final recoveryToken = base64Url.decode(base64Url.normalize(parts[2]));
    final key = base64Url.decode(base64Url.normalize(parts[3]));
    if (recoveryToken.length != 32 || key.length != 32) {
      throw const FormatException('invalid recovery code');
    }
    final client = ApiClient(baseUrl: baseUrl);
    final directory = await getApplicationSupportDirectory();
    await _cleanupOrphans(directory);
    final file = File('${directory.path}${Platform.pathSeparator}'
        '.${_randomHex(12)}.backup-ciphertext');
    try {
      final sink = file.openWrite(mode: FileMode.writeOnly);
      await sink.addStream(await client.recoverEncryptedBackup(recoveryToken));
      await sink.flush();
      await sink.close();
      final input = await file.open();
      try {
        final magic = await _readExactly(input, 4);
        final nonce = await _readExactly(input, 8);
        final metadata = ByteData.sublistView(
            Uint8List.fromList(await _readExactly(input, 12)));
        if (!_constantTimeEqual(magic, _backupMagic)) {
          throw const FormatException('invalid backup framing');
        }
        final chunkCount = metadata.getUint32(0, Endian.big);
        final plaintextSize = metadata.getUint64(4, Endian.big);
        if (chunkCount <= 0 ||
            plaintextSize <= 0 ||
            plaintextSize > _maxBackupPlaintext ||
            chunkCount !=
                (plaintextSize + _backupChunkSize - 1) ~/ _backupChunkSize) {
          throw const FormatException('invalid backup bounds');
        }
        final context = <int>[
          ...utf8.encode('veritra-backup-v1'),
          ...recoveryToken
        ];
        final plaintext = BytesBuilder(copy: false);
        for (var index = 0; index < chunkCount; index++) {
          final lengthBytes = await _readExactly(input, 4);
          final length = ByteData.sublistView(Uint8List.fromList(lengthBytes))
              .getUint32(0, Endian.big);
          if (length <= 16 || length > _backupChunkSize + 16) {
            throw const FormatException('invalid backup chunk');
          }
          plaintext.add(bindings.decryptAttachmentChunk(
            key: key,
            noncePrefix: nonce,
            chunkIndex: index,
            context: context,
            ciphertext: await _readExactly(input, length),
          ));
        }
        if ((await input.readByte()) != -1 ||
            plaintext.length != plaintextSize) {
          throw const FormatException('backup is truncated or extended');
        }
        final decoded = plaintext.takeBytes();
        try {
          await localStore.restoreBackup(decoded);
        } finally {
          decoded.fillRange(0, decoded.length, 0);
        }
      } finally {
        await input.close();
      }
    } finally {
      key.fillRange(0, key.length, 0);
      recoveryToken.fillRange(0, recoveryToken.length, 0);
      client.close();
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _cleanupOrphans(Directory directory) async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.backup-ciphertext')) {
        final modified = await entity.lastModified();
        if (DateTime.now().difference(modified) > const Duration(hours: 24)) {
          await entity.delete();
        }
      }
    }
  }
}

Future<List<int>> _readExactly(RandomAccessFile file, int length) async {
  final result = BytesBuilder(copy: false);
  while (result.length < length) {
    final chunk = await file.read(length - result.length);
    if (chunk.isEmpty) throw const FormatException('truncated backup');
    result.add(chunk);
  }
  return result.takeBytes();
}

bool _constantTimeEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

String _randomHex(int bytes) => _randomBytes(bytes)
    .map((value) => value.toRadixString(16).padLeft(2, '0'))
    .join();
