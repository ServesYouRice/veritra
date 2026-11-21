import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_errors.dart';
import 'package:private_messenger/core/history_transfer_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/history_transfer_service.dart';
import 'package:private_messenger/crypto/k2_transfer_crypto.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/crypto/sha256.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

/// K2 against a hostile or unreliable server, on the real native engine: one
/// source device links two new devices over two links, and the in-memory
/// server serves one link's copy to the other (wrong device, replay), forges
/// or truncates handoffs, swaps or alters ciphertext under rewritten digests,
/// cuts an upload part-way, and replays a finished copy. In every case the
/// new device imports nothing and acknowledges nothing until the genuine copy
/// for its own link arrives.

const _origin = 'https://chat.example.org';
const _account = 'acct_me';
const _sourceDevice = 'dev_src';
const _week = Duration(days: 7);

const _sourceSession = Session(
  baseUrl: _origin,
  token: 'tok_src',
  accountId: _account,
  deviceId: _sourceDevice,
  deviceSecret: 'secret_src',
);

class _Store extends MemoryLocalStore {
  List<int>? exported;

  @override
  Future<List<int>> exportHistorySnapshot({
    bool omitDisappearing = false,
  }) async =>
      exported == null
          ? await super
              .exportHistorySnapshot(omitDisappearing: omitDisappearing)
          : Uint8List.fromList(exported!);
}

class _Copy {
  _Copy(this.receipt, this.ciphertext, this.handoff);
  final HistoryTransferReceipt receipt;
  final Uint8List ciphertext;
  final Uint8List handoff;
  String state = 'active';
}

HistoryTransferReceipt _receipt(
  HistoryTransferReceipt base, {
  String? transferId,
  String? linkId,
  String? recipientDeviceId,
  String? claimRequestHash,
  Uint8List? transcriptHash,
  String? ciphertextSha256,
  int? sizeBytes,
  String? state,
  Uint8List? handoff,
}) =>
    HistoryTransferReceipt(
      transferId: transferId ?? base.transferId,
      linkId: linkId ?? base.linkId,
      accountId: base.accountId,
      sourceDeviceId: base.sourceDeviceId,
      recipientDeviceId: recipientDeviceId ?? base.recipientDeviceId,
      claimRequestHash: claimRequestHash ?? base.claimRequestHash,
      transcriptHash: transcriptHash ?? base.transcriptHash,
      ciphertextSha256: ciphertextSha256 ?? base.ciphertextSha256,
      sizeBytes: sizeBytes ?? base.sizeBytes,
      state: state ?? base.state,
      createdAt: base.createdAt,
      expiresAt: base.expiresAt,
      handoff: handoff ?? base.handoff,
    );

/// The transfer resource for every link, in memory, with hooks for a server
/// that lies.
class _Server implements HistoryTransferTransport {
  final copies = <String, _Copy>{};
  final recipients = <String, String>{};

  /// What the server answers a status request for a link with, instead of
  /// that link's own receipt.
  HistoryTransferReceipt Function(String linkId, HistoryTransferReceipt own)?
      lieAboutReceipt;

  /// What the server sends as a link's ciphertext, instead of its own.
  Uint8List Function(String linkId, Uint8List own)? lieAboutCiphertext;

  /// The next upload's connection drops after this many ciphertext bytes;
  /// nothing is stored.
  int? cutUploadAfter;
  int cutUploads = 0;
  int storedUploads = 0;
  int acks = 0;
  int cancels = 0;

