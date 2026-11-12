import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/reports_service.dart'
    show designationNames, frankDesignationKid;
import 'package:private_messenger/crypto/franking.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'native_test_env.dart';

Uint8List _hex(String text) => Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// L2-3 designated-verifier franking (crypto ABI 26) through the native
/// calls the app uses: testing/vectors/l2-frank-dv-v1.json (which Rust and
/// the Go cross-check read too) gives every verdict, the Dart key id matches
/// the vector's, and a real device designates to owner keys that only those
/// owners' seeds verify.
void main() {
  final vector = jsonDecode(
    File('../testing/vectors/l2-frank-dv-v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final skip = nativeCryptoSkip();
  final owners = (vector['owners'] as List).cast<Map<String, dynamic>>();
  final refusedKeys = <String>{
    for (final k in (vector['refused_public_keys'] as List))
      (k as Map<String, dynamic>)['key'] as String,
  };

  test('the Dart key id is the vector key id', () {
    for (final owner in owners) {
      expect(_toHex(frankDesignationKid(_hex(owner['report_public']))),
          owner['kid']);
    }
    for (final designation
        in (vector['designations'] as List).cast<Map<String, dynamic>>()) {
      final d = _hex(designation['d'] as String);
      expect(designationWellFormed(d), isTrue);
      // Every usable owner key is named; a refused one is skipped.
      for (final key in (designation['owner_public_keys'] as List)) {
        final refused = refusedKeys.contains(key);
        expect(designationNames(d, frankDesignationKid(_hex(key as String))),
            !refused,
            reason: '${designation['name']}: $key');
      }
    }
  });

  group('L2 designated franking (native)', () {
    late NativeCryptoBindings bindings;
    setUp(
      () => bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary()),
    );

    test('every vector verify case gives its verdict', () {
      final cases =
          (vector['verify_cases'] as List).cast<Map<String, dynamic>>();
      expect(cases.length, greaterThanOrEqualTo(11));
      for (final item in cases) {
        expect(
          bindings.l2FrankDvVerify(
            seed: _hex(item['report_seed'] as String),
            senderFrankKey: _hex(item['sender_frank_public'] as String),
            conversationId: item['conversation_id'] as String,
            accountId: item['account_id'] as String,
            deviceId: item['device_id'] as String,
            commit: _hex(item['commit'] as String),
            designation: _hex(item['d'] as String),
          ),
          item['result'],
          reason: item['name'] as String,
        );
      }
    }, skip: skip);

    test('a device designates with its own key to the given owners only', () {
      final device = bindings.createDevice('acct_dv_dart', 'dev_dv_dart');
      final own = device.l2FrankPublicKey();
      expect(own, hasLength(32));
      final commit = Uint8List.fromList(List<int>.filled(32, 0x5a));
      final keys = [for (final o in owners.take(2)) _hex(o['report_public'])];
      final d = device.l2FrankDesignate(
        conversationId: 'conv_dv_dart',
        commit: commit,
        listedKey: own,
        ownerKeys: keys,
      );
      expect(d, hasLength(96));
      expect(designationWellFormed(d), isTrue);
      int verdict(Map<String, dynamic> owner, {List<int>? designation}) =>
          bindings.l2FrankDvVerify(
            seed: _hex(owner['report_seed'] as String),
            senderFrankKey: own,
            conversationId: 'conv_dv_dart',
            accountId: 'acct_dv_dart',
            deviceId: 'dev_dv_dart',
            commit: commit,
            designation: designation ?? d,
          );
      expect(verdict(owners[0]), 1);
      expect(verdict(owners[1]), 1);
      // The third owner was not designated.
      expect(verdict(owners[2]), 2);
      // A flipped tag bit fails for its owner.
      final bent = Uint8List.fromList(d)..[20] ^= 1;
      final first = d.sublist(0, 16);
      final bentOwner = owners.firstWhere((o) =>
          _toHex(frankDesignationKid(_hex(o['report_public']))) ==
          _toHex(first));
      expect(verdict(bentOwner, designation: bent), 0);
      // A key other than the listed one is refused; a refused owner key is
      // skipped, and only refused keys give the plain form (empty).
      final wrong = Uint8List.fromList(own)..[0] ^= 1;
      expect(
          () => device.l2FrankDesignate(
              conversationId: 'conv_dv_dart',
              commit: commit,
              listedKey: wrong,
              ownerKeys: keys),
          throwsA(isA<NativeCryptoException>()));
      final refused = (vector['refused_public_keys'] as List)
          .map((k) => _hex((k as Map<String, dynamic>)['key'] as String))
          .toList();
      expect(
          device.l2FrankDesignate(
              conversationId: 'conv_dv_dart',
              commit: commit,
              listedKey: own,
              ownerKeys: refused.take(16).toList()),
          isEmpty);
    }, skip: skip);
  });
}
