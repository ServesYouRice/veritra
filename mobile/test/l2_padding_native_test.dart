import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'native_test_env.dart';

/// L2-1 and the L2-3 boundary (crypto ABI 23) on the real MLS core: the size
/// buckets of testing/vectors/l2-padding-v1.json (which Rust and Go check
/// too), padded key packages and Welcomes, and the sealed-sender decrypt
/// that returns the sender MLS authenticated.
void main() {
  final vector = jsonDecode(
    File('../testing/vectors/l2-padding-v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final skip = nativeCryptoSkip();

  group('L2 padding (native)', () {
    late NativeCryptoBindings bindings;
    setUp(() =>
        bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary()));

    test('the bucket rule matches the shared vector', () {
      final cases = vector['buckets'] as List<dynamic>;
      expect(cases.length, greaterThanOrEqualTo(10));
      for (final raw in cases) {
        final item = raw as Map<String, dynamic>;
        expect(bindings.l2PaddedSize(item['length'] as int),
            item['padded'] as int?,
            reason: 'length ${item['length']}');
      }
    }, skip: skip);

    test('key packages and Welcomes leave in buckets and still join', () {
      final alice = bindings.createDevice('acct_l2_alice', 'dev_l2_alice');
      final members = [
        for (var i = 0; i < 6; i++)
          (
            device: bindings.createDevice('acct_l2_$i', 'dev_l2_$i'),
            accountId: 'acct_l2_$i',
            deviceId: 'dev_l2_$i',
          ),
      ];
      const groupId = 'conv_l2_dart';
      alice.createGroup(groupId);
      var joined = 0;
      for (final batch in [1, 2, 3]) {
        final adds = [
          for (final member in members.sublist(joined, joined + batch))
            (
              keyPackage: member.device.createKeyPackage(),
              accountId: member.accountId,
              deviceId: member.deviceId,
            ),
        ];
        for (final add in adds) {
          expect(bindings.l2PaddedSize(add.keyPackage.length),
              add.keyPackage.length);
        }
        final staged = alice.stageCommit(groupId, adds: adds);
        expect(bindings.l2PaddedSize(staged.welcome.length),
            staged.welcome.length);
        alice.mergePendingCommit(groupId);
        for (final member in members.take(joined)) {
          member.device.processCommit(groupId, staged.commit);
        }
        for (final member in members.sublist(joined, joined + batch)) {
          member.device.joinGroup(groupId, staged.welcome);
        }
        joined += batch;
      }

      // Sealed sender boundary: the sender comes from MLS, never from the
      // transport.
      final ciphertext = alice.encrypt(groupId, utf8.encode('hello'));
      final opened = members.last.device.decryptSealed(groupId, ciphertext);
      expect(utf8.decode(opened.plaintext), 'hello');
      expect(opened.accountId, 'acct_l2_alice');
      expect(opened.deviceId, 'dev_l2_alice');
      final fromBob =
          members.first.device.encrypt(groupId, utf8.encode('from bob'));
      final byBob = members[1].device.decryptSealed(groupId, fromBob);
      expect(byBob.accountId, 'acct_l2_0');
      expect(byBob.deviceId, 'dev_l2_0');
    }, skip: skip);
  });
}