  @override
  Future<HistoryTransferReceipt> upload({
    required String token,
    required String linkId,
    required HistoryTransferMetadata metadata,
    required Stream<List<int>> Function() ciphertext,
  }) async {
    final existing = copies[linkId];
    if (existing != null) {
      if (!existing.receipt.matches(metadata)) {
        throw ApiException(409, '{"error":"idempotency_conflict"}');
      }
      return _own(linkId);
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in ciphertext()) {
      body.add(chunk);
      final cut = cutUploadAfter;
      if (cut != null && body.length >= cut) {
        cutUploadAfter = null;
        cutUploads++;
        throw const SocketException('connection reset by peer');
      }
    }
    final bytes = body.takeBytes();
    if (bytes.length != metadata.sizeBytes ||
        sha256Hex(bytes) != metadata.ciphertextSha256) {
      throw ApiException(400, '{"error":"invalid_body"}');
    }
    storedUploads++;
    copies[linkId] = _Copy(
      HistoryTransferReceipt(
        transferId: metadata.transferId,
        linkId: linkId,
        accountId: _account,
        sourceDeviceId: _sourceDevice,
        recipientDeviceId: recipients[linkId]!,
        claimRequestHash: metadata.claimRequestHash,
        transcriptHash: Uint8List.fromList(metadata.transcriptHash),
        ciphertextSha256: metadata.ciphertextSha256,
        sizeBytes: metadata.sizeBytes,
        state: 'active',
        createdAt: DateTime.utc(2026, 11, 7),
        expiresAt: DateTime.utc(2026, 11, 14),
      ),
      bytes,
      Uint8List.fromList(metadata.handoff),
    );
    return _own(linkId);
  }

  HistoryTransferReceipt _own(String linkId) {
    final copy = copies[linkId]!;
    return _receipt(
      copy.receipt,
      state: copy.state,
      handoff: copy.state == 'active' ? copy.handoff : null,
    );
  }

  @override
  Future<HistoryTransferReceipt> status(
    String linkId,
    HistoryTransferAuth auth,
  ) async {
    if (!copies.containsKey(linkId)) {
      throw ApiException(404, '{"error":"not_found"}');
    }
    final own = _own(linkId);
    return lieAboutReceipt?.call(linkId, own) ?? own;
  }

  @override
  Future<int> download({
    required String linkId,
    required HistoryTransferAuth auth,
    required String expectedSha256,
    required int expectedSize,
    required File target,
    required Future<bool> Function(File complete) verifyDigest,
  }) async {
    final own = copies[linkId]!.ciphertext;
    final bytes = lieAboutCiphertext?.call(linkId, own) ?? own;
    // As the real client: a body of another length never reaches the
    // digest check, and a rejected file is deleted.
    if (bytes.length != expectedSize) {
      if (target.existsSync()) target.deleteSync();
      throw const HistoryTransferMismatch();
    }
    target.writeAsBytesSync(bytes);
    var verified = false;
    try {
      verified = await verifyDigest(target);
    } finally {
      if (!verified && target.existsSync()) target.deleteSync();
    }
    if (!verified) throw const HistoryTransferMismatch();
    return bytes.length;
  }

  @override
  Future<HistoryTransferReceipt> acknowledge({
    required String linkId,
    required HistoryTransferAuth auth,
    required String transferId,
    required String ciphertextSha256,
  }) async {
    final copy = copies[linkId];
    if (copy == null ||
        copy.receipt.transferId != transferId ||
        copy.receipt.ciphertextSha256 != ciphertextSha256) {
      throw ApiException(409, '{"error":"conflict"}');
    }
    acks++;
    copy.state = 'acknowledged';
    return _own(linkId);
  }

  @override
  Future<void> cancel(String linkId, HistoryTransferAuth auth) async {
    cancels++;
    copies[linkId]?.state = 'cancelled';
  }
}

List<int> _snapshot(int now) => HistorySnapshot(
      accountId: _account,
      sourceDeviceId: _sourceDevice,
      counter: 3,
      createdAt: now,
      conversations: const [
        HistoryConversation('conv', 'dm', title: 'historical')
      ],
      messages: [
        for (final (index, body) in const ['first', 'second'].indexed)
          LocalMessage(
            key: '$_sourceDevice:a$index',
            conversationId: 'conv',
            senderAccountId: 'bob',
            senderDeviceId: _sourceDevice,
            kind: 'text',
            body: body,
            createdAt: now - 1000,
            state: 'received',
            senderHidden: false,
          ),
      ],
      reactions: const [],
      pins: const [],
      starred: const {},
      preferences: const [],
    ).encode();

/// One new device, linked to the shared source over its own link.
class _Recipient {
  _Recipient(this.id, this.deviceId, this.claimHash, this.store, this.crypto,
      this.flow, this.downloadDir);
  final K2TransferId id;
  final String deviceId;
  final String claimHash;
  final _Store store;
  final NativeCryptoService crypto;
  final HistoryTransferService flow;
  final String downloadDir;

