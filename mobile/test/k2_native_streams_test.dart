import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'native_state_round_trip.dart';

class _Linked {
  _Linked(String path) {
    bindings = NativeCryptoBindings.open(path);
    source = bindings.createDevice('account', 'source');
    recipient = bindings.createDevice('account', 'recipient');
    K2LinkContext context(List<int> key) => K2LinkContext(
        id: id,
        accountId: 'account',
        nonce: List.filled(32, 9),
        sourceDeviceId: 'source',
        sourceSigningKey: source.signingPublicKey(),
        recipientDeviceId: 'recipient',
        recipientSigningKey: recipient.signingPublicKey(),
        transferPublicKey: key);
    final secret = List.filled(16, 8);
    final received = recipient.k2ReceiveBegin(
        context(List.filled(32, 0)), secret,
        originalExpiresAt: 1000, now: 100);
    final checked = source.k2SourceAccept(
        context(received.transferPublicKey), secret,
        originalExpiresAt: 1000,
        now: 100,
        transcriptHash: received.verification.transcriptHash,
        claimTag: received.verification.claimTag);
    source.k2SourceConfirm(id, checked.sas, now: 100);
    final tag = source.k2SourceApprovalRequest(id, now: 100).approvalTag;
    source.k2ApplyApproval(id, tag, approvedAt: 100, now: 100);
    recipient.k2ApplyApproval(id, tag, approvedAt: 100, now: 100);
  }
  late final NativeCryptoBindings bindings;
  late final NativeCryptoDevice source;
  late NativeCryptoDevice recipient;
  final id = const K2TransferId('https://example.test', 'link');
  K2HistoryStream begin(int length) => source.k2SourceBegin(id,
      now: 100,
      createdAt: 100,
      snapshotCounter: 31,
      plaintextVersion: 4,
      payloadLength: length);
  void close() {
    source.close();
    recipient.close();
  }
}

