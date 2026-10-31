import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

void main() {
  final configured = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  // An empty value counts as missing, so it never reaches the loader.
  final libraryPath =
      configured == null || configured.isEmpty ? null : configured;
  if (libraryPath == null && Platform.environment['CI'] == 'true') {
    test('CI provides the native crypto library', () {
      fail('VERITRA_CRYPTO_LIBRARY is required when CI=true: set it to a '
          'built libprivate_messenger_crypto');
    });
  }
  test('ABI v9 lifecycle owns outputs and handles safely', () {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = bindings.createDevice('acct_alice', 'dev_alice');
    final bob = bindings.createDevice('acct_bob', 'dev_bob');
    expect(alice.signingPublicKey(), hasLength(32));
    expect(alice.signingPublicKey(), hasLength(32));
    final enrollment = alice.createEnrollmentCredential([7, 8, 9]);
    expect(enrollment.signingKey, hasLength(32));
    final linked = bindings.createDevice('acct_alice', 'dev_linked');
    final nonce = List<int>.filled(32, 0x42);
    final existingVerification = alice.deriveDeviceLinkVerification(
      protocolVersion: 'veritra-device-link-v2',
      serverOrigin: 'https://example.test',
      linkId: 'link_01',
      linkSecret: List<int>.filled(16, 0x55),
      peerDeviceId: 'dev_linked',
      peerSigningKey: linked.signingPublicKey(),
      linkNonce: nonce,
      localIsExistingDevice: true,
    );
    final linkedVerification = linked.deriveDeviceLinkVerification(
      protocolVersion: 'veritra-device-link-v2',
      serverOrigin: 'https://example.test',
      linkId: 'link_01',
      linkSecret: List<int>.filled(16, 0x55),
      peerDeviceId: 'dev_alice',
      peerSigningKey: alice.signingPublicKey(),
      linkNonce: nonce,
      localIsExistingDevice: false,
    );
    expect(
        linkedVerification.transcriptHash, existingVerification.transcriptHash);
    expect(linkedVerification.sas, existingVerification.sas);
    expect(linkedVerification.claimTag, existingVerification.claimTag);
    expect(linkedVerification.approvalTag, existingVerification.approvalTag);
    expect(linkedVerification.claimTag, isNot(linkedVerification.approvalTag));
    final substitutedKey = linked.signingPublicKey();
    substitutedKey[0] ^= 1;
    expect(
      alice
          .deriveDeviceLinkVerification(
            protocolVersion: 'veritra-device-link-v2',
            serverOrigin: 'https://example.test',
            linkId: 'link_01',
            linkSecret: List<int>.filled(16, 0x55),
            peerDeviceId: 'dev_linked',
            peerSigningKey: substitutedKey,
            linkNonce: nonce,
            localIsExistingDevice: true,
          )
          .sas,
      isNot(existingVerification.sas),
    );
    linked.close();
    final bobPackage = bob.createKeyPackage();
    alice.createGroup('conv_test');
    final added =
        alice.addMember('conv_test', bobPackage, 'acct_bob', 'dev_bob');
    bob.joinGroup('conv_test', added.welcome);
    final ciphertext = alice.encrypt('conv_test', [4, 5, 6]);
    expect(
        bob.decrypt('conv_test', ciphertext,
            senderAccountId: 'acct_alice', senderDeviceId: 'dev_alice'),
        [4, 5, 6]);
    final spoofed = alice.encrypt('conv_test', [7]);
    expect(
        () => bob.decrypt('conv_test', spoofed,
            senderAccountId: 'acct_mallory', senderDeviceId: 'dev_mallory'),
        throwsA(isA<NativeCryptoException>().having(
            (error) => error.kind, 'kind', NativeCryptoError.senderMismatch)));
    // A self-update is staged and merged only once accepted (D28).
    final before = alice.groupEpoch('conv_test');
    final update = alice.stageSelfUpdate('conv_test');
    expect(update.welcome, isEmpty);
    expect(update.epoch, before.epoch);
    expect(alice.groupEpoch('conv_test'), (epoch: before.epoch, pending: true));
    alice.mergePendingCommit('conv_test');
    bob.processCommit('conv_test', update.commit);
    expect(
        bob.groupEpoch('conv_test'), (epoch: before.epoch + 1, pending: false));
    // Both sides now share the new epoch's keys, so a message round-trips.
    final afterUpdate = alice.encrypt('conv_test', [8, 9]);
    expect(
        bob.decrypt('conv_test', afterUpdate,
            senderAccountId: 'acct_alice', senderDeviceId: 'dev_alice'),
        [8, 9]);
    final removal = alice.removeMember('conv_test', 'acct_bob', 'dev_bob');
    expect(alice.groupEpoch('conv_test'),
        (epoch: before.epoch + 2, pending: false));
    bob.processCommit('conv_test', removal);
    expect(() => bob.encrypt('conv_test', [1]),
        throwsA(isA<NativeCryptoException>()));
    // A removed member cannot read what the group sends after the removal.
    final afterRemoval = alice.encrypt('conv_test', [10, 11]);
    expect(
        () => bob.decrypt('conv_test', afterRemoval,
            senderAccountId: 'acct_alice', senderDeviceId: 'dev_alice'),
        throwsA(isA<NativeCryptoException>()));

    final key = List<int>.filled(32, 9);
    final sealed = alice.sealChanges(key, 1);
    final records = [
      for (final change in sealed.changes)
        if (change.sealed != null) change.sealed!,
    ];
    alice.close();
    alice.close();
    final restored = bindings.restoreRecords(
        'acct_alice', 'dev_alice', key, 1, sealed.root, records);
    expect(restored.generation, 1);
    final oldFormat = List<int>.of(sealed.root)
      ..setRange(8, 10, const [0, 1]);
    expect(
        () => bindings.restoreRecords(
            'acct_alice', 'dev_alice', key, 1, oldFormat, records),
        throwsA(isA<NativeCryptoException>().having((error) => error.kind,
            'kind', NativeCryptoError.stateFormatUnsupported)));
    final tampered = List<int>.of(sealed.root)
      ..[sealed.root.length - 1] ^= 1;
    expect(
        () => bindings.restoreRecords(
            'acct_alice', 'dev_alice', key, 1, tampered, records),
        throwsA(isA<NativeCryptoException>().having(
            (error) => error.kind, 'kind', NativeCryptoError.operationFailed)));
    expect(() => restored.device.encrypt('conv_test', const []),
        throwsArgumentError);
    restored.device.close();
    bob.close();
  }, skip: libraryPath == null ? 'host native library not built' : false);

  test('a past-epoch message from a removed device is senderRemoved', () {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = bindings.createDevice('acct_alice', 'dev_alice');
    final bob = bindings.createDevice('acct_bob', 'dev_bob');
    final carol = bindings.createDevice('acct_carol', 'dev_carol');
    alice.createGroup('conv_removed');
    final added = alice.stageCommit('conv_removed', adds: [
      (
        keyPackage: bob.createKeyPackage(),
        accountId: 'acct_bob',
        deviceId: 'dev_bob'
      ),
      (
        keyPackage: carol.createKeyPackage(),
        accountId: 'acct_carol',
        deviceId: 'dev_carol'
      ),
    ]);
    alice.mergePendingCommit('conv_removed');
    bob.joinGroup('conv_removed', added.welcome);
    carol.joinGroup('conv_removed', added.welcome);
    final removal = alice.stageCommit('conv_removed',
        removes: [(accountId: 'acct_bob', deviceId: 'dev_bob')]);
    alice.mergePendingCommit('conv_removed');
    carol.processCommit('conv_removed', removal.commit);
    // Bob never applies his removal and writes in the old epoch.
    final injected = bob.encrypt('conv_removed', [1, 2, 3]);
    expect(
        () => carol.decrypt('conv_removed', injected,
            senderAccountId: 'acct_bob', senderDeviceId: 'dev_bob'),
        throwsA(isA<NativeCryptoException>().having(
            (error) => error.kind, 'kind', NativeCryptoError.senderRemoved)));
    // The service commits the ratchet and keeps a warning for both.
    expect(NativeCryptoError.senderRemoved.ratchetAdvanced, isTrue);
    expect(NativeCryptoError.senderMismatch.ratchetAdvanced, isTrue);
    expect(NativeCryptoError.operationFailed.ratchetAdvanced, isFalse);
    alice.close();
    bob.close();
    carol.close();
  }, skip: libraryPath == null ? 'host native library not built' : false);

  test('every owned buffer is freed exactly once when the copy fails', () {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = bindings.createDevice('acct_alice', 'dev_alice');
    final bob = bindings.createDevice('acct_bob', 'dev_bob');
    alice.createGroup('conv_free');
    final freed = <int>[];
    var copies = 0;
    var failAt = 0;
    void failingCopy(int copy, void Function() operation) {
      freed.clear();
      copies = 0;
      failAt = copy;
      expect(operation, throwsA(isA<StateError>()));
    }

    final originalCopy = NativeCryptoBindings.debugCopyOwnedBytes;
    NativeCryptoBindings.debugFreeOwnedBuffer =
        (Pointer<Uint8> data, int len) => freed.add(data.address);
    NativeCryptoBindings.debugCopyOwnedBytes = (Pointer<Uint8> data, int len) {
      if (++copies == failAt) throw StateError('copy failed');
      return List<int>.of(data.asTypedList(len));
    };
    try {
      // _output: one buffer.
      failingCopy(1, alice.signingPublicKey);
      expect(freed, hasLength(1));
      // _twoOutputs: the copy fails on the first and on the second buffer.
      for (final copy in [1, 2]) {
        failingCopy(copy, () => alice.conversationSafetyNumber('conv_free'));
        expect(freed, hasLength(2), reason: 'copy $copy');
        expect(freed.toSet(), hasLength(2), reason: 'copy $copy');
      }
      // Three outputs, taken one by one.
      for (final copy in [1, 2, 3]) {
        failingCopy(copy, () => alice.createEnrollmentCredential([1, 2, 3]));
        expect(freed, hasLength(3), reason: 'copy $copy');
        expect(freed.toSet(), hasLength(3), reason: 'copy $copy');
      }
      // stageCommit's commit and Welcome.
      final keyPackage = bob.createKeyPackage();
      for (final copy in [1, 2]) {
        failingCopy(
            copy,
            () => alice.stageCommit('conv_free', adds: [
                  (
                    keyPackage: keyPackage,
                    accountId: 'acct_bob',
                    deviceId: 'dev_bob'
                  )
                ]));
        expect(freed, hasLength(2), reason: 'copy $copy');
        expect(freed.toSet(), hasLength(2), reason: 'copy $copy');
        alice.clearPendingCommit('conv_free');
      }
    } finally {
      NativeCryptoBindings.debugFreeOwnedBuffer = null;
      NativeCryptoBindings.debugCopyOwnedBytes = originalCopy;
    }
    alice.close();
    bob.close();
  }, skip: libraryPath == null ? 'host native library not built' : false);

  test('a plaintext whose ciphertext cannot be sent is refused first', () {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final alice = bindings.createDevice('acct_alice', 'dev_alice');
    alice.createGroup('conv_size');
    final tooLarge = throwsA(isA<NativeCryptoException>().having(
        (error) => error.kind, 'kind', NativeCryptoError.plaintextTooLarge));
    // 800 KiB encrypts to more than the 1 MiB JSON route can carry in
    // base64, so it must be refused before encrypting.
    expect(() => alice.encrypt('conv_size', List<int>.filled(800 * 1024, 7)),
        tooLarge);
    expect(
        () => alice.encrypt(
            'conv_size', List<int>.filled(maxSendablePlaintextBytes + 1, 7)),
        tooLarge);
    final epoch = alice.groupEpoch('conv_size');
    // The largest accepted plaintext fits a full message request.
    final ciphertext = alice.encrypt(
        'conv_size', List<int>.filled(maxSendablePlaintextBytes, 7));
    expect(ciphertext.length - maxSendablePlaintextBytes, lessThan(4096));
    final request = jsonEncode(<String, Object?>{
      'conversation_id': 'c' * 128,
      'idempotency_key': 'k' * 128,
      'ciphertext': base64Encode(ciphertext),
      'crypto_protocol': 'mls10-openmls-v1',
      'crypto_metadata': <String, Object?>{
        'protocol_version': 1,
        'epoch': epoch.epoch,
        'note': 'm' * 4096,
      },
      'attachment_refs': List<String>.filled(64, 'a' * 128),
      'reply_to_id': 'r' * 128,
      'thread_root_id': 't' * 128,
      'expires_at': '2026-10-31T00:00:00.000000000Z',
    });
    expect(utf8.encode(request).length, lessThanOrEqualTo(1024 * 1024));
    alice.close();
  }, skip: libraryPath == null ? 'host native library not built' : false);
}
