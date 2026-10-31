import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../core/api_client.dart';
import '../storage/local_store.dart';
import 'native_crypto_bindings.dart';
import '../l10n/l10n.dart';

const int _backupChunkSize = 1024 * 1024;
const int _maxBackupPlaintext = 64 * 1024 * 1024;

/// The encrypted backup file, format VBK2 (TASK-044). All integers are
/// big-endian. With a random 32-byte key K, a random 8-byte nonce prefix N
/// and the 32-byte recovery token T:
///
///     header   = "VBK2" || N || u32 chunkCount || u64 plaintextSize  (24 B)
///     frame 0  = u32 length || seal(K, N, 0, "veritra-backup-v2-header"
///                    || T || header[0..12], header[12..24])
///     frame i  = u32 length || seal(K, N, i, "veritra-backup-v2" || T
///                    || header || last, chunk i-1)       for i = 1..count
///
/// `seal` is the native chunk AEAD (AES-256-GCM, nonce N || u32 index, the
/// index also in the associated data); `last` is one byte, 1 for frame
/// `count` and 0 before it; chunks are 1 MiB except the last. Frame 0
/// checks the key before the cleartext count and size are trusted, so a
/// wrong recovery code is told apart from a damaged file. Every data frame
/// binds the whole header and whether it is the last, so a rewritten header
/// or a file cut at a chunk boundary fails to authenticate, and nothing is
/// restored until every frame has. Restore refuses the legacy VBK1 format
/// (D55), whose header was not authenticated. Described in docs/crypto.md,
/// "Encrypted backup file (VBK2)".
const List<int> _backupMagic = <int>[0x56, 0x42, 0x4b, 0x32];
const int _backupHeaderLength = 24;
const String _backupHeaderDomain = 'veritra-backup-v2-header';
const String _backupChunkDomain = 'veritra-backup-v2';

/// Associated data of frame 0, which seals the count and size.
List<int> _headerFrameContext(List<int> recoveryToken, List<int> header) =>
    <int>[
      ...utf8.encode(_backupHeaderDomain),
      ...recoveryToken,
      ...header.sublist(0, 12),
    ];

/// Associated data of a data frame: the whole header, and whether this is
/// the last chunk.
List<int> _chunkContext(List<int> recoveryToken, List<int> header,
        {required bool last}) =>
    <int>[
      ...utf8.encode(_backupChunkDomain),
      ...recoveryToken,
      ...header,
      last ? 1 : 0,
    ];

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

/// What [BackupService._download] left in the recovery file.
enum _Download {
  /// A whole download from byte 0.
  fresh,

  /// A saved prefix continued.
  resumed,

  /// The saved file was already the whole backup, and is restored.
  restoredSaved,
}

/// The server will not continue a saved prefix (416, or a 200 to a range
/// request). Never leaves [BackupService]: the download restarts from 0.
class _RangeRefused implements Exception {
  const _RangeRefused();
}

class BackupException implements Exception {
  const BackupException(this.kind);

  final BackupFailureKind kind;

  /// The English explanation; see [localizedMessage].
  String get message => localizedMessage(englishL10n);

