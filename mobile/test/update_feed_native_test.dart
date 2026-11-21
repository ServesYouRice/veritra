import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/desktop/update_service.dart';
import 'package:private_messenger/desktop/update_verifier.dart';

import 'native_test_env.dart';

/// W12 (crypto ABI 27): the update feed's Ed25519 check through the native
/// library, with the signed vector `scripts/update-feed.py` made
/// (test/fixtures/update-feed/; Rust checks the same bytes in
/// crypto/rust/src/update_feed_tests.rs).
void main() {
  const dir = 'test/fixtures/update-feed';
  final feed = File('$dir/update.json').readAsBytesSync();
  final signature = File('$dir/update.json.sig').readAsBytesSync();
  final keyHex = File('$dir/public-key.hex').readAsStringSync().trim();
  final key = Uint8List.fromList([
    for (var i = 0; i < keyHex.length; i += 2)
      int.parse(keyHex.substring(i, i + 2), radix: 16),
  ]);

  group('pm_crypto_update_feed_verify', skip: nativeCryptoSkip(), () {
    late NativeCryptoBindings bindings;
    setUp(
      () => bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary()),
    );

    test('the committed vector verifies; a changed byte does not', () {
      expect(
        bindings.updateFeedVerify(
          publicKey: key,
          message: feed,
          signature: signature,
        ),
        isTrue,
      );
      final changed = Uint8List.fromList(feed)..[10] ^= 1;
      expect(
        bindings.updateFeedVerify(
          publicKey: key,
          message: changed,
          signature: signature,
        ),
        isFalse,
      );
      final otherKey = Uint8List.fromList(key)..[0] ^= 1;
      expect(
        bindings.updateFeedVerify(
          publicKey: otherKey,
          message: feed,
          signature: signature,
        ),
        isFalse,
      );
    });

    test('a signature over the feed without the domain is not valid', () {
      // The vector's signature covers "veritra-update-feed-v1" | feed, so
      // presenting the domain-prefixed bytes as the message must fail too.
      final prefixed = Uint8List.fromList([
        ...'veritra-update-feed-v1'.codeUnits,
        ...feed,
      ]);
      expect(
        bindings.updateFeedVerify(
          publicKey: key,
          message: prefixed,
          signature: signature,
        ),
        isFalse,
      );
    });

    test('wrong sizes are refused before the call', () {
      expect(
        () => bindings.updateFeedVerify(
          publicKey: key.sublist(0, 31),
          message: feed,
          signature: signature,
        ),
        throwsArgumentError,
      );
      expect(
        () => bindings.updateFeedVerify(
          publicKey: key,
          message: Uint8List(NativeCryptoBindings.updateFeedMaxBytes + 1),
          signature: signature,
        ),
        throwsArgumentError,
      );
      expect(
        () => bindings.updateFeedVerify(
          publicKey: key,
          message: feed,
          signature: signature.sublist(0, 63),
        ),
        throwsArgumentError,
      );
    });

    test('the app verifier with the vector key accepts the vector', () async {
      final verifier = Ed25519UpdateSignatureVerifier(
        publicKeyHex: keyHex,
        verify: bindings.updateFeedVerify,
      );
      expect(verifier.isConfigured, isTrue);
      expect(await verifier.verify(data: feed, signature: signature), isTrue);
      expect(
        await verifier.verify(
          data: Uint8List.fromList(feed)..[feed.length - 3] ^= 1,
          signature: signature,
        ),
        isFalse,
      );
      expect(await verifier.verify(data: feed, signature: null), isFalse);
    });

    test('a real service check reaches the offer only with a valid signature',
        () async {
      Future<UpdateStatus> check(List<int> body) async {
        final settings = UpdateSettings(MemoryUpdateSettingsStore(null));
        final service = createDesktopUpdateService(
          settings: settings,
          isWindows: true,
          executable: r'C:\Users\u\AppData\Local\Programs\Veritra\veritra.exe',
          environment: const {'LOCALAPPDATA': r'C:\Users\u\AppData\Local'},
          currentBuild: 1,
          publicKeyHex: keyHex,
          verify: bindings.updateFeedVerify,
          client: MemoryUpdateClient(
            responseBytes: Uint8List.fromList(body),
            signatureBytes: signature,
          ),
          // Inside the vector's validity (2026-11-21 to 2027-02-19).
          now: () => DateTime.utc(2026, 12, 1),
        );
        addTearDown(service.dispose);
        addTearDown(settings.dispose);
        return service.checkForUpdatesIfEnabled();
      }

      final good = await check(feed);
      expect(good.kind, UpdateStatusKind.updateAvailable);
      expect(good.update?.version, '0.2.0');
      final bad = await check(Uint8List.fromList(feed)..[20] ^= 1);
      expect(bad.kind, UpdateStatusKind.error);
      expect(bad.errorMessage, 'Update signature is invalid');
    });
  });
}
