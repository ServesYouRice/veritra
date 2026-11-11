import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/encrypted_database.dart'
    show LocalMessage;
import 'package:private_messenger/storage/history_snapshot.dart';

import 'native_test_env.dart';

/// K1 (ABI 16): the Dart bindings for the VHC1 kind-1 backup container
/// against testing/vectors/k1-backup-v1.json, which the Rust core checks in
/// full.
void main() {
  group('K1 backup container (native)', () {
    late NativeCryptoBindings bindings;
    late Map<String, dynamic> vector;

    Uint8List hex(Object? value) {
      final text = value as String;
      return Uint8List.fromList([
        for (var i = 0; i < text.length; i += 2)
          int.parse(text.substring(i, i + 2), radix: 16),
      ]);
    }

    setUp(() {
      bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
      // A missing vector fails the test; it never skips.
      vector = jsonDecode(
              File('../testing/vectors/k1-backup-v1.json').readAsStringSync())
          as Map<String, dynamic>;
    });

    test('the pinned header reads back to its fields', () {
      final info = bindings.peekBackup(hex(vector['header_hex']));
      expect(info.accountId, vector['account_id']);
      expect(info.sourceDeviceId, vector['source_device_id']);
      expect(info.createdAtMs, vector['created_at_ms']);
      expect(info.counter, vector['counter']);
      expect(info.plaintextVersion, vector['plaintext_version']);
      expect(info.paddedSize, vector['padded_size']);
      expect(info.rkId, hex(vector['rk_id_hex']));
    });

    test('seal then open round trips with the vector key and rejects the rest',
        () {
      final entropy = hex(vector['recovery_key_entropy_hex']);
      final rk = bindings.deriveRecoveryKey(entropy);
      expect(rk.rkPub, hex(vector['rk_pub_hex']));
      final plaintext = Uint8List.fromList(utf8.encode('{"synthetic":true}'));
      final sealed = bindings.sealBackup(
        accountId: 'acct_1',
        sourceDeviceId: 'dev_a',
        createdAtMs: 1730000000000,
        counter: 3,
        plaintextVersion: 6,
        rkPub: rk.rkPub,
        plaintext: plaintext,
      );
      // Padded to the floor, so the size says little about the history.
      expect(sealed.length, greaterThan(1024 * 1024));
      final peek = bindings.peekBackup(Uint8List.sublistView(
          sealed, 0, NativeCryptoBindings.backupPeekBytes));
      expect(peek.counter, 3);
      expect(peek.rkId, rk.rkId);

      final opened = bindings.openBackup(
          ciphertext: sealed,
          entropy: entropy,
          accountId: 'acct_1',
          sourceDeviceId: 'dev_a');
      expect(opened.plaintext, plaintext);
      expect(opened.header.sourceDeviceId, 'dev_a');
      expect(opened.header.counter, 3);

      // A file restore does not pin the device and learns it from the header.
      final fromFile = bindings.openBackup(
          ciphertext: sealed, entropy: entropy, accountId: 'acct_1');
      expect(fromFile.header.sourceDeviceId, 'dev_a');

      final wrongKey = Uint8List.fromList(entropy)..[0] ^= 1;
      for (final attempt in <Uint8List Function()>[
        () => bindings
            .openBackup(
                ciphertext: sealed, entropy: wrongKey, accountId: 'acct_1')
            .plaintext,
        () => bindings
            .openBackup(
                ciphertext: sealed, entropy: entropy, accountId: 'acct_2')
            .plaintext,
        () => bindings
            .openBackup(
                ciphertext: sealed,
                entropy: entropy,
                accountId: 'acct_1',
                sourceDeviceId: 'dev_b')
            .plaintext,
        () {
          final changed = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1;
          return bindings
              .openBackup(
                  ciphertext: changed, entropy: entropy, accountId: 'acct_1')
              .plaintext;
        },
      ]) {
        expect(attempt, throwsA(isA<NativeCryptoException>()));
      }
    });

    test('a history snapshot survives seal and open for the K1-4 import', () {
      final entropy = hex(vector['recovery_key_entropy_hex']);
      final rk = bindings.deriveRecoveryKey(entropy);
      final snapshot = HistorySnapshot(
          accountId: 'acct_1',
          sourceDeviceId: 'dev_a',
          counter: 4,
          createdAt: 1730000000000,
          conversations: const [HistoryConversation('conv', 'dm')],
          messages: [
            LocalMessage(
                key: 'dev_a:1',
                conversationId: 'conv',
                senderAccountId: 'bob',
                senderDeviceId: 'dev_a',
                kind: 'text',
                body: 'hi',
                createdAt: 1729999999000,
                state: 'received',
                senderHidden: false)
          ],
          reactions: const [],
          pins: const [],
          starred: const {},
          preferences: const []);
      final sealed = bindings.sealBackup(
        accountId: 'acct_1',
        sourceDeviceId: 'dev_a',
        createdAtMs: 1730000001000,
        counter: 9,
        plaintextVersion: 1,
        rkPub: rk.rkPub,
        plaintext: Uint8List.fromList(snapshot.encode()),
      );
      final opened = bindings.openBackup(
          ciphertext: sealed,
          entropy: entropy,
          accountId: 'acct_1',
          sourceDeviceId: 'dev_a');
      final back = HistorySnapshot.decode(opened.plaintext);
      expect(back.messages.single.body, 'hi');
      expect(back.accountId, opened.header.accountId);
      expect(back.sourceDeviceId, opened.header.sourceDeviceId);
      // The seal's counter and time are the container's; the snapshot keeps
      // its own, so the restore builds the importer context from it.
      expect(opened.header.counter, 9);
      expect(back.counter, 4);
    });

    test('the padded size is the attachment bucket, floored at 1 MiB', () {
      final entropy = hex(vector['recovery_key_entropy_hex']);
      final rk = bindings.deriveRecoveryKey(entropy);
      for (final length in [1, 900000, 1048568, 3145733]) {
        final sealed = bindings.sealBackup(
          accountId: 'acct_1',
          sourceDeviceId: 'dev_a',
          createdAtMs: 1730000000000,
          counter: 1,
          plaintextVersion: 6,
          rkPub: rk.rkPub,
          plaintext: Uint8List(length)..fillRange(0, length, 7),
        );
        final padded = bindings
            .peekBackup(Uint8List.sublistView(
                sealed, 0, NativeCryptoBindings.backupPeekBytes))
            .paddedSize;
        // Dart's bucket (the same function attachments use), floored at
        // 1 MiB and rounded up to the 64 KiB frame, must equal Rust's.
        final bucket =
            paddedAttachmentSize(length + 8, limit: 64 * 1024 * 1024);
        final expected =
            ((bucket < 1048576 ? 1048576 : bucket) + 65535) ~/ 65536 * 65536;
        expect(padded, expected, reason: 'payload $length');
      }
    });

    test('bad arguments are refused before the library is called', () {
      final entropy = hex(vector['recovery_key_entropy_hex']);
      final rk = bindings.deriveRecoveryKey(entropy);
      Uint8List seal({int counter = 1, Uint8List? plaintext, Uint8List? pub}) =>
          bindings.sealBackup(
            accountId: 'acct_1',
            sourceDeviceId: 'dev_a',
            createdAtMs: 1730000000000,
            counter: counter,
            plaintextVersion: 6,
            rkPub: pub ?? rk.rkPub,
            plaintext: plaintext ?? Uint8List(4),
          );
      expect(() => seal(counter: 0), throwsArgumentError);
      expect(() => seal(plaintext: Uint8List(0)), throwsArgumentError);
      expect(() => seal(pub: Uint8List(31)), throwsArgumentError);
    });
  }, skip: nativeCryptoSkip());
}
