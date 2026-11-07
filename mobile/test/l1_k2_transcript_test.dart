import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/k2_transcript.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

K2LinkContext _context(
        {List<int>? recipientKey, String recipient = 'dev_new'}) =>
    K2LinkContext(
      id: const K2TransferId('https://example.test', 'link_01'),
      accountId: 'acct_01',
      nonce: List<int>.filled(32, 0x11),
      sourceDeviceId: 'dev_old',
      sourceSigningKey: List<int>.filled(32, 0x22),
      recipientDeviceId: recipient,
      recipientSigningKey: recipientKey ?? List<int>.filled(32, 0x33),
      transferPublicKey: List<int>.filled(32, 0x44),
      sourceCommitment: _bytes(
          'ff2211c8c00f5fe3bbd434e9327b24d1caeaa0144ae01ab72cc1f6fe9e719393'),
      recipientRandom: List<int>.filled(32, 0x77),
    );

List<int> _bytes(String hex) => [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];

void main() {
  // testing/vectors/device-link-v4.json, which Rust and an independent
  // Python script check too: Dart must hash byte for byte as Rust.
  test('the v4 transcript hash matches the shared vector', () {
    expect(_hex(deviceLinkV3TranscriptHash(_context())),
        '66327629e6c43d9f94566895f17ece003a0e43b29f83a88815d1238e5a65399a');
  });

  test('a swapped recipient key or id changes the hash (L1 change 2)', () {
    final real = _hex(deviceLinkV3TranscriptHash(_context()));
    expect(
        _hex(deviceLinkV3TranscriptHash(
            _context(recipientKey: List<int>.filled(32, 0x34)))),
        isNot(real));
    expect(_hex(deviceLinkV3TranscriptHash(_context(recipient: 'dev_ghost'))),
        isNot(real));
  });
}
