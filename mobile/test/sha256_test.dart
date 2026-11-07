import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/sha256.dart';

/// FIPS 180-4 vectors, the padding boundaries, and a canonical token text:
/// the hash the server's `auth.HashToken` computes over the exact text.
void main() {
  String hash(String text) => sha256Hex(utf8.encode(text));

  test('standard vectors', () {
    expect(hash(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(hash('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(hash('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
    expect(hash('a' * 1000000),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
  });

  test('lengths around the padding boundary', () {
    expect(hash('a' * 55),
        '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318');
    expect(hash('a' * 56),
        'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a');
    expect(hash('a' * 64),
        'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb');
    expect(hash('a' * 119),
        '31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb');
  });

  test('a canonical 43-character token text', () {
    expect(hash('A' * 43),
        '0f007385b6f9d4b7eeb2748605afe1a984a0a3bfa3f014d09e2a784ce9e5cd1a');
    expect(sha256(utf8.encode('abc')), hasLength(32));
    expect(hexOf(<int>[0, 1, 255]), '0001ff');
  });
}
