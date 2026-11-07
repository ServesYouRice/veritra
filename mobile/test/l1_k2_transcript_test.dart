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
    );

void main() {
  // The vector of `v3_transcript_and_tags_match_independent_python_vector`
  // in crypto/rust/src/mls/link_v3.rs: Dart must hash byte for byte as Rust.
  test('the v3 transcript hash matches the Rust and Python vector', () {
    expect(_hex(deviceLinkV3TranscriptHash(_context())),
        'ad52136463e49d1c1484e12a2745de1722c99d402666dd533de03150391fb9db');
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
