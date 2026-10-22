import 'dart:async';
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

/// Why creating or restoring an encrypted backup failed (card I45).
enum BackupFailureKind {
  /// No connection or the server was busy. A restore can continue later
  /// from where it stopped.
  network,

  /// The recovery code is unknown, expired or already used, or the backup
  /// was replaced by a newer one.
  notFound,

  /// Another device is downloading this backup right now.
  busy,

  /// The recovery code does not open this backup.
  wrongKey,

  /// The backup is damaged or not a Veritra backup.
  corrupt,

  /// This device already holds an account; restoring would replace it.
  deviceNotEmpty,

  /// The backup does not fit the supported size.
  tooLarge,

  /// Local storage failed.
  storage,
}

class BackupException implements Exception {
  const BackupException(this.kind);

  final BackupFailureKind kind;

  String get message {
    switch (kind) {
      case BackupFailureKind.network:
        return 'The server could not be reached. Try again; the restore '
            'continues where it stopped.';
      case BackupFailureKind.notFound:
        return 'This recovery code is unknown, expired or already used.';
      case BackupFailureKind.busy:
        return 'This backup is being downloaded elsewhere. Try again in a '
            'few minutes.';
      case BackupFailureKind.wrongKey:
        return 'This recovery code does not open the backup.';
      case BackupFailureKind.corrupt:
        return 'The backup is damaged and cannot be restored.';
      case BackupFailureKind.deviceNotEmpty:
        return 'This device already has an account. Sign out and reset it '
            'before restoring a backup.';
      case BackupFailureKind.tooLarge:
        return 'The backup is larger than this app supports.';
      case BackupFailureKind.storage:
        return 'This device could not store the backup.';
    }
  }

  @override
  String toString() => 'BackupException(${kind.name})';
}

class BackupService {
  BackupService({
    required this.bindings,
    required this.localStore,
    Future<Directory> Function()? directoryProvider,
    ApiClient Function(String baseUrl)? clientFactory,
  })  : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory,
        _clientFactory =
            clientFactory ?? ((baseUrl) => ApiClient(baseUrl: baseUrl));

  final NativeCryptoBindings bindings;
  final LocalStore localStore;
  final Future<Directory> Function() _directoryProvider;
  final ApiClient Function(String baseUrl) _clientFactory;

  static const _partialName = '.veritra-recovery.partial';

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
    final directory = await _directoryProvider();
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

  /// Downloads, decrypts and restores the backup named by [recoveryCode]
  /// into an empty local store. An interrupted download is kept and
  /// continued by the next call; nothing is written to the store until the
  /// whole backup has decrypted and parsed. Throws [BackupException].
  Future<void> recover(String recoveryCode) async {
    final parts = recoveryCode.trim().split('.');
    if (parts.length != 4 || parts[0] != 'v1') {
      throw const BackupException(BackupFailureKind.wrongKey);
    }
    final String baseUrl;
    final List<int> recoveryToken;
    final List<int> key;
    try {
      baseUrl = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      recoveryToken = base64Url.decode(base64Url.normalize(parts[2]));
      key = base64Url.decode(base64Url.normalize(parts[3]));
    } on FormatException {
      throw const BackupException(BackupFailureKind.wrongKey);
    }
    if (recoveryToken.length != 32 || key.length != 32) {
      throw const BackupException(BackupFailureKind.wrongKey);
    }
    try {
      final existing = await localStore.loadSession();
      if (existing != null && (existing.deviceId?.isNotEmpty ?? false)) {
        throw const BackupException(BackupFailureKind.deviceNotEmpty);
      }
    } on BackupException {
      rethrow;
    } catch (_) {
      throw const BackupException(BackupFailureKind.storage);
    }
    final ApiClient client;
    try {
      client = _clientFactory(baseUrl);
    } catch (_) {
      throw const BackupException(BackupFailureKind.wrongKey);
    }
    final directory = await _directoryProvider();
    await _cleanupOrphans(directory);
    final file =
        File('${directory.path}${Platform.pathSeparator}$_partialName');
    try {
      var resumed = await file.exists() && await file.length() > 0;
      await _download(client, recoveryToken, file);
      try {
        await _decryptAndRestore(file, recoveryToken, key);
      } on BackupException catch (error) {
        // A partial file left by another recovery code decrypts as garbage:
        // only a fresh download can tell a wrong code from a stale prefix.
        if (!resumed || error.kind == BackupFailureKind.deviceNotEmpty) {
          rethrow;
        }
        resumed = false;
        await file.delete();
        await _download(client, recoveryToken, file);
        await _decryptAndRestore(file, recoveryToken, key);
      }
      if (await file.exists()) await file.delete();
    } on BackupException catch (error) {
      if (error.kind != BackupFailureKind.network &&
          error.kind != BackupFailureKind.busy &&
          await file.exists()) {
        await file.delete();
      }
      rethrow;
    } finally {
      key.fillRange(0, key.length, 0);
      recoveryToken.fillRange(0, recoveryToken.length, 0);
      client.close();
    }
  }

