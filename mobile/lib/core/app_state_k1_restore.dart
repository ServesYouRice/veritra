part of 'app_state.dart';

// K1-4: restoring history from an automatic backup
// (docs/designs/K1-automatic-backups.md, "Restore"). The device is already
// enrolled (linked, or recovered through K0-R); the copy is listed with the
// session, the typed recovery key opens it in Rust, and the K2 history-only
// importer merges it: existing newer messages are kept. Nothing here logs a
// key, a token or history.

extension K1RestoreActions on AppState {
  /// Whether this build can open K1 backups.
  bool get k1RestoreSupported =>
      recoveryAvailable && cryptoService is BackupOpenCryptoService;

  /// The copies a restore offers, or null when the list could not be read.
  Future<List<K1BackupEntry>?> loadK1RestoreList() async {
    final current = session;
    final client = api;
    if (current == null ||
        client == null ||
        current.token.isEmpty ||
        current.deviceId == null ||
        !k1RestoreSupported) {
      return null;
    }
    try {
      final rows = await client.listBackups(current.token);
      if (!identical(session, current)) return null;
      // VBK2 copies (no K1 kind) are retired and never opened (K1-6); the
      // screen only says so.
      k1LegacyBackupsRefused = rows.any((row) => row['kind'] != 1);
      return k1RestoreCandidates(
        rows.map(K1BackupEntry.tryParse).whereType<K1BackupEntry>(),
        current.deviceId!,
      );
    } catch (_) {
      return null;
    }
  }

  /// Opens [entry] with the typed recovery key and merges its history.
  /// Order: the key is checked against the row before any download; the
  /// header is peeked and checked before the body is fetched; the body's
  /// digest is checked before it is opened; Rust opens it pinned to the
  /// row's device; the importer refuses a snapshot that is not the header's.
  Future<K1RestoreResult> restoreFromK1Backup(
      K1BackupEntry entry, String typedKey) async {
    final current = session;
    final client = api;
    final crypto = cryptoService;
    if (current == null ||
        client == null ||
        current.token.isEmpty ||
        current.accountId == null ||
        current.deviceId == null ||
        crypto is! BackupOpenCryptoService ||
        !recoveryAvailable ||
        entry.deviceId == current.deviceId) {
      return K1RestoreResult.unavailable;
    }
    final open = crypto as BackupOpenCryptoService;
    final Uint8List entropy;
    try {
      entropy = await _recoveryCrypto
          .decodeRecoveryKey(normalizeRecoveryKeyInput(typedKey));
    } catch (_) {
      return K1RestoreResult.wrongKey;
    }
    Uint8List? plaintext;
    RecoveryKeyValues? values;
    try {
      values = await _recoveryCrypto.deriveRecoveryKey(entropy);
      if (!_constantTimeBytesEqual(values.rkId, entry.rkId)) {
        return K1RestoreResult.otherKey;
      }
      // The account's current key may differ (a copy older than a swap):
      // the restore works with the key that sealed the copy.
      final prefix = await _k1ReadBytes(
          await client.downloadBackup(current.token, entry.id,
              start: 0, end: k1BackupPeekBytes - 1),
          k1BackupPeekBytes);
      final peek = open.peekK1Backup(prefix);
      if (peek.accountId != current.accountId ||
          peek.sourceDeviceId != entry.deviceId ||
          peek.counter != entry.counter ||
          !_constantTimeBytesEqual(peek.rkId, entry.rkId)) {
        return K1RestoreResult.corrupt;
      }
      final body = await _k1ReadBytes(
          await client.downloadBackup(current.token, entry.id),
          k1MaxBackupCiphertextBytes);
      if (body.length != entry.sizeBytes ||
          _hexOf(sha256(body)) != entry.sha256Hex) {
        return K1RestoreResult.corrupt;
      }
      final opened = await open.openK1Backup(
          ciphertext: body,
          entropy: entropy,
          accountId: current.accountId!,
          sourceDeviceId: entry.deviceId);
      plaintext = opened.plaintext;
      if (opened.header.accountId != current.accountId ||
          opened.header.sourceDeviceId != entry.deviceId ||
          opened.header.counter != entry.counter ||
          opened.header.plaintextVersion != k1BackupPlaintextVersion) {
        return K1RestoreResult.corrupt;
      }
      // The snapshot is inside the authenticated container; the importer
      // also requires its own account, device, counter and time to be the
      // ones it is told, so the context comes from what was just opened.
      final snapshot = HistorySnapshot.decode(plaintext);
      if (snapshot.accountId != current.accountId ||
          snapshot.sourceDeviceId != entry.deviceId ||
          snapshot.counter <= 0) {
        return K1RestoreResult.corrupt;
      }
      await localStore.importHistorySnapshot(
          plaintext,
          HistoryImportContext(
              origin: current.baseUrl,
              accountId: current.accountId!,
              sourceDeviceId: entry.deviceId,
              recipientDeviceId: current.deviceId!,
              transferId: entry.id,
              digest: entry.sha256Hex,
              snapshotCounter: snapshot.counter,
              snapshotCreatedAt: snapshot.createdAt));
      // The typed key turns backups on here (design, Restore step 4), when it
      // is also the account's current key.
      final status = recoveryKeyStatus;
      if (status?.rkId != null &&
          _constantTimeBytesEqual(status!.rkId!, values.rkId) &&
          identical(session, current)) {
        await _storeK1Key(values.rkPub, values.rkId);
      }
      try {
        await refreshCopiedHistory();
      } catch (_) {}
      return K1RestoreResult.done;
    } on SocketException {
      return K1RestoreResult.network;
    } on TimeoutException {
      return K1RestoreResult.network;
    } on ApiException catch (err) {
      return err.statusCode >= 500 || err.statusCode == 429
          ? K1RestoreResult.network
          : K1RestoreResult.corrupt;
    } catch (_) {
      return K1RestoreResult.corrupt;
    } finally {
      entropy.fillRange(0, entropy.length, 0);
      values?.rkPub.fillRange(0, values.rkPub.length, 0);
      plaintext?.fillRange(0, plaintext.length, 0);
    }
  }
}

/// Reads [stream] into one buffer, failing above [max] bytes.
Future<Uint8List> _k1ReadBytes(Stream<List<int>> stream, int max) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (out.length + chunk.length > max) {
      throw const ApiResponseTooLargeException();
    }
    out.add(chunk);
  }
  return out.takeBytes();
}

String _hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
