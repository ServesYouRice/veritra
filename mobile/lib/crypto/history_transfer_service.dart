import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import '../core/history_transfer_client.dart';
import '../storage/encrypted_database.dart'
    show
        HistoryTransferProgress,
        HistoryTransferStage,
        historyTransferIncoming,
        historyTransferOutgoing;
import '../storage/local_store.dart';
import 'k2_transfer_crypto.dart';
import 'native_crypto_bindings.dart' show K2Stage, K2TransferId;

/// K2 history transfer sequencing (`docs/designs/K2-new-device-history.md`):
/// each side resumes from its stored progress row, one stage at a time, and
/// every stage that changes native state is committed by
/// [K2TransferCryptoService] before the next HTTP call.
///
/// Rows are created by the link flow, not here: the source's `approving` row
/// by [K2TransferCryptoService.k2SourceConfirm], the recipient's
/// `awaiting_handoff` row by the promotion
/// (`EnrollmentPromotion.transfer`). The recipient's row `payloadJson` is the
/// contract with that flow:
/// `{"approval_tag": base64 (32 bytes), "approved_at": epoch ms,
///   "claim_request_hash": hex (optional, checked against the receipt)}`
/// plus whatever else the flow keeps there (the claim token).
///
/// A method returns the last row it reached. A failure leaves the row at the
/// last committed stage, so calling again resumes. Nothing here logs.
class HistoryTransferService {
  HistoryTransferService({
    required this.crypto,
    required this.localStore,
    required this.transport,
  });

  final K2TransferCryptoService crypto;
  final LocalStore localStore;
  final HistoryTransferTransport transport;

  /// Source: prepare the encrypted copy, upload it, and settle when the
  /// recipient acknowledged. The source's approval POST and the native
  /// approval ([K2TransferCryptoService.k2ApplyApproval]) come before this.
  ///
  /// The cached copy is never regenerated: when it is missing or short after
  /// the handoff was committed, this refuses ([K2TransferException]) and the
  /// caller abandons it ([abandon]); a new link makes a new copy.
  Future<HistoryTransferProgress> send(
    K2TransferId id, {
    required String sessionToken,
    required String cacheDirectory,
  }) async {
    var row = await _row(id, historyTransferOutgoing);
    if (row.stage == HistoryTransferStage.approving) {
      row = await crypto.k2SourcePrepare(id, cacheDirectory: cacheDirectory);
    }
    if (row.stage == HistoryTransferStage.snapshotReady) {
      row = await _upload(id, row, sessionToken);
    }
    if (row.stage == HistoryTransferStage.uploaded) {
      final receipt =
          await transport.status(id.linkId, HistorySessionAuth(sessionToken));
      if (receipt.state == 'acknowledged') {
        row = row.copyWith(stage: HistoryTransferStage.acknowledged);
        await localStore.saveHistoryTransfer(row);
      }
    }
    if (row.stage == HistoryTransferStage.acknowledged) {
      await crypto.k2Finish(id);
    }
    return row;
  }

  Future<HistoryTransferProgress> _upload(
      K2TransferId id, HistoryTransferProgress row, String token) async {
    final file = File(row.filePath!);
    if (!file.existsSync() || file.lengthSync() != row.ciphertextSize) {
      throw const K2TransferException('the cached copy is gone');
    }
    final status = await crypto.k2Inspect(id);
    final claimHash = _payload(row)['claim_request_hash'];
    if (claimHash is! String) {
      throw const K2TransferException('the claim digest is missing');
    }
    await transport.upload(
      token: token,
      linkId: id.linkId,
      metadata: HistoryTransferMetadata(
        transferId: row.transferId!,
        claimRequestHash: claimHash,
        transcriptHash: status.verification.transcriptHash,
        ciphertextSha256: _hex(row.ciphertextSha256!),
        sizeBytes: row.ciphertextSize!,
        handoff: row.handoff!,
      ),
      ciphertext: () => file.openRead(),
    );
    return crypto.k2SourcePosted(id);
  }

