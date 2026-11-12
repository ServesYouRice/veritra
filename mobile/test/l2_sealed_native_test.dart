import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'native_test_env.dart';

Uint8List _hex(String text) => Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// L2-3 sealed sender (crypto ABI 26, D123) on the real core: the token
/// exchange of testing/vectors/l2-sealed-v1.json (which Rust and Go check
/// too). The franking designation has its own vector and test
/// (l2_frank_dv_native_test.dart).
void main() {
  final vector = jsonDecode(
    File('../testing/vectors/l2-sealed-v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final skip = nativeCryptoSkip();

  group('L2 sealed sender (native)', () {
    late NativeCryptoBindings bindings;
    setUp(
      () => bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary()),
    );

    test('finalizing the vector exchange gives its tokens', () {
      final exchange = vector['exchange'] as Map<String, dynamic>;
      final tokens = bindings.l2TokenFinalize(
        state: _hex(exchange['state'] as String),
        response: _hex(exchange['response'] as String),
      );
      expect(_toHex(tokens), exchange['tokens']);
      // A flipped proof bit yields no token.
      final bad = _hex(exchange['response'] as String);
      bad[bad.length - 10] ^= 1;
      expect(
        () => bindings.l2TokenFinalize(
          state: _hex(exchange['state'] as String),
          response: bad,
        ),
        throwsA(isA<NativeCryptoException>()),
      );
    }, skip: skip);

    test('a request carries fresh blinds and names the pinned key', () {
      final key = _hex(vector['public_key'] as String);
      final info = vector['info_case'] as Map<String, dynamic>;
      final first = bindings.l2TokenRequest(
        publicKey: key,
        conversationId: info['conversation_id'] as String,
        epoch: info['epoch'] as int,
        count: 3,
      );
      final second = bindings.l2TokenRequest(
        publicKey: key,
        conversationId: info['conversation_id'] as String,
        epoch: info['epoch'] as int,
        count: 3,
      );
      expect(first.request.length, 3 * 32);
      expect(first.request, isNot(second.request));
      // VLT1 || count || key || u16 len(info) || info || 3 × (nonce || state)
      expect(utf8.decode(first.state.sublist(0, 4)), 'VLT1');
      expect(first.state[4], 3);
      expect(first.state.sublist(5, 37), key);
      final infoBytes = _hex(info['info'] as String);
      expect(first.state.sublist(39, 39 + infoBytes.length), infoBytes);
      expect(
        () => bindings.l2TokenRequest(
          publicKey: Uint8List(32),
          conversationId: 'c',
          epoch: 1,
          count: 1,
        ),
        throwsA(isA<NativeCryptoException>()),
      );
      expect(
        () => bindings.l2TokenRequest(
          publicKey: key,
          conversationId: 'c',
          epoch: 1,
          count: 33,
        ),
        throwsArgumentError,
      );
    }, skip: skip);
  });
}