void main() {
  test('malformed owned native read frames are wiped before decoder throws',
      () {
    Uint8List valid() => Uint8List.fromList([
          80,
          75,
          50,
          82,
          1,
          0,
          25,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          1,
          1,
          0,
          0,
          0,
          1,
          0xa5,
        ]);
    final malformed = <Uint8List>[
      valid()..[0] = 0,
      valid()..[4] = 2,
      valid()..[6] = 24,
      Uint8List.fromList([0xa5, 0x5a]),
      Uint8List(1024 * 1024 + 33)..fillRange(0, 1024 * 1024 + 33, 0xa5),
      valid()..[19] = 2,
    ];
    for (final frame in malformed) {
      expect(() => K2StreamChunk.fromOwnedNativeFrame(frame, offset: 0),
          throwsA(isA<NativeCryptoException>()));
      expect(frame.every((value) => value == 0), isTrue);
    }
    final frame = valid();
    final chunk = K2StreamChunk.fromOwnedNativeFrame(frame, offset: 0);
    expect(chunk.bytes, [0xa5]);
    chunk.bytes.fillRange(0, chunk.bytes.length, 0);
    expect(frame.last, 0);
  });
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final skip = libraryPath == null ? 'host native library not built' : false;
  test('ABI8 verified bundle streams retain import capability through restart',
      () {
    final linked = _Linked(libraryPath!);
    final payload =
        Uint8List.fromList(List.generate(1024 * 1024 + 37, (i) => i % 251));
    K2HistoryStream? source, receiver;
    try {
      source = linked.begin(payload.length);
      expect(() => linked.begin(0), throwsA(isA<NativeCryptoException>()));
      expect(() => source!.read(0), throwsA(isA<NativeCryptoException>()));
      expect(
          () => source!.write(1, [1]), throwsA(isA<NativeCryptoException>()));
      source.write(0, Uint8List.sublistView(payload, 0, 1024 * 1024));
      source.write(1024 * 1024, Uint8List.sublistView(payload, 1024 * 1024));
      final metadata = source.sourceFinish(now: 100);
      expect(metadata.transferId, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(() => linked.source.k2Forget(linked.id),
          throwsA(isA<NativeCryptoException>()));
      final ciphertext = BytesBuilder(copy: false);
      var offset = 0;
      while (true) {
        final chunk = source.read(offset);
        ciphertext.add(chunk.bytes);
        offset = chunk.nextOffset;
        if (chunk.eof) break;
      }
      expect(offset, metadata.ciphertextSize);
      source.close();
      source = null;
      expect(() => linked.begin(0), throwsA(isA<NativeCryptoException>()));
      final incoming = linked.recipient.k2ReceiveBeginBundle(
          linked.id, metadata.handoff,
          now: 100, plaintextVersion: 4);
      receiver = incoming.stream;
      expect(incoming.transferId, metadata.transferId);
      expect(incoming.ciphertextHash, metadata.ciphertextHash);
      expect(incoming.headerHash, metadata.headerHash);
      expect(() => receiver!.read(0), throwsA(isA<NativeCryptoException>()));
      expect(() => linked.recipient.k2Importing(linked.id, now: 100),
          throwsA(isA<NativeCryptoException>()));
      final encrypted = ciphertext.takeBytes();
      offset = 0;
      while (offset < encrypted.length) {
        final end = (offset + 1024 * 1024).clamp(0, encrypted.length);
        offset = receiver.write(
            offset, Uint8List.sublistView(encrypted, offset, end));
      }
      final opened = receiver.receiveFinish(now: 100);
      expect(opened.payloadLength, payload.length);
      expect(opened.snapshotCounter, 31);
      expect(opened.plaintextVersion, 4);
      expect(opened.createdAt, 100);
      linked.recipient.k2Importing(linked.id, now: 100);
      linked.recipient.k2Importing(linked.id, now: 100);
      expect(linked.recipient.k2Inspect(linked.id, now: 100).stage,
          K2Stage.importing);
      final recovered = BytesBuilder(copy: false);
      offset = 0;
      while (true) {
        final chunk = receiver.read(offset);
        recovered.add(chunk.bytes);
        offset = chunk.nextOffset;
        if (chunk.eof) break;
      }
      expect(recovered.takeBytes(), payload);
      receiver.close();
      receiver = null;
      final key = List.filled(32, 7);
      linked.recipient = reopenFreshDevice(
          linked.bindings, linked.recipient, 'account', 'recipient',
          stateKey: key, generation: 1);
      receiver = linked.recipient
          .k2ReceiveBeginBundle(linked.id, metadata.handoff,
              now: 100, plaintextVersion: 4)
          .stream;
      expect(linked.recipient.k2Inspect(linked.id, now: 100).stage,
          K2Stage.importing);
      offset = 0;
      while (offset < encrypted.length) {
        final end = (offset + 1024 * 1024).clamp(0, encrypted.length);
        offset = receiver.write(
            offset, Uint8List.sublistView(encrypted, offset, end));
      }
      receiver.receiveFinish(now: 100);
      expect(receiver.read(0, maximum: 37).bytes,
          Uint8List.sublistView(payload, 0, 37));
    } finally {
      source?.close();
      receiver?.close();
      linked.close();
      payload.fillRange(0, payload.length, 0);
    }
  }, skip: skip);

  test('ABI8 tampering never returns plaintext and device close releases lease',
      () {
    final linked = _Linked(libraryPath!);
    K2HistoryStream? source, receiver;
    try {
      source = linked.begin(3);
      source.write(0, [1, 2, 3]);
      final metadata = source.sourceFinish(now: 100);
      final encrypted = source.read(0).bytes;
      source.close();
      source = null;
      receiver = linked.recipient
          .k2ReceiveBeginBundle(linked.id, metadata.handoff,
              now: 100, plaintextVersion: 4)
          .stream;
      encrypted[encrypted.length - 1] ^= 1;
      receiver.write(0, encrypted);
      expect(() => receiver!.receiveFinish(now: 100),
          throwsA(isA<NativeCryptoException>()));
      expect(() => receiver!.read(0), throwsA(isA<NativeCryptoException>()));
      linked.recipient.close();
      expect(
          () => receiver!.write(0, [1]), throwsA(isA<NativeCryptoException>()));
      // A stream pointer can still be destroyed exactly once after its owner.
      receiver.close();
      receiver.close();
      receiver = null;
      final another = _Linked(libraryPath);
      try {
        source = another.begin(0);
        source.sourceFinish(now: 100);
        expect(source.read(0).eof, isTrue);
      } finally {
        source?.close();
        source = null;
        another.close();
      }
      expect(
          () => linked.source.k2SourceBegin(linked.id,
              now: 100,
              createdAt: 100,
              snapshotCounter: 31,
              plaintextVersion: 4,
              payloadLength: 64 * 1024 * 1024 - 7),
          throwsA(isA<NativeCryptoException>()));
    } finally {
      source?.close();
      receiver?.close();
      linked.close();
    }
  }, skip: skip);
}