  /// A sentence safe to show to end users, in [l10n]'s language.
  String localizedMessage(AppLocalizations l10n) {
    switch (kind) {
      case BackupFailureKind.network:
        return l10n.backupErrorNetwork;
      case BackupFailureKind.notFound:
        return l10n.backupErrorNotFound;
      case BackupFailureKind.busy:
        return l10n.backupErrorBusy;
      case BackupFailureKind.wrongKey:
        return l10n.backupErrorWrongKey;
      case BackupFailureKind.corrupt:
        return l10n.backupErrorCorrupt;
      case BackupFailureKind.deviceNotEmpty:
        return l10n.backupErrorDeviceNotEmpty;
      case BackupFailureKind.tooLarge:
        return l10n.backupErrorTooLarge;
      case BackupFailureKind.storage:
        return l10n.backupErrorStorage;
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
    final directory = await _directoryProvider();
    await _cleanupOrphans(directory);
    final file = File('${directory.path}${Platform.pathSeparator}'
        '.${_randomHex(12)}.backup-ciphertext');
    RandomAccessFile? output;
    try {
      output = await file.open(mode: FileMode.writeOnly);
      final chunkCount =
          (plaintext.length + _backupChunkSize - 1) ~/ _backupChunkSize;
      final metadata = ByteData(12)
        ..setUint32(0, chunkCount, Endian.big)
        ..setUint64(4, plaintext.length, Endian.big);
      final header = <int>[
        ..._backupMagic,
        ...nonce,
        ...metadata.buffer.asUint8List(),
      ];
      await output.writeFrom(header);
      Future<void> writeFrame(List<int> encrypted) async {
        final length = ByteData(4)..setUint32(0, encrypted.length, Endian.big);
        await output!.writeFrom(length.buffer.asUint8List());
        await output.writeFrom(encrypted);
      }

      await writeFrame(bindings.encryptAttachmentChunk(
        key: key,
        noncePrefix: nonce,
        chunkIndex: 0,
        context: _headerFrameContext(recoveryToken, header),
        plaintext: header.sublist(12),
      ));
      for (var index = 0; index < chunkCount; index++) {
        final start = index * _backupChunkSize;
        final end = min(start + _backupChunkSize, plaintext.length);
        await writeFrame(bindings.encryptAttachmentChunk(
          key: key,
          noncePrefix: nonce,
          chunkIndex: index + 1,
          context: _chunkContext(recoveryToken, header,
              last: index == chunkCount - 1),
          plaintext: plaintext.sublist(start, end),
        ));
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
      final download = await _download(client, recoveryToken, key, file,
          restoreSaved: () => _restoreSaved(file, recoveryToken, key));
      if (download != _Download.restoredSaved) {
        try {
          await _decryptAndRestore(file, recoveryToken, key);
        } on BackupException catch (error) {
          // Only a prefix whose frame 0 opened with this code is continued,
          // but its later frames may still be damaged: only a fresh download
          // can tell a damaged backup from a damaged prefix.
          if (download != _Download.resumed ||
              error.kind == BackupFailureKind.deviceNotEmpty) {
            rethrow;
          }
          await file.delete();
          await _download(client, recoveryToken, key, file);
          await _decryptAndRestore(file, recoveryToken, key);
        }
      }
      if (await file.exists()) await file.delete();
    } on BackupException catch (error) {
      // A wrong key is kept too: the server accepted the token, so the file
      // is this backup, and the transfer that fetched it may have used up
      // the code. Only the corrected key part can restore it now. A local
      // storage failure says nothing about the file either.
      if (error.kind != BackupFailureKind.network &&
          error.kind != BackupFailureKind.busy &&
          error.kind != BackupFailureKind.wrongKey &&
          error.kind != BackupFailureKind.storage &&
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
  /// already holds, and says whether the file now continues a prefix saved
  /// by an earlier attempt.
  ///
  /// A saved prefix is continued only if its frame 0 opens with this code.
  /// Otherwise it belongs to another code (or this code's key is mistyped,
  /// or it is too short to tell), and appending this code's tail to it would
  /// use up this code for a file that never restores. The download then
  /// starts from byte 0 and replaces the file only once the server answers;
  /// a 404 then reports a file that failed on the key as a wrong code,
  /// which [recover] keeps.
  ///
  /// The server may not continue a saved file: a 416 (or a 200 to the range
  /// request, as from a proxy that drops `Range`), or a 404 once a transfer
  /// that reached the end used up the code. The saved file may then already
  /// be the whole backup, as when the app stopped after the download but
  /// before the restore, so [restoreSaved] tries it first; VBK2
  /// authenticates every frame and the last, so a cut or stale file never
  /// passes. If it does not restore, a refused range drops the file and
  /// downloads again from byte 0, once, in this call; a 404 stays not found,
  /// unless the saved file failed on the key: it is then kept
  /// for the corrected code, as a wrong code.
  Future<_Download> _download(
      ApiClient client, List<int> recoveryToken, List<int> key, File file,
      {Future<BackupFailureKind?> Function()? restoreSaved}) async {
    final start = await file.exists() ? await file.length() : 0;
    if (start == 0) {
      await _downloadFrom(client, recoveryToken, file, 0);
      return _Download.fresh;
    }
    final savedFailure = await _savedHeaderFailure(file, recoveryToken, key);
    if (savedFailure != null) {
      try {
        await _downloadFrom(client, recoveryToken, file, 0);
      } on BackupException catch (error) {
        if (error.kind == BackupFailureKind.notFound &&
            savedFailure == BackupFailureKind.wrongKey) {
          throw const BackupException(BackupFailureKind.wrongKey);
        }
        rethrow;
      }
      return _Download.fresh;
    }
    try {
      await _downloadFrom(client, recoveryToken, file, start);
      return _Download.resumed;
    } on _RangeRefused {
      if (restoreSaved != null && await restoreSaved() == null) {
        return _Download.restoredSaved;
      }
      await _deletePartial(file);
      await _downloadFrom(client, recoveryToken, file, 0);
      return _Download.fresh;
    } on BackupException catch (error) {
      if (error.kind == BackupFailureKind.notFound && restoreSaved != null) {
        final failed = await restoreSaved();
        if (failed == null) return _Download.restoredSaved;
        if (failed == BackupFailureKind.wrongKey)
          throw const BackupException(BackupFailureKind.wrongKey);
      }
      rethrow;
    }
  }

  /// Restores [file] if it is a whole, authentic backup for this code, and
  /// returns null. Otherwise returns why not: [BackupFailureKind.wrongKey]
  /// when its frame 0 does not open with this code, another kind when it is
  /// partial or damaged. A device that already has an account still fails
  /// as such.
  Future<BackupFailureKind?> _restoreSaved(
      File file, List<int> recoveryToken, List<int> key) async {
    try {
      await _decryptAndRestore(file, recoveryToken, key);
      return null;
    } on BackupException catch (error) {
      if (error.kind == BackupFailureKind.deviceNotEmpty) rethrow;
      return error.kind;
    }
  }

  /// Null if [file]'s header and frame 0 open with this code; otherwise
  /// why not: [BackupFailureKind.wrongKey] if frame 0 does not open,
  /// [BackupFailureKind.corrupt] if the file is too short or not VBK2.
  Future<BackupFailureKind?> _savedHeaderFailure(
      File file, List<int> recoveryToken, List<int> key) async {
    final RandomAccessFile input;
    try {
      input = await file.open();
    } on FileSystemException {
      throw const BackupException(BackupFailureKind.storage);
    }
    try {
      await _readHeader(input, recoveryToken, key);
      return null;
    } on BackupException catch (error) {
      return error.kind;
    } on FormatException {
      return BackupFailureKind.corrupt;
    } finally {
      await input.close();
    }
  }

  static Future<void> _deletePartial(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      throw const BackupException(BackupFailureKind.storage);
    }
  }

  Future<void> _downloadFrom(
      ApiClient client, List<int> recoveryToken, File file, int start) async {
    IOSink? sink;
    try {
      final stream = await client.recoverEncryptedBackup(recoveryToken,
          startOffset: start == 0 ? null : start);
      // From byte 0 the file is replaced, but only now that the server has
      // answered: a refused request leaves a saved file as it was.
      sink = file.openWrite(
          mode: start == 0 ? FileMode.writeOnly : FileMode.writeOnlyAppend);
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
        // The saved prefix cannot be continued: the caller restarts from
        // byte 0. A 416 to a request without a range is not expected.
        if (start > 0) throw const _RangeRefused();
        throw const BackupException(BackupFailureKind.corrupt);
      }
      // Anything else (5xx, 429, or a status the recovery route never
      // sends, as from a proxy or captive portal) says nothing about the
      // backup: keep the download and let the user try again.
      throw const BackupException(BackupFailureKind.network);
    } on FormatException {
      // A malformed answer (ApiResponseException), as from a proxy: a range
      // the server did not prove is refused like a 416, so the saved file is
      // tried and the download restarts from 0; from byte 0 it says nothing
      // about the backup, so the file is kept for a retry.
      if (start > 0) throw const _RangeRefused();
      throw const BackupException(BackupFailureKind.network);
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
      final header = await _readHeader(input, recoveryToken, key);
      final nonce = header.sublist(4, 12);
      final metadata =
          ByteData.sublistView(Uint8List.fromList(header.sublist(12)));
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
      final plaintext = BytesBuilder(copy: false);
      for (var index = 0; index < chunkCount; index++) {
        final length = await _readFrameLength(input);
        final ciphertext = await _readExactly(input, length);
        try {
          plaintext.add(bindings.decryptAttachmentChunk(
            key: key,
            noncePrefix: nonce,
            chunkIndex: index + 1,
            context: _chunkContext(recoveryToken, header,
                last: index == chunkCount - 1),
            ciphertext: ciphertext,
          ));
        } on NativeCryptoException {
          // The key already checked out on frame 0: the file was changed.
          throw const BackupException(BackupFailureKind.corrupt);
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

  /// Reads the header and frame 0 from [input] and returns the header once
  /// frame 0 has authenticated it with this code. Throws
  /// [BackupFailureKind.wrongKey] if frame 0 does not open,
  /// [BackupFailureKind.corrupt] if the file is not VBK2, and
  /// [FormatException] if it is too short.
  Future<List<int>> _readHeader(
      RandomAccessFile input, List<int> recoveryToken, List<int> key) async {
    final header = await _readExactly(input, _backupHeaderLength);
    // Anything else, the legacy VBK1 format included (D55), is refused.
    if (!_constantTimeEqual(header.sublist(0, 4), _backupMagic)) {
      throw const BackupException(BackupFailureKind.corrupt);
    }
    final nonce = header.sublist(4, 12);
    // Frame 0 first: it checks the key and seals the count and size, so
    // nothing below trusts the cleartext header unchecked.
    final headerFrameLength = await _readFrameLength(input);
    if (headerFrameLength != 12 + 16) {
      throw const BackupException(BackupFailureKind.corrupt);
    }
    final headerFrame = await _readExactly(input, headerFrameLength);
    final List<int> sealedMetadata;
    try {
      sealedMetadata = bindings.decryptAttachmentChunk(
        key: key,
        noncePrefix: nonce,
        chunkIndex: 0,
        context: _headerFrameContext(recoveryToken, header),
        ciphertext: headerFrame,
      );
    } on NativeCryptoException {
      // The code does not open this backup (or its nonce was changed).
      throw const BackupException(BackupFailureKind.wrongKey);
    }
    if (!_constantTimeEqual(sealedMetadata, header.sublist(12))) {
      throw const BackupException(BackupFailureKind.corrupt);
    }
    return header;
  }

  /// A frame's length: at least one byte of ciphertext and its 16-byte tag,
  /// at most a full chunk and its tag.
  static Future<int> _readFrameLength(RandomAccessFile input) async {
    final length =
        ByteData.sublistView(Uint8List.fromList(await _readExactly(input, 4)))
            .getUint32(0, Endian.big);
    if (length <= 16 || length > _backupChunkSize + 16) {
      throw const BackupException(BackupFailureKind.corrupt);
    }
    return length;
  }

  /// Deletes upload files left by a create that stopped. The recovery
  /// download is not aged out: it may be the only copy of a backup whose
  /// code its finished transfer used up, and [recover] deletes it itself
  /// once it is restored or definitively fails.
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