  Future<HistoryTransferProgress> receive() => flow.receive(
        id,
        auth: HistorySessionAuth('tok_$deviceId'),
        downloadDirectory: downloadDir,
      );

  Future<HistoryTransferProgress?> row() =>
      store.loadHistoryTransfer(_origin, id.linkId);

  Future<List<String?>> bodies() async =>
      (await store.loadMessages('conv')).map((m) => m.body).toList();
}

class _World {
  _World(this.dir);
  final Directory dir;
  final server = _Server();
  final sourceStore = _Store();
  final recipients = <_Recipient>[];
  late NativeCryptoBindings bindings;
  late NativeCryptoService source;
  late HistoryTransferService sourceFlow;
  late List<int> sourceSigningKey;
  String get cacheDir => '${dir.path}/cache';

  Future<void> setUp() async {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    source = TestNativeCryptoService(
      bindings: bindings,
      localStore: sourceStore,
      clock: DateTime.now,
    );
    sourceStore.exported = _snapshot(DateTime.now().millisecondsSinceEpoch);
    final credential = await source.createEnrollmentCredential(
      const EnrollmentReservation(
        id: 'res_src',
        accountId: _account,
        deviceId: _sourceDevice,
        challenge: <int>[1, 2, 3],
      ),
    );
    sourceSigningKey = credential.signingKey;
    await sourceStore.saveSession(_sourceSession);
    await source.activateSession(_sourceSession);
    sourceFlow = HistoryTransferService(
      crypto: source,
      localStore: sourceStore,
      transport: server,
    );
  }

