import 'dart:async';
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
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';
import 'l1_test_lists.dart';

/// K2 orchestration on the native engine and the schema-18 tables: a source
/// and a recipient, each a real `NativeCryptoService` on its own store,
/// linked through the real native controls, move one history bundle through
/// an in-memory transport. Faults are injected at the stored-outcome points
/// the design names (lost commit outcome, a failed commit, a lost upload
/// reply, a crash after the import, a corrupt download, an expired
/// transfer).

const _origin = 'https://chat.example.org';
const _account = 'acct_me';
const _sourceDevice = 'dev_src';
const _newDevice = 'dev_new';
const _linkId = 'link_1';
const _claimHash =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _week = Duration(days: 7);

const _sourceSession = Session(
  baseUrl: _origin,
  token: 'tok_src',
  accountId: _account,
  deviceId: _sourceDevice,
  deviceSecret: 'secret_src',
);
const _newSession = Session(
  baseUrl: _origin,
  token: 'tok_new',
  accountId: _account,
  deviceId: _newDevice,
  deviceSecret: 'secret_new',
);

/// Injects the failures the stored outcome of a transfer step can have.
class _FaultStore extends MemoryLocalStore {
  /// A transfer commit in this stage fails before anything is stored.
  String? failBeforeStage;

  /// A transfer commit in this stage is stored, then reports failure.
  String? loseOutcomeStage;

  /// Saving a row in this stage fails once, before it is stored.
  String? failSaveStage;

  /// What the source exports as its history snapshot.
  List<int>? exported;

  @override
  Future<void> commitHistoryTransferState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
    required HistoryTransferProgress transfer,
  }) async {
    if (failBeforeStage == transfer.stage) {
      failBeforeStage = null;
      throw StateError('disk full');
    }
    await super.commitHistoryTransferState(
        expectedCounter: expectedCounter,
        expectedCursor: expectedCursor,
        state: state,
        transfer: transfer);
    if (loseOutcomeStage == transfer.stage) {
      loseOutcomeStage = null;
      throw StateError('outcome lost');
    }
  }

  @override
  Future<void> saveHistoryTransfer(HistoryTransferProgress transfer) async {
    if (failSaveStage == transfer.stage) {
      failSaveStage = null;
      throw StateError('crash');
    }
    await super.saveHistoryTransfer(transfer);
  }

  @override
  Future<List<int>> exportHistorySnapshot() async => exported == null
      ? await super.exportHistorySnapshot()
      : Uint8List.fromList(exported!);
}

/// The server's side of one transfer, in memory.
class _FakeTransport implements HistoryTransferTransport {
  HistoryTransferReceipt? stored;
  Uint8List? ciphertext;
  Uint8List? handoff;
  bool corruptDownload = false;
  bool loseUploadReply = false;

  /// The status the ACK is refused with (the server holds no active copy).
  int? ackRefusedWith;

  /// The download writes the file and stops before the digest check.
  bool stopAfterDownload = false;
  String? wrongTransferId;
  int uploads = 0;
  bool cancelled = false;

  HistoryTransferReceipt _receipt(String state, {bool withHandoff = true}) {
    final base = stored!;
    return HistoryTransferReceipt(
      transferId: wrongTransferId ?? base.transferId,
      linkId: base.linkId,
      accountId: base.accountId,
      sourceDeviceId: base.sourceDeviceId,
      recipientDeviceId: base.recipientDeviceId,
      claimRequestHash: base.claimRequestHash,
      transcriptHash: base.transcriptHash,
      ciphertextSha256: base.ciphertextSha256,
      sizeBytes: base.sizeBytes,
      state: state,
      createdAt: base.createdAt,
      expiresAt: base.expiresAt,
      handoff: withHandoff && state == 'active' ? handoff : null,
    );
  }