  /// Appends the rest of the backup to [file], starting after what it
  /// already holds.
  Future<void> _download(
      ApiClient client, List<int> recoveryToken, File file) async {
    final start = await file.exists() ? await file.length() : 0;
    IOSink? sink;
    try {
      final stream = await client.recoverEncryptedBackup(recoveryToken,
          startOffset: start == 0 ? null : start);
      sink = file.openWrite(mode: FileMode.writeOnlyAppend);
      await sink.addStream(stream);
      await sink.flush();
    } on ApiException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 410) {
        throw const BackupException(BackupFailureKind.notFound);
      }
      if (error.statusCode == 409) {
        throw const BackupException(BackupFailureKind.busy);
      }
      if (error.statusCode == 416) {
        // The saved prefix is not from this backup any more.
        await sink?.close();
        sink = null;
        await file.delete();
        throw const BackupException(BackupFailureKind.corrupt);
      }
      if (error.statusCode >= 500 || error.statusCode == 429) {
        throw const BackupException(BackupFailureKind.network);
      }
      throw const BackupException(BackupFailureKind.notFound);
    } on SocketException {
      throw const BackupException(BackupFailureKind.network);
    } on HttpException {
      throw const BackupException(BackupFailureKind.network);
    } on TimeoutException {
      throw const BackupException(BackupFailureKind.network);
    } on FileSystemException {
      throw const BackupException(BackupFailureKind.storage);
    } finally {
      try {
        await sink?.close();
      } on FileSystemException {
        // The stream failure is the error to report; what reached the file
        // is kept, and the next attempt continues from its length.
      }
    }
  }

  Future<void> _decryptAndRestore(
      File file, List<int> recoveryToken, List<int> key) async {
    final input = await file.open();
    Uint8List? decoded;
    try {
      final magic = await _readExactly(input, 4);
      final nonce = await _readExactly(input, 8);
      final metadata = ByteData.sublistView(
          Uint8List.fromList(await _readExactly(input, 12)));
      if (!_constantTimeEqual(magic, _backupMagic)) {
        throw const BackupException(BackupFailureKind.corrupt);
      }
      final chunkCount = metadata.getUint32(0, Endian.big);
      final plaintextSize = metadata.getUint64(4, Endian.big);
      if (plaintextSize > _maxBackupPlaintext) {
        throw const BackupException(BackupFailureKind.tooLarge);
      }
      if (chunkCount <= 0 ||
          plaintextSize <= 0 ||
          chunkCount !=
              (plaintextSize + _backupChunkSize - 1) ~/ _backupChunkSize) {
        throw const BackupException(BackupFailureKind.corrupt);
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
          throw const BackupException(BackupFailureKind.corrupt);
        }
        final ciphertext = await _readExactly(input, length);
        try {
          plaintext.add(bindings.decryptAttachmentChunk(
            key: key,
            noncePrefix: nonce,
            chunkIndex: index,
            context: context,
            ciphertext: ciphertext,
          ));
        } on NativeCryptoException {
          // The first chunk failing means the code does not match; a later
          // one means the file was damaged.
          throw BackupException(index == 0
              ? BackupFailureKind.wrongKey
              : BackupFailureKind.corrupt);
        }
      }
      if ((await input.readByte()) != -1 || plaintext.length != plaintextSize) {
        throw const BackupException(BackupFailureKind.corrupt);
      }
      decoded = plaintext.takeBytes();
      try {
        await localStore.restoreBackup(decoded);
      } on FormatException {
        throw const BackupException(BackupFailureKind.corrupt);
      } on StateError {
        throw const BackupException(BackupFailureKind.deviceNotEmpty);
      }
    } on FormatException {
      throw const BackupException(BackupFailureKind.corrupt);
    } finally {
      decoded?.fillRange(0, decoded.length, 0);
      await input.close();
    }
  }

  Future<void> _cleanupOrphans(Directory directory) async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File &&
          (entity.path.endsWith('.backup-ciphertext') ||
              entity.path.endsWith(_partialName))) {
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