  /// Recipient: apply the approval, fetch and verify the handoff, download,
  /// verify, import, acknowledge and clean up. Resumes at any stage.
  ///
  /// [auth] is the recipient's ordinary session or its claim token.
  Future<HistoryTransferProgress> receive(
    K2TransferId id, {
    required HistoryTransferAuth auth,
    required String downloadDirectory,
  }) async {
    var row = await _row(id, historyTransferIncoming);
    if (row.stage == HistoryTransferStage.awaitingHandoff) {
      row = await _handoff(id, row, auth, downloadDirectory);
    }
    if (row.stage == HistoryTransferStage.downloading) {
      row = await _download(id, row, auth);
    }
    if (row.stage == HistoryTransferStage.downloaded) {
      row = await crypto.k2ImportDownloaded(id);
    }
    if (row.stage == HistoryTransferStage.imported) {
      // Only after the import transaction and its ledger committed.
      await transport.acknowledge(
        linkId: id.linkId,
        auth: auth,
        transferId: row.transferId!,
        ciphertextSha256: _hex(row.ciphertextSha256!),
      );
      row = row.copyWith(stage: HistoryTransferStage.acknowledged);
      await localStore.saveHistoryTransfer(row);
    }
    if (row.stage == HistoryTransferStage.acknowledged) {
      await crypto.k2Finish(id);
    }
    return row;
  }

  Future<HistoryTransferProgress> _handoff(
      K2TransferId id,
      HistoryTransferProgress row,
      HistoryTransferAuth auth,
      String directory) async {
    final status = await crypto.k2Inspect(id);
    final payload = _payload(row);
    if (status.stage == K2Stage.waitingApproval) {
      // The first active commit after promotion (the pending state is frozen).
      final tag = payload['approval_tag'];
      final at = payload['approved_at'];
      if (tag is! String || at is! int) {
        throw const K2TransferException('the approval is missing');
      }
      await crypto.k2ApplyApproval(id, base64Decode(tag), approvedAt: at);
    }
    final receipt = await transport.status(id.linkId, auth);
    final claimHash = payload['claim_request_hash'];
    final handoff = receipt.handoff;
    if (!receipt.active ||
        handoff == null ||
        receipt.linkId != id.linkId ||
        receipt.accountId != row.accountId ||
        receipt.sourceDeviceId != row.peerDeviceId ||
        receipt.recipientDeviceId != row.deviceId ||
        (claimHash is String && claimHash != receipt.claimRequestHash) ||
        !_same(receipt.transcriptHash, status.verification.transcriptHash)) {
      throw const K2TransferException('the server describes another transfer');
    }
    Directory(directory).createSync(recursive: true);
    return crypto.k2ReceiveHandoff(
      id,
      handoff: handoff,
      transferId: receipt.transferId,
      ciphertextSha256: _unhex(receipt.ciphertextSha256),
      ciphertextSize: receipt.sizeBytes,
      downloadPath: '$directory${Platform.pathSeparator}'
          'k2-${id.linkId}.download',
    );
  }

  Future<HistoryTransferProgress> _download(K2TransferId id,
      HistoryTransferProgress row, HistoryTransferAuth auth) async {
    final size = row.ciphertextSize!;
    // The native digest check runs on every complete file; a failure deletes
    // the file and the next call starts the download again.
    await transport.download(
      linkId: id.linkId,
      auth: auth,
      expectedSha256: _hex(row.ciphertextSha256!),
      expectedSize: size,
      target: File(row.filePath!),
      verifyDigest: (_) => crypto.k2VerifyDownload(id),
    );
    final next =
        row.copyWith(stage: HistoryTransferStage.downloaded, fileOffset: size);
    await localStore.saveHistoryTransfer(next);
    return next;
  }

  /// Cancels this device's side: the server's copy (best effort: a failure
  /// leaves it to expire) and then the local record, file and row. Imported
  /// history stays.
  Future<void> abandon(K2TransferId id, HistoryTransferAuth auth) async {
    try {
      await transport.cancel(id.linkId, auth);
    } on Exception {
      // The server's copy expires by itself; the local cleanup still runs.
    }
    await crypto.k2Abandon(id);
  }

  Future<HistoryTransferProgress> _row(
      K2TransferId id, String direction) async {
    final row =
        await localStore.loadHistoryTransfer(id.serverOrigin, id.linkId);
    if (row == null || row.direction != direction) {
      throw const K2TransferException('no such transfer');
    }
    return row;
  }

  static Map<String, Object?> _payload(HistoryTransferProgress row) {
    final decoded = jsonDecode(row.payloadJson);
    return decoded is Map ? Map<String, Object?>.from(decoded) : const {};
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var index = 0; index < a.length; index++) {
      diff |= a[index] ^ b[index];
    }
    return diff == 0;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _unhex(String text) => <int>[
        for (var index = 0; index < text.length; index += 2)
          int.parse(text.substring(index, index + 2), radix: 16),
      ];
}