  @override
  Future<HistoryTransferReceipt> upload({
    required String token,
    required String linkId,
    required HistoryTransferMetadata metadata,
    required Stream<List<int>> Function() ciphertext,
  }) async {
    uploads++;
    if (stored == null) {
      final body = BytesBuilder(copy: false);
      await for (final chunk in ciphertext()) {
        body.add(chunk);
      }
      final bytes = body.takeBytes();
      if (bytes.length != metadata.sizeBytes) {
        throw StateError('wrong length');
      }
      this.ciphertext = bytes;
      handoff = metadata.handoff;
      stored = HistoryTransferReceipt(
        transferId: metadata.transferId,
        linkId: linkId,
        accountId: _account,
        sourceDeviceId: _sourceDevice,
        recipientDeviceId: _newDevice,
        claimRequestHash: metadata.claimRequestHash,
        transcriptHash: metadata.transcriptHash,
        ciphertextSha256: metadata.ciphertextSha256,
        sizeBytes: metadata.sizeBytes,
        state: 'active',
        createdAt: DateTime.utc(2026, 11, 7),
        expiresAt: DateTime.utc(2026, 11, 14),
      );
    } else if (!stored!.matches(metadata)) {
      throw StateError('a different transfer is stored');
    }
    if (loseUploadReply) {
      loseUploadReply = false;
      throw const SocketException('reply lost');
    }
    return _receipt('active');
  }

  @override
  Future<HistoryTransferReceipt> status(
      String linkId, HistoryTransferAuth auth) async {
    if (stored == null) throw StateError('no transfer yet');
    return _receipt(stored!.state);
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
    final bytes = Uint8List.fromList(ciphertext!);
    if (corruptDownload) bytes[bytes.length ~/ 2] ^= 1;
    target.writeAsBytesSync(bytes);
    if (stopAfterDownload) throw const SocketException('stopped');
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
    if (ackRefusedWith != null) throw ApiException(ackRefusedWith!);
    final base = stored!;
    stored = HistoryTransferReceipt(
      transferId: base.transferId,
      linkId: base.linkId,
      accountId: base.accountId,
      sourceDeviceId: base.sourceDeviceId,
      recipientDeviceId: base.recipientDeviceId,
      claimRequestHash: base.claimRequestHash,
      transcriptHash: base.transcriptHash,
      ciphertextSha256: base.ciphertextSha256,
      sizeBytes: base.sizeBytes,
      state: 'acknowledged',
      createdAt: base.createdAt,
      expiresAt: base.expiresAt,
    );
    return stored!;
  }

  @override
  Future<void> cancel(String linkId, HistoryTransferAuth auth) async {
    cancelled = true;
  }
}

LocalMessage _message(String action, String body, int now) => LocalMessage(
      key: '$_sourceDevice:$action',
      conversationId: 'conv',
      senderAccountId: 'bob',
      senderDeviceId: _sourceDevice,
      kind: 'text',
      body: body,
      createdAt: now - 1000,
      state: 'received',
      senderHidden: false,
    );

/// The source's history snapshot as it would export it.
List<int> _snapshot(int now,
        {int counter = 3, List<String> bodies = const []}) =>
    HistorySnapshot(
      accountId: _account,
      sourceDeviceId: _sourceDevice,
      counter: counter,
      createdAt: now,
      conversations: const [
        HistoryConversation('conv', 'dm', title: 'historical'),
      ],
      messages: [
        for (var index = 0; index < bodies.length; index++)
          _message('a$index', bodies[index], now),
      ],
      reactions: const [],
      pins: const [],
      starred: const {},
      preferences: const [],
    ).encode();

class _Pair {
  _Pair(this.dir);
  final Directory dir;
  late NativeCryptoBindings bindings;
  late DateTime clock;
  final sourceStore = _FaultStore();
  final recipientStore = _FaultStore();
  final transport = _FakeTransport();
  late NativeCryptoService source;
  late NativeCryptoService recipient;
  late HistoryTransferService sourceFlow;
  late HistoryTransferService recipientFlow;
  final id = const K2TransferId(_origin, _linkId);
  late int approvedAt;
  late String cacheDir;
  late String downloadDir;

