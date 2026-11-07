import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'native_test_env.dart';

/// C7 (ABI 13): the stateless crypto primitives against
/// testing/vectors/c7-primitives-v1.json, which the Rust core checks too.
/// Nothing in the app uses them yet. A missing vector fails; it never skips.
void main() {
  final vector = jsonDecode(
    File('../testing/vectors/c7-primitives-v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final inputs = vector['inputs'] as Map<String, dynamic>;
  final outputs = vector['outputs'] as Map<String, dynamic>;

  Uint8List hex(Object? value) {
    final text = value as String;
    return Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
  }

  /// `lp(x)` in C7: a u16 big-endian length, then the bytes.
  List<int> lp(String value) {
    final bytes = utf8.encode(value);
    return [bytes.length >> 8, bytes.length & 0xff, ...bytes];
  }

  List<int> fields(List<String> keys) {
    return [
      for (final key in keys) ...lp(inputs[key] as String),
    ];
  }

  group('native ABI 13, C7 primitives', () {
    late NativeCryptoBindings bindings;
    setUp(() {
      bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    });

    Matcher failsWith(NativeCryptoError kind) => throwsA(
          isA<NativeCryptoException>().having((e) => e.kind, 'kind', kind),
        );

    test(
      'derive, commitment and seal match the shared vector',
      () {
        final chk = bindings.c7Derive(
          key: hex(inputs['root_hex']),
          label: 'veritra-c7-rekey-chk-v1',
          info: fields(['community_id', 'channel_id']),
        );
        expect(chk, hex(outputs['chk_hex']));
        expect(bindings.c7ChkCommit(chk), hex(outputs['chk_commit_hex']));
        final messageInfo = fields([
          'community_id',
          'channel_id',
          'sender_device_id',
          'action_id',
        ]);
        final bodyKey = bindings.c7Derive(
          key: chk,
          label: 'veritra-c7-post-v1',
          info: messageInfo,
        );
        expect(bodyKey, hex(outputs['body_key_hex']));
        final slotKey = bindings.c7Derive(
          key: chk,
          label: 'veritra-c7-slot-v1',
          info: messageInfo,
        );
        expect(slotKey, hex(outputs['slot_key_hex']));
        final aad = hex(outputs['body_aad_hex']);
        final opened = bindings.c7Open(
          key: bodyKey,
          aad: aad,
          sealed: hex(outputs['sealed_body_hex']),
        );
        expect(opened, hex(inputs['body_plaintext_hex']));
        // The slot opens under its own key and holds the record and entry.
        final slot = bindings.c7Open(
          key: slotKey,
          aad: aad,
          sealed: hex(outputs['slot_hex']),
        );
        expect(slot, hex(outputs['slot_plain_hex']));
        // Another key is a mismatch, not an error: the next candidate.
        expect(
          bindings.c7Open(
            key: slotKey,
            aad: aad,
            sealed: hex(outputs['sealed_body_hex']),
          ),
          isNull,
        );
      },
      skip: nativeCryptoSkip(),
    );

    test(
      'seal and open round trip; the right key with a change fails closed',
      () {
        final key = Uint8List.fromList(List<int>.filled(32, 7));
        final plaintext = Uint8List.fromList(utf8.encode('a post'));
        const aad = [1, 2, 3];
        final sealed = bindings.c7Seal(
          key: key,
          aad: aad,
          plaintext: plaintext,
        );
        expect(sealed, hasLength(plaintext.length + 60));
        expect(
          bindings.c7Open(key: key, aad: aad, sealed: sealed),
          plaintext,
        );
        final tampered = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1;
        expect(
          () => bindings.c7Open(key: key, aad: aad, sealed: tampered),
          failsWith(NativeCryptoError.operationFailed),
        );
        const otherAad = [1, 2, 4];
        expect(
          () => bindings.c7Open(key: key, aad: otherAad, sealed: sealed),
          failsWith(NativeCryptoError.operationFailed),
        );
      },
      skip: nativeCryptoSkip(),
    );

    test(
      'signatures verify only in their own domain; other labels are refused',
      () {
        final key = hex(outputs['signing_public_key_hex']);
        final message = hex(outputs['post_signed_fields_hex']);
        final signature = hex(outputs['post_signature_hex']);
        expect(
          bindings.c7Verify(
            domain: 'veritra-c7-post-sig-v1',
            publicKey: key,
            message: message,
            signature: signature,
          ),
          isTrue,
        );
        expect(
          bindings.c7Verify(
            domain: 'veritra-c7-history-v1',
            publicKey: key,
            message: message,
            signature: signature,
          ),
          isFalse,
        );
        expect(
          () => bindings.c7Verify(
            domain: 'veritra-c7-other-v1',
            publicKey: key,
            message: message,
            signature: signature,
          ),
          failsWith(NativeCryptoError.invalidArgument),
        );
        expect(
          () => bindings.c7Derive(
            key: Uint8List(32),
            label: 'veritra-c7-enc-v1',
            info: const [1],
          ),
          failsWith(NativeCryptoError.invalidArgument),
        );
      },
      skip: nativeCryptoSkip(),
    );
  });
}
