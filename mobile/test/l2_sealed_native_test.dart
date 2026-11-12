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

/// L2-3 sealed sender (crypto ABI 26, D122) on the real core: the token
/// exchange and the franking signature of testing/vectors/l2-sealed-v1.json
/// (which Rust and Go check too), and a sealed message whose signature the
/// receiver checks against the sender leaf MLS authenticated.
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

    test('the vector franking signature verifies only for its sender', () {
      final sig = vector['frank_sig'] as Map<String, dynamic>;
      bool check(String account, String device) => bindings.l2FrankVerify(
            signingKey: _hex(sig['signing_key'] as String),
            conversationId: sig['conversation_id'] as String,
            accountId: account,
            deviceId: device,
            commit: _hex(sig['commit'] as String),
            signature: _hex(sig['signature'] as String),
          );
      expect(
        check(sig['account_id'] as String, sig['device_id'] as String),
        isTrue,
      );
      expect(check(sig['account_id'] as String, 'dev_other'), isFalse);
      expect(check('acct_other', sig['device_id'] as String), isFalse);
    }, skip: skip);

    test(
      'a sealed sender signs; the receiver checks it against the MLS leaf',
      () {
        final alice = bindings.createDevice('acct_ls_alice', 'dev_ls_alice');
        final bob = bindings.createDevice('acct_ls_bob', 'dev_ls_bob');
        const groupId = 'conv_ls_dart';
        alice.createGroup(groupId);
        final staged = alice.stageCommit(
          groupId,
          adds: [
            (
              keyPackage: bob.createKeyPackage(),
              accountId: 'acct_ls_bob',
              deviceId: 'dev_ls_bob',
            ),
          ],
        );
        alice.mergePendingCommit(groupId);
        bob.joinGroup(groupId, staged.welcome);
        final commit = Uint8List.fromList(List<int>.filled(32, 0x24));
        final signature = alice.l2FrankSign(
          conversationId: groupId,
          commit: commit,
        );
        final ciphertext = alice.encrypt(groupId, utf8.encode('sealed hi'));
        final opened = bob.decryptSealed(groupId, ciphertext);
        expect(utf8.decode(opened.plaintext), 'sealed hi');
        final key = bob.memberSignatureKey(
          groupId,
          opened.accountId,
          opened.deviceId,
        );
        expect(
          bindings.l2FrankVerify(
            signingKey: key,
            conversationId: groupId,
            accountId: opened.accountId,
            deviceId: opened.deviceId,
            commit: commit,
            signature: signature,
          ),
          isTrue,
        );
        // Bob's own key never verifies Alice's signature.
        final bobKey = bob.memberSignatureKey(
          groupId,
          'acct_ls_bob',
          'dev_ls_bob',
        );
        expect(
          bindings.l2FrankVerify(
            signingKey: bobKey,
            conversationId: groupId,
            accountId: opened.accountId,
            deviceId: opened.deviceId,
            commit: commit,
            signature: signature,
          ),
          isFalse,
        );
      },
      skip: skip,
    );
  });
}