  /// Links the two devices through the native controls and approves, so the
  /// source row is `approving` and the recipient's `awaiting_handoff`.
  Future<void> link(
      {List<String> bodies = const ['first', 'second'],
      bool loseConfirmOutcome = false}) async {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    clock = DateTime.now().toUtc();
    final now = clock.millisecondsSinceEpoch;
    source = TestNativeCryptoService(
        bindings: bindings, localStore: sourceStore, clock: () => clock);
    recipient = TestNativeCryptoService(
        bindings: bindings, localStore: recipientStore, clock: () => clock);
    cacheDir = '${dir.path}/cache';
    downloadDir = '${dir.path}/download';
    sourceStore.exported = _snapshot(now, bodies: bodies);

    final sourceCredential = await source.createEnrollmentCredential(
        const EnrollmentReservation(
            id: 'res_src',
            accountId: _account,
            deviceId: _sourceDevice,
            challenge: <int>[1, 2, 3]));
    await sourceStore.saveSession(_sourceSession);
    await source.activateSession(_sourceSession);

    final newCredential = await recipient.createEnrollmentCredential(
        const EnrollmentReservation(
            id: 'res_new',
            accountId: _account,
            deviceId: _newDevice,
            challenge: <int>[1, 2, 3]));
    final sourceRandom = List<int>.filled(32, 6);
    final commitment = await source.k2SourceCommitment(_origin, sourceRandom);
    K2LinkContext context(List<int> key, List<int> random) => K2LinkContext(
        id: id,
        accountId: _account,
        nonce: List<int>.filled(32, 9),
        sourceDeviceId: _sourceDevice,
        sourceSigningKey: sourceCredential.signingKey,
        recipientDeviceId: _newDevice,
        recipientSigningKey: newCredential.signingKey,
        transferPublicKey: key,
        sourceCommitment: commitment,
        recipientRandom: random);
    final secret = List<int>.filled(16, 8);
    final originalExpiresAt = now + const Duration(minutes: 30).inMilliseconds;
    final received = await recipient.k2ReceiveBegin(
        context(List<int>.filled(32, 0), List<int>.filled(32, 0)), secret,
        originalExpiresAt: originalExpiresAt);
    final sealed = await recipient.sealPendingEnrollment();
    await recipientStore.savePendingEnrollment(PendingEnrollment(
      kind: PendingEnrollment.kindDeviceLinkV3,
      origin: _origin,
      accountId: _account,
      deviceId: _newDevice,
      payloadJson: '{}',
      state: sealed,
    ));
    final verification = await source.k2SourceAccept(
        context(received.transferPublicKey, received.recipientRandom), secret,
        originalExpiresAt: originalExpiresAt,
        transcriptHash: received.transcriptHash,
        claimTag: received.claimTag,
        sourceRandom: sourceRandom);
    // The pending (frozen) identity shows the same code from the reveal.
    expect(await recipient.k2RevealSas(id, sourceRandom), verification.sas);
    if (loseConfirmOutcome) {
      // The confirm committed, then the app crashed before the approval POST.
      sourceStore.loseOutcomeStage = HistoryTransferStage.approving;
      await expectLater(
          source.k2SourceConfirm(id, verification.sas,
              recipientDeviceId: _newDevice, claimRequestHash: _claimHash),
          throwsA(isA<StateError>()));
      expect((await sourceStore.loadHistoryTransfer(_origin, _linkId))!.stage,
          HistoryTransferStage.approving);
    }
    await source.k2SourceConfirm(id, verification.sas,
        recipientDeviceId: _newDevice, claimRequestHash: _claimHash);
    final approval = await source.k2SourceApprovalRequest(id);
    approvedAt = now;
    await source.k2ApplyApproval(id, approval.approvalTag,
        approvedAt: approvedAt);
    await recipient.promotePendingEnrollment(
      _newSession,
      kind: PendingEnrollment.kindDeviceLinkV3,
      promotionId: _claimHash,
      transfer: HistoryTransferProgress(
        origin: _origin,
        linkId: _linkId,
        direction: historyTransferIncoming,
        accountId: _account,
        deviceId: _newDevice,
        peerDeviceId: _sourceDevice,
        stage: HistoryTransferStage.awaitingHandoff,
        expiresAt: approvedAt + _week.inMilliseconds,
        payloadJson: jsonEncode(<String, Object?>{
          'approval_tag': base64Encode(approval.approvalTag),
          'approved_at': approvedAt,
          'claim_request_hash': _claimHash,
        }),
      ),
    );
    sourceFlow = HistoryTransferService(
        crypto: source, localStore: sourceStore, transport: transport);
    recipientFlow = HistoryTransferService(
        crypto: recipient, localStore: recipientStore, transport: transport);
  }

