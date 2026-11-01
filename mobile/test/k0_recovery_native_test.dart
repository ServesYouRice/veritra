import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'native_test_env.dart';

/// K0 R1 (ABI 11): the Dart bindings against the shared known-answer vector
/// in testing/vectors/k0-recovery-v1.json, which the Rust core and the Go
/// server check too.
void main() {
  late NativeCryptoBindings bindings;
  late Map<String, dynamic> key;
  late Map<String, dynamic> proof;

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
    final vector = jsonDecode(
            File('../testing/vectors/k0-recovery-v1.json').readAsStringSync())
        as Map<String, dynamic>;
    key = vector['recovery_key'] as Map<String, dynamic>;
    proof = vector['proof'] as Map<String, dynamic>;
  });

  test('codec, derive and proof match the shared vector', () {
    final entropy = hex(key['entropy_hex']);
    expect(bindings.encodeRecoveryKey(entropy), key['display']);
    expect(bindings.decodeRecoveryKey(key['display'] as String), entropy);
    final derived = bindings.deriveRecoveryKey(entropy);
    expect(derived.rkPub, hex(key['rk_pub_hex']));
    expect(derived.rkId, hex(key['rk_id_hex']));
    expect(derived.rkAuthPub, hex(key['rk_auth_pub_hex']));
    final signature = bindings.signRecoveryProof(
      entropy: entropy,
      challenge: hex(proof['challenge_hex']),
      signingKey: hex(proof['signing_key_hex']),
      keyPackage: hex(proof['key_package_hex']),
      origin: proof['origin'] as String,
    );
    expect(signature, hex(proof['signature_hex']));
    final otherOrigin = bindings.signRecoveryProof(
      entropy: entropy,
      challenge: hex(proof['challenge_hex']),
      signingKey: hex(proof['signing_key_hex']),
      keyPackage: hex(proof['key_package_hex']),
      origin: 'https://chat.example.com.evil',
    );
    expect(otherOrigin, isNot(signature));
  }, skip: nativeCryptoSkip());

  test('typed variants decode; typos and bad input fail closed', () {
    final display = key['display'] as String;
    final entropy = hex(key['entropy_hex']);
    final grouped = [
      for (var i = 0; i < display.length; i += 4) display.substring(i, i + 4),
    ].join('-');
    expect(bindings.decodeRecoveryKey(grouped.toLowerCase()), entropy);
    expect(bindings.decodeRecoveryKey(grouped.replaceAll('-', ' ')), entropy);

    Matcher failsWith(NativeCryptoError kind) => throwsA(
        isA<NativeCryptoException>().having((e) => e.kind, 'kind', kind));
    final typo = display.replaceRange(10, 11, display[10] == 'A' ? 'B' : 'A');
    for (final text in [
      '',
      typo,
      display.substring(1),
      '${display}0',
      display.replaceFirst('W', 'U'),
      'é' * 52,
      '-' * 300,
    ]) {
      expect(() => bindings.decodeRecoveryKey(text),
          failsWith(NativeCryptoError.invalidArgument),
          reason: 'text of length ${text.length}');
    }
    expect(
        () => bindings.encodeRecoveryKey(Uint8List(29)), throwsArgumentError);
    expect(
        () => bindings.deriveRecoveryKey(Uint8List(31)), throwsArgumentError);
    expect(
      () => bindings.signRecoveryProof(
        entropy: entropy,
        challenge: hex(proof['challenge_hex']),
        signingKey: hex(proof['signing_key_hex']),
        keyPackage: hex(proof['key_package_hex']),
        origin: 'https://chat.example.com\n',
      ),
      failsWith(NativeCryptoError.invalidArgument),
    );
    expect(
      () => bindings.signRecoveryProof(
        entropy: entropy,
        challenge: hex(proof['challenge_hex']),
        signingKey: Uint8List(31),
        keyPackage: hex(proof['key_package_hex']),
        origin: proof['origin'] as String,
      ),
      throwsArgumentError,
    );
  }, skip: nativeCryptoSkip());

  test('generated keys round-trip and differ', () {
    final first = bindings.generateRecoveryKey();
    final second = bindings.generateRecoveryKey();
    expect(first, hasLength(NativeCryptoBindings.recoveryKeyEntropyBytes));
    expect(first, isNot(second));
    final display = bindings.encodeRecoveryKey(first);
    expect(display, hasLength(NativeCryptoBindings.recoveryKeyDisplayChars));
    expect(display, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{52}$')));
    expect(bindings.decodeRecoveryKey(display), first);
    expect(bindings.deriveRecoveryKey(first).rkAuthPub,
        isNot(bindings.deriveRecoveryKey(second).rkAuthPub));
    first.fillRange(0, first.length, 0);
    second.fillRange(0, second.length, 0);
  }, skip: nativeCryptoSkip());
}