  /// Links a new device over [linkId] and approves it, as the link flow does:
  /// the source's row is `approving`, the recipient's `awaiting_handoff`.
  Future<_Recipient> link(String linkId, String deviceId, int seed) async {
    final id = K2TransferId(_origin, linkId);
    final claimHash = sha256Hex(utf8.encode('claim $linkId'));
    final store = _Store();
    final crypto = TestNativeCryptoService(
      bindings: bindings,
      localStore: store,
      clock: DateTime.now,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final credential = await crypto.createEnrollmentCredential(
      EnrollmentReservation(
        id: 'res_$deviceId',
        accountId: _account,
        deviceId: deviceId,
        challenge: const <int>[1, 2, 3],
      ),
    );
    final sourceRandom = List<int>.filled(32, seed);
    final commitment = await source.k2SourceCommitment(_origin, sourceRandom);
    K2LinkContext context(List<int> key, List<int> random) => K2LinkContext(
          id: id,
          accountId: _account,
          nonce: List<int>.filled(32, seed + 1),
          sourceDeviceId: _sourceDevice,
          sourceSigningKey: sourceSigningKey,
          recipientDeviceId: deviceId,
          recipientSigningKey: credential.signingKey,
          transferPublicKey: key,
          sourceCommitment: commitment,
          recipientRandom: random,
        );
    final secret = List<int>.generate(16, (i) => (seed * 31 + i) & 0xff);
    final linkExpiresAt = now + const Duration(minutes: 30).inMilliseconds;
    final received = await crypto.k2ReceiveBegin(
      context(List<int>.filled(32, 0), List<int>.filled(32, 0)),
      secret,
      originalExpiresAt: linkExpiresAt,
    );
    await store.savePendingEnrollment(
      PendingEnrollment(
        kind: PendingEnrollment.kindDeviceLinkV3,
        origin: _origin,
        accountId: _account,
        deviceId: deviceId,
        payloadJson: '{}',
        state: await crypto.sealPendingEnrollment(),
      ),
    );
    final verification = await source.k2SourceAccept(
      context(received.transferPublicKey, received.recipientRandom),
      secret,
      originalExpiresAt: linkExpiresAt,
      transcriptHash: received.transcriptHash,
      claimTag: received.claimTag,
      sourceRandom: sourceRandom,
    );
    await source.k2SourceConfirm(
      id,
      verification.sas,
      recipientDeviceId: deviceId,
      claimRequestHash: claimHash,
    );
    final approval = await source.k2SourceApprovalRequest(id);
    await source.k2ApplyApproval(id, approval.approvalTag, approvedAt: now);
    await crypto.promotePendingEnrollment(
      Session(
        baseUrl: _origin,
        token: 'tok_$deviceId',
        accountId: _account,
        deviceId: deviceId,
        deviceSecret: 'secret_$deviceId',
      ),
      kind: PendingEnrollment.kindDeviceLinkV3,
      promotionId: claimHash,
      transfer: HistoryTransferProgress(
        origin: _origin,
        linkId: linkId,
        direction: historyTransferIncoming,
        accountId: _account,
        deviceId: deviceId,
        peerDeviceId: _sourceDevice,
        stage: HistoryTransferStage.awaitingHandoff,
        expiresAt: now + _week.inMilliseconds,
        payloadJson: jsonEncode(<String, Object?>{
          'approval_tag': base64Encode(approval.approvalTag),
          'approved_at': now,
          'claim_request_hash': claimHash,
        }),
      ),
    );
    server.recipients[linkId] = deviceId;
    final recipient = _Recipient(
      id,
      deviceId,
      claimHash,
      store,
      crypto,
      HistoryTransferService(
        crypto: crypto,
        localStore: store,
        transport: server,
      ),
      '${dir.path}/download-$deviceId',
    );
    recipients.add(recipient);
    return recipient;
  }

  Future<HistoryTransferProgress> send(_Recipient to) => sourceFlow.send(
        to.id,
        sessionToken: _sourceSession.token,
        cacheDirectory: cacheDir,
      );

  /// Nothing of a refused copy was kept: the row still waits for a handoff,
  /// no handoff or file is stored, no history and no ACK.
  Future<void> expectNothingKept(_Recipient r, {int acks = 0}) async {
    final row = (await r.row())!;
    expect(row.stage, HistoryTransferStage.awaitingHandoff);
    expect(row.handoff, isNull);
    expect(row.transferId, isNull);
    expect(await r.bodies(), isEmpty);
    expect((await r.store.loadHistoryNamespace()).imports, isEmpty);
    expect(server.acks, acks);
    final downloads = Directory(r.downloadDir);
    expect(!downloads.existsSync() || downloads.listSync().isEmpty, isTrue);
  }

  /// The genuine copy for [r]'s own link imports, once.
  Future<void> expectGenuineArrives(_Recipient r) async {
    server
      ..lieAboutReceipt = null
      ..lieAboutCiphertext = null;
    final done = await r.receive();
    expect(done.stage, HistoryTransferStage.acknowledged);
    expect(await r.bodies(), ['first', 'second']);
    expect((await r.store.loadHistoryNamespace()).imports, hasLength(1));
  }

  Future<void> dispose() async {
    await source.dispose();
    for (final r in recipients) {
      await r.crypto.dispose();
    }
  }
}

Future<void> _withWorld(Future<void> Function(_World w) body) async {
  final dir = Directory.systemTemp.createTempSync('k2-adversarial');
  final world = _World(dir);
  try {
    await world.setUp();
    await body(world);
  } finally {
    await world.dispose();
    dir.deleteSync(recursive: true);
  }
}

Uint8List _flip(Uint8List bytes, int at) =>
    Uint8List.fromList(bytes)..[at] ^= 0x01;

void main() {
  final skip = nativeCryptoSkip();

  test(
    'wrong device: a copy sealed for another device is refused by native, '
    'even under a receipt rewritten to name this link',
    () => _withWorld((w) async {
      final b1 = await w.link('link_1', 'dev_b1', 11);
      final b2 = await w.link('link_2', 'dev_b2', 21);
      expect((await w.send(b1)).stage, HistoryTransferStage.uploaded);
      expect((await w.send(b2)).stage, HistoryTransferStage.uploaded);
      final first = w.server.copies['link_1']!;

      // The easy lie: link_1's receipt as it is. The context check refuses
      // it before native sees the handoff.
      w.server.lieAboutReceipt =
          (link, own) => link == 'link_2' ? w.server._own('link_1') : own;
      await expectLater(b2.receive(), throwsA(isA<K2TransferException>()));
      await w.expectNothingKept(b2);

      // The hard lie: every context field names link_2 and dev_b2, but the
      // handoff, transfer and ciphertext are link_1's (sealed to dev_b1's
      // transfer key, signed over link_1's transcript). Only native is left
      // to refuse it.
      w.server
        ..lieAboutReceipt = ((link, own) => link == 'link_2'
            ? _receipt(
                own,
                transferId: first.receipt.transferId,
                ciphertextSha256: first.receipt.ciphertextSha256,
                sizeBytes: first.receipt.sizeBytes,
                handoff: first.handoff,
              )
            : own)
        ..lieAboutCiphertext =
            ((link, own) => link == 'link_2' ? first.ciphertext : own);
      await expectLater(b2.receive(), throwsA(isA<NativeCryptoException>()));
      await w.expectNothingKept(b2);

      // Both genuine copies still arrive, each on its own device.
      await w.expectGenuineArrives(b2);
      await w.expectGenuineArrives(b1);
      expect(w.server.acks, 2);
    }),
    skip: skip,
  );

  test(
    'replay across links: this link\'s genuine handoff with another link\'s '
    'ciphertext is refused, whatever digest the server names',
    () => _withWorld((w) async {
      final b1 = await w.link('link_1', 'dev_b1', 11);
      final b2 = await w.link('link_2', 'dev_b2', 21);
      await w.send(b1);
      await w.send(b2);
      final first = w.server.copies['link_1']!;
      final second = w.server.copies['link_2']!;
      expect(first.ciphertext.length, second.ciphertext.length);
      expect(first.receipt.transferId, isNot(second.receipt.transferId));

      // The receipt names link_1's digest to match the swapped bytes: the
      // authenticated handoff names link_2's, so nothing is stored.
      w.server.lieAboutReceipt = (link, own) => link == 'link_2'
          ? _receipt(own, ciphertextSha256: first.receipt.ciphertextSha256)
          : own;
      await expectLater(b2.receive(), throwsA(isA<K2TransferException>()));
      await w.expectNothingKept(b2);

      // The honest receipt, but link_1's bytes: the native digest check
      // rejects the file, which is deleted; nothing is imported.
      w.server
        ..lieAboutReceipt = null
        ..lieAboutCiphertext =
            ((link, own) => link == 'link_2' ? first.ciphertext : own);
      await expectLater(
        b2.receive(),
        throwsA(isA<HistoryTransferMismatch>()),
      );
      final row = (await b2.row())!;
      expect(row.stage, HistoryTransferStage.downloading);
      expect(File(row.filePath!).existsSync(), isFalse);
      expect(await b2.bodies(), isEmpty);
      expect(w.server.acks, 0);

      await w.expectGenuineArrives(b2);
    }),
    skip: skip,
  );

  test(
    'a forged handoff is refused by native wherever it was changed, and '
    'nothing of it is kept',
    () => _withWorld((w) async {
      final b1 = await w.link('link_1', 'dev_b1', 11);
      await w.send(b1);
      final genuine = w.server.copies['link_1']!.handoff;
      final forgeries = <String, Uint8List>{
        'first byte': _flip(genuine, 0),
        'a quarter in': _flip(genuine, genuine.length ~/ 4),
        'the middle': _flip(genuine, genuine.length ~/ 2),
        'last byte': _flip(genuine, genuine.length - 1),
        'one byte short': Uint8List.sublistView(genuine, 0, genuine.length - 1),
        'one byte more': Uint8List.fromList([...genuine, 0]),
      };
      for (final MapEntry(key: name, value: forged) in forgeries.entries) {
        w.server.lieAboutReceipt = (_, own) => _receipt(own, handoff: forged);
        await expectLater(
          b1.receive(),
          throwsA(isA<NativeCryptoException>()),
          reason: name,
        );
        await w.expectNothingKept(b1);
      }
      await w.expectGenuineArrives(b1);
    }),
    skip: skip,
  );

  test(
    'tampered bundle: altered or cut ciphertext under a digest the server '
    'rewrote to match is refused at the handoff',
    () => _withWorld((w) async {
      final b1 = await w.link('link_1', 'dev_b1', 11);
      await w.send(b1);
      final genuine = w.server.copies['link_1']!.ciphertext;
      final tampered = <String, Uint8List>{
        'header byte': _flip(genuine, 0),
        'a chunk byte': _flip(genuine, genuine.length ~/ 2),
        'last tag byte': _flip(genuine, genuine.length - 1),
        'one chunk short':
            Uint8List.sublistView(genuine, 0, genuine.length - 16),
      };
      for (final MapEntry(key: name, value: bytes) in tampered.entries) {
        w.server
          ..lieAboutReceipt = ((_, own) => _receipt(
                own,
                ciphertextSha256: sha256Hex(bytes),
                sizeBytes: bytes.length,
              ))
          ..lieAboutCiphertext = ((_, __) => bytes);
        await expectLater(
          b1.receive(),
          throwsA(isA<K2TransferException>()),
          reason: name,
        );
        await w.expectNothingKept(b1);
      }

      // Under the genuine digest, altered bytes fail the native check.
      w.server
        ..lieAboutReceipt = null
        ..lieAboutCiphertext = ((_, __) => tampered['a chunk byte']!);
      await expectLater(b1.receive(), throwsA(isA<HistoryTransferMismatch>()));
      expect(await b1.bodies(), isEmpty);
      expect(w.server.acks, 0);

      await w.expectGenuineArrives(b1);
    }),
    skip: skip,
  );

  test(
    'partial upload: a connection cut part-way stores nothing, keeps the '
    'cached copy as it was, and the retry sends exactly that copy once',
    () => _withWorld((w) async {
      final b1 = await w.link('link_1', 'dev_b1', 11);
      w.server.cutUploadAfter = 1;
      await expectLater(w.send(b1), throwsA(isA<SocketException>()));
      var row = (await w.sourceStore.loadHistoryTransfer(_origin, 'link_1'))!;
      expect(row.stage, HistoryTransferStage.snapshotReady);
      final cache = File(row.filePath!);
      final cached = cache.readAsBytesSync();
      expect(cached.length, row.ciphertextSize);
      expect(w.server.copies, isEmpty);
      expect(w.server.cutUploads, 1);

      // A second cut, halfway through: still nothing stored, cache intact.
      w.server.cutUploadAfter = cached.length ~/ 2;
      await expectLater(w.send(b1), throwsA(isA<SocketException>()));
      row = (await w.sourceStore.loadHistoryTransfer(_origin, 'link_1'))!;
      expect(row.stage, HistoryTransferStage.snapshotReady);
      expect(cache.readAsBytesSync(), cached);
      expect(w.server.copies, isEmpty);

      // The new device asking meanwhile finds nothing yet (a 404 is the
      // wait), and keeps nothing.
      await expectLater(
        b1.receive(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
      await w.expectNothingKept(b1);

      expect((await w.send(b1)).stage, HistoryTransferStage.uploaded);
      expect(w.server.storedUploads, 1);
      expect(w.server.copies['link_1']!.ciphertext, cached);
      expect(
        w.server.copies['link_1']!.receipt.ciphertextSha256,
        hexOf(row.ciphertextSha256!),
      );
      await w.expectGenuineArrives(b1);

      // The source settles once the server shows the ACK.
      expect((await w.send(b1)).stage, HistoryTransferStage.acknowledged);
      expect(
        await w.sourceStore.loadHistoryTransfer(_origin, 'link_1'),
        isNull,
      );
    }),
    skip: skip,
  );

  test(
    'replay after the ACK: a finished copy offered again finds no transfer '
    'and imports nothing more',
    () => _withWorld((w) async {
      final b1 = await w.link('link_1', 'dev_b1', 11);
      await w.send(b1);
      await w.expectGenuineArrives(b1);
      expect(await b1.row(), isNull);

      // The server reopens the same copy, handoff and all.
      w.server.copies['link_1']!.state = 'active';
      await expectLater(b1.receive(), throwsA(isA<K2TransferException>()));
      expect(await b1.bodies(), ['first', 'second']);
      expect((await b1.store.loadHistoryNamespace()).imports, hasLength(1));
      expect(w.server.acks, 1);
      // Native forgot the transfer key with the record: the handoff cannot
      // be opened again on this device.
      await expectLater(b1.crypto.k2Inspect(b1.id), throwsA(anything));
    }),
    skip: skip,
  );
}