  Future<HistoryTransferProgress> send() => sourceFlow.send(id,
      sessionToken: _sourceSession.token, cacheDirectory: cacheDir);

  Future<HistoryTransferProgress> receive() => recipientFlow.receive(id,
      auth: HistorySessionAuth(_newSession.token),
      downloadDirectory: downloadDir);

  Future<HistoryTransferProgress?> sourceRow() =>
      sourceStore.loadHistoryTransfer(_origin, _linkId);
  Future<HistoryTransferProgress?> recipientRow() =>
      recipientStore.loadHistoryTransfer(_origin, _linkId);

  Future<void> dispose() async {
    await source.dispose();
    await recipient.dispose();
  }
}

Future<void> _withPair(
  Future<void> Function(_Pair pair) body, {
  List<String> bodies = const ['first', 'second'],
  bool loseConfirmOutcome = false,
}) async {
  final dir = Directory.systemTemp.createTempSync('k2-orchestration');
  final pair = _Pair(dir);
  try {
    await pair.link(bodies: bodies, loseConfirmOutcome: loseConfirmOutcome);
    await body(pair);
  } finally {
    await pair.dispose();
    dir.deleteSync(recursive: true);
  }
}

bool _fileGone(Directory dir) => !dir.existsSync() || dir.listSync().isEmpty;

void main() {
  final skip = nativeCryptoSkip();

  test(
      'history moves from the source to the new device and both clean up',
      () => _withPair((pair) async {
            final cursor = await pair.recipientStore.loadSyncCursor();
            final sourceCounter =
                (await pair.sourceStore.loadCryptoState())!.counter;
            var sent = await pair.send();
            expect(sent.stage, HistoryTransferStage.uploaded);
            expect(File(sent.filePath!).existsSync(), isTrue);
            expect(sent.handoff, isNotEmpty);

            final received = await pair.receive();
            expect(received.stage, HistoryTransferStage.acknowledged);
            expect(await pair.recipientRow(), isNull);
            expect(_fileGone(Directory(pair.downloadDir)), isTrue);

            final messages = await pair.recipientStore.loadMessages('conv');
            expect(messages.map((m) => m.body), ['first', 'second']);
            expect(messages.every((m) => m.state == 'restored'), isTrue);
            final namespace = await pair.recipientStore.loadHistoryNamespace();
            expect(namespace.imports, hasLength(1));
            // Importing never moves the sync cursor.
            expect(await pair.recipientStore.loadSyncCursor(), cursor);

            sent = await pair.send();
            expect(sent.stage, HistoryTransferStage.acknowledged);
            expect(await pair.sourceRow(), isNull);
            expect(_fileGone(Directory(pair.cacheDir)), isTrue);
            expect((await pair.sourceStore.loadCryptoState())!.counter,
                greaterThan(sourceCounter));

            // The native records are gone, and both devices still work: the
            // in-memory state is the stored one after every commit.
            await expectLater(
                pair.source.k2Inspect(pair.id), throwsA(anything));
            await expectLater(
                pair.recipient.k2Inspect(pair.id), throwsA(anything));
            await pair.source.createReplenishmentKeyPackages(count: 1);
            await pair.recipient.createReplenishmentKeyPackages(count: 1);
          }),
      skip: skip);

  test('the approval tag is released only after the intent is committed',
      () async {
    final dir = Directory.systemTemp.createTempSync('k2-orchestration');
    final pair = _Pair(dir);
    try {
      pair.bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
      final store = _FaultStore();
      final service =
          TestNativeCryptoService(bindings: pair.bindings, localStore: store);
      await service.createEnrollmentCredential(const EnrollmentReservation(
          id: 'r',
          accountId: _account,
          deviceId: _sourceDevice,
          challenge: [1]));
      await store.saveSession(_sourceSession);
      await service.activateSession(_sourceSession);
      await expectLater(service.k2SourceApprovalRequest(pair.id),
          throwsA(isA<K2TransferException>()));
      await service.dispose();
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);

  test('an approved transfer refuses a later confirm', () async {
    final dir = Directory.systemTemp.createTempSync('k2-orchestration');
    final pair = _Pair(dir);
    try {
      await pair.link();
      final before = await pair.sourceRow();
      final intent = (await pair.source.k2Inspect(pair.id)).intentPresent;
      expect(intent, isTrue);
      expect(before!.stage, HistoryTransferStage.approving);
      // An approved transfer is past its approval: the retry is refused.
      await expectLater(
          pair.source.k2SourceConfirm(pair.id, '00000000',
              recipientDeviceId: _newDevice, claimRequestHash: _claimHash),
          throwsA(anything));
      expect((await pair.sourceRow())!.stage, HistoryTransferStage.approving);
    } finally {
      await pair.dispose();
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);

  test('the pending state cannot grow a transfer record after its seal',
      () async {
    final dir = Directory.systemTemp.createTempSync('k2-orchestration');
    try {
      final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
      final service = TestNativeCryptoService(
          bindings: bindings, localStore: _FaultStore());
      final credential = await service.createEnrollmentCredential(
          const EnrollmentReservation(
              id: 'r',
              accountId: _account,
              deviceId: _newDevice,
              challenge: [1]));
      await service.sealPendingEnrollment();
      await expectLater(
          service.k2ReceiveBegin(
              K2LinkContext(
                  id: const K2TransferId(_origin, _linkId),
                  accountId: _account,
                  nonce: List<int>.filled(32, 9),
                  sourceDeviceId: _sourceDevice,
                  sourceSigningKey: credential.signingKey,
                  recipientDeviceId: _newDevice,
                  recipientSigningKey: credential.signingKey,
                  transferPublicKey: List<int>.filled(32, 0),
                  sourceCommitment: List<int>.filled(32, 3),
                  recipientRandom: List<int>.filled(32, 0)),
              List<int>.filled(16, 8),
              originalExpiresAt: DateTime.now().millisecondsSinceEpoch + 1000),
          throwsA(isA<K2TransferException>()));
      await service.dispose();
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);

  test(
      'a snapshot commit that fails leaves no cache and the next try works',
      () => _withPair((pair) async {
            pair.sourceStore.failBeforeStage =
                HistoryTransferStage.snapshotReady;
            await expectLater(pair.send(), throwsA(isA<StateError>()));
            expect((await pair.sourceRow())!.stage,
                HistoryTransferStage.approving);
            expect(_fileGone(Directory(pair.cacheDir)), isTrue);
            expect((await pair.send()).stage, HistoryTransferStage.uploaded);
            expect((await pair.receive()).stage,
                HistoryTransferStage.acknowledged);
            expect(
                await pair.recipientStore.loadMessages('conv'), hasLength(2));
          }),
      skip: skip);

  test(
      'a snapshot commit whose outcome was lost keeps its frozen copy',
      () => _withPair((pair) async {
            pair.sourceStore.loseOutcomeStage =
                HistoryTransferStage.snapshotReady;
            await expectLater(pair.send(), throwsA(isA<StateError>()));
            final stored = (await pair.sourceRow())!;
            expect(stored.stage, HistoryTransferStage.snapshotReady);
            expect(File(stored.filePath!).existsSync(), isTrue);
            // The retry uploads exactly the stored copy and handoff.
            final resumed = await pair.send();
            expect(resumed.stage, HistoryTransferStage.uploaded);
            expect(resumed.transferId, stored.transferId);
            expect(resumed.handoff, stored.handoff);
            expect((await pair.receive()).stage,
                HistoryTransferStage.acknowledged);
          }),
      skip: skip);

  test(
      'a lost upload reply is retried without a second copy',
      () => _withPair((pair) async {
            pair.transport.loseUploadReply = true;
            await expectLater(pair.send(), throwsA(isA<SocketException>()));
            expect((await pair.sourceRow())!.stage,
                HistoryTransferStage.snapshotReady);
            expect((await pair.send()).stage, HistoryTransferStage.uploaded);
            expect(pair.transport.uploads, 2);
            expect((await pair.receive()).stage,
                HistoryTransferStage.acknowledged);
          }),
      skip: skip);

  test(
      'a cached copy that went missing is refused, never regenerated',
      () => _withPair((pair) async {
            pair.transport.loseUploadReply = true;
            await expectLater(pair.send(), throwsA(isA<SocketException>()));
            final row = (await pair.sourceRow())!;
            File(row.filePath!).deleteSync();
            await expectLater(pair.send(), throwsA(isA<K2TransferException>()));
            expect((await pair.sourceRow())!.transferId, row.transferId);
            await pair.sourceFlow
                .abandon(pair.id, HistorySessionAuth(_sourceSession.token));
            expect(pair.transport.cancelled, isTrue);
            expect(await pair.sourceRow(), isNull);
            await expectLater(
                pair.source.k2Inspect(pair.id), throwsA(anything));
          }),
      skip: skip);

  test(
      'a crash after the import committed re-imports as a no-op',
      () => _withPair((pair) async {
            await pair.send();
            pair.recipientStore.failSaveStage = HistoryTransferStage.imported;
            await expectLater(pair.receive(), throwsA(isA<StateError>()));
            expect((await pair.recipientRow())!.stage,
                HistoryTransferStage.downloaded);
            expect(
                await pair.recipientStore.loadMessages('conv'), hasLength(2));
            final done = await pair.receive();
            expect(done.stage, HistoryTransferStage.acknowledged);
            // The ledger made the second import a no-op: no duplicates.
            expect(
                await pair.recipientStore.loadMessages('conv'), hasLength(2));
            expect((await pair.recipientStore.loadHistoryNamespace()).imports,
                hasLength(1));
          }),
      skip: skip);

  test(
      'a crash after the ACK is finished by the next call',
      () => _withPair((pair) async {
            await pair.send();
            pair.recipientStore.failSaveStage =
                HistoryTransferStage.acknowledged;
            await expectLater(pair.receive(), throwsA(isA<StateError>()));
            expect(pair.transport.stored!.state, 'acknowledged');
            expect((await pair.recipientRow())!.stage,
                HistoryTransferStage.imported);
            // The server accepts an exact replay of the ACK.
            final done = await pair.receive();
            expect(done.stage, HistoryTransferStage.acknowledged);
            expect(await pair.recipientRow(), isNull);
          }),
      skip: skip);

  test(
      'a corrupt download imports nothing and is fetched again',
      () => _withPair((pair) async {
            await pair.send();
            pair.transport.corruptDownload = true;
            await expectLater(
                pair.receive(), throwsA(isA<HistoryTransferMismatch>()));
            expect((await pair.recipientRow())!.stage,
                HistoryTransferStage.downloading);
            expect(await pair.recipientStore.loadMessages('conv'), isEmpty);
            expect(_fileGone(Directory(pair.downloadDir)), isTrue);
            pair.transport.corruptDownload = false;
            expect((await pair.receive()).stage,
                HistoryTransferStage.acknowledged);
            expect(
                await pair.recipientStore.loadMessages('conv'), hasLength(2));
          }),
      skip: skip);

  test(
      'a receipt that names another transfer is refused before anything is kept',
      () => _withPair((pair) async {
            await pair.send();
            pair.transport.wrongTransferId = 'd' * 64;
            await expectLater(
                pair.receive(), throwsA(isA<K2TransferException>()));
            final row = (await pair.recipientRow())!;
            expect(row.stage, HistoryTransferStage.awaitingHandoff);
            expect(row.handoff, isNull);
            expect(await pair.recipientStore.loadMessages('conv'), isEmpty);
          }),
      skip: skip);

  test(
      'a recipient resuming after the link expired still applies the approval',
      () => _withPair((pair) async {
            // The harness link expires 30 minutes after `link()`; the transfer
            // itself stays live for seven days from the approval.
            pair.clock = pair.clock.add(const Duration(hours: 1));
            await pair.send();
            final received = await pair.receive();
            expect(received.stage, HistoryTransferStage.acknowledged);
            final messages = await pair.recipientStore.loadMessages('conv');
            expect(messages.map((m) => m.body), ['first', 'second']);
          }),
      skip: skip);

  test(
      'an expired transfer is refused and then swept',
      () => _withPair((pair) async {
            await pair.send();
            // Past the seven-day window.
            pair.clock = pair.clock.add(const Duration(days: 8));
            await expectLater(pair.receive(), throwsA(anything));
            expect(await pair.recipientStore.loadMessages('conv'), isEmpty);
            expect(await pair.recipient.k2ExpireTransfers(), 1);
            expect(await pair.recipientRow(), isNull);
            await expectLater(
                pair.recipient.k2Inspect(pair.id), throwsA(anything));
            expect(await pair.source.k2ExpireTransfers(), 1);
            expect(await pair.sourceRow(), isNull);
            expect(_fileGone(Directory(pair.cacheDir)), isTrue);
          }),
      skip: skip);

  test(
      'a bundle the history importer refuses keeps its stage and imports nothing',
      () => _withPair((pair) async {
            // A snapshot of another account passes native (the bytes are
            // opaque to it) and is refused by the importer's own checks.
            pair.sourceStore.exported = HistorySnapshot(
              accountId: 'someone_else',
              sourceDeviceId: _sourceDevice,
              counter: 3,
              createdAt: pair.clock.millisecondsSinceEpoch,
              conversations: const [],
              messages: const [],
              reactions: const [],
              pins: const [],
              starred: const {},
              preferences: const [],
            ).encode();
            await pair.send();
            await expectLater(pair.receive(), throwsA(isA<FormatException>()));
            expect((await pair.recipientRow())!.stage,
                HistoryTransferStage.downloaded);
            expect(await pair.recipientStore.loadMessages('conv'), isEmpty);
          }),
      skip: skip);

  test(
      'a confirm whose outcome was lost is retried onto the same row',
      () => _withPair(loseConfirmOutcome: true, (pair) async {
            final row = (await pair.sourceRow())!;
            expect(row.stage, HistoryTransferStage.approving);
            final original =
                (await pair.source.k2Inspect(pair.id)).originalExpiresAt;
            expect(row.expiresAt, original + _week.inMilliseconds);
            // The whole transfer still completes from that row.
            expect((await pair.send()).stage, HistoryTransferStage.uploaded);
            expect((await pair.receive()).stage,
                HistoryTransferStage.acknowledged);
            expect(
                await pair.recipientStore.loadMessages('conv'), hasLength(2));
          }),
      skip: skip);

  test(
      'a copy the server closed is refused and can be abandoned',
      () => _withPair((pair) async {
            await pair.send();
            final base = pair.transport.stored!;
            pair.transport.stored = HistoryTransferReceipt(
              transferId: base.transferId,
              linkId: base.linkId,
              accountId: base.accountId,
              sourceDeviceId: base.sourceDeviceId,
              recipientDeviceId: base.recipientDeviceId,
              claimRequestHash: base.claimRequestHash,
              transcriptHash: base.transcriptHash,
              ciphertextSha256: base.ciphertextSha256,
              sizeBytes: base.sizeBytes,
              state: 'cancelled',
              createdAt: base.createdAt,
              expiresAt: base.expiresAt,
            );
            await expectLater(pair.send(), throwsA(isA<K2TransferException>()));
            expect(
                (await pair.sourceRow())!.stage, HistoryTransferStage.uploaded);
            await pair.sourceFlow
                .abandon(pair.id, HistorySessionAuth(_sourceSession.token));
            expect(await pair.sourceRow(), isNull);
            expect(_fileGone(Directory(pair.cacheDir)), isTrue);
          }),
      skip: skip);

  test(
      'an ACK on a copy the server closed is a typed refusal and the row stays',
      () => _withPair((pair) async {
            await pair.send();
            for (final status in [404, 409, 410]) {
              pair.transport.ackRefusedWith = status;
              await expectLater(
                  pair.receive(),
                  throwsA(isA<K2TransferException>().having(
                      (e) => e.reason, 'reason', contains('server closed'))));
              // The history is imported and stays; the row is not
              // acknowledged, so the caller abandons it.
              expect((await pair.recipientRow())!.stage,
                  HistoryTransferStage.imported);
              expect(
                  await pair.recipientStore.loadMessages('conv'), hasLength(2));
            }
            // Any other failure keeps its own type.
            pair.transport.ackRefusedWith = 500;
            await expectLater(pair.receive(), throwsA(isA<ApiException>()));
            pair.transport.ackRefusedWith = null;
            await pair.recipientFlow
                .abandon(pair.id, HistorySessionAuth(_newSession.token));
            expect(await pair.recipientRow(), isNull);
            expect(
                await pair.recipientStore.loadMessages('conv'), hasLength(2));
          }),
      skip: skip);

  test(
      'a link ID that could name another path is refused before any file',
      () => _withPair((pair) async {
            for (final bad in ['../x', 'a/b', r'a\b', '.', 'C:x', '']) {
              expect(() => k2DownloadFileName(bad),
                  throwsA(isA<K2TransferException>()),
                  reason: bad);
              await expectLater(
                  pair.source.k2SourcePrepare(K2TransferId(_origin, bad),
                      cacheDirectory: pair.cacheDir),
                  throwsA(isA<K2TransferException>()),
                  reason: bad);
              await expectLater(
                  pair.recipient.k2ReceiveHandoff(K2TransferId(_origin, bad),
                      handoff: const [1],
                      transferId: 'a' * 64,
                      ciphertextSha256: List<int>.filled(32, 1),
                      ciphertextSize: 1,
                      downloadPath: '${pair.downloadDir}/x'),
                  throwsA(isA<K2TransferException>()),
                  reason: bad);
            }
            expect(k2DownloadFileName('link_1-A'), 'k2-link_1-A.download');
            expect(Directory(pair.cacheDir).existsSync(), isFalse);
          }),
      skip: skip);

  test(
      'only a digest failure answers false; other failures keep the file',
      () => _withPair((pair) async {
            await pair.send();
            pair.transport.stopAfterDownload = true;
            await expectLater(pair.receive(), throwsA(isA<SocketException>()));
            final row = (await pair.recipientRow())!;
            expect(row.stage, HistoryTransferStage.downloading);
            final file = File(row.filePath!);
            expect(file.existsSync(), isTrue);
            expect(await pair.recipient.k2VerifyDownload(pair.id), isTrue);

            // A flipped byte fails native authentication: false.
            final bytes = file.readAsBytesSync();
            bytes[bytes.length ~/ 2] ^= 1;
            file.writeAsBytesSync(bytes);
            expect(await pair.recipient.k2VerifyDownload(pair.id), isFalse);

            // A missing file says nothing about the bytes: it throws.
            file.deleteSync();
            await expectLater(pair.recipient.k2VerifyDownload(pair.id),
                throwsA(isA<K2TransferException>()));
            // So does a transfer with no record.
            await expectLater(
                pair.recipient
                    .k2VerifyDownload(const K2TransferId(_origin, 'link_2')),
                throwsA(isA<K2TransferException>()));
          }),
      skip: skip);

  test(
      'orphan source copies are swept; a copy a row names never is',
      () => _withPair((pair) async {
            final sent = await pair.send();
            final kept = File(sent.filePath!);
            final cache = Directory(pair.cacheDir);
            final orphan = File('${cache.path}/k2-source-${'e' * 64}.bin')
              ..writeAsBytesSync([1, 2, 3]);
            final orphanPart =
                File('${cache.path}/k2-source-${'f' * 64}.bin.part')
                  ..writeAsBytesSync([4]);
            final other = File('${cache.path}/notes.txt')
              ..writeAsStringSync('x');
            expect(await pair.source.k2SweepOrphanCaches(pair.cacheDir), 2);
            expect(orphan.existsSync(), isFalse);
            expect(orphanPart.existsSync(), isFalse);
            expect(kept.existsSync(), isTrue);
            expect(other.existsSync(), isTrue);
            expect(await pair.source.k2SweepOrphanCaches(pair.cacheDir), 0);
            expect(
                await pair.source
                    .k2SweepOrphanCaches('${pair.dir.path}/nowhere'),
                0);
            // The transfer still completes from its stored copy.
            expect((await pair.receive()).stage,
                HistoryTransferStage.acknowledged);
            expect(
                (await pair.send()).stage, HistoryTransferStage.acknowledged);
          }),
      skip: skip);

  test(
      'a confirm retry cannot replace the claim digest the row stored',
      () => _withPair((pair) async {
            await expectLater(
                pair.source.k2SourceConfirm(pair.id, '00000000',
                    recipientDeviceId: _newDevice, claimRequestHash: 'd' * 64),
                throwsA(isA<K2TransferException>()));
            final row = (await pair.sourceRow())!;
            expect(row.stage, HistoryTransferStage.approving);
            expect(
                jsonDecode(row.payloadJson)['claim_request_hash'], _claimHash);
            expect((await pair.send()).stage, HistoryTransferStage.uploaded);
          }),
      skip: skip);
}
