import 'dart:typed_data';

import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/sha256.dart';
import 'package:private_messenger/crypto/crypto_service.dart';

/// The device signing key [TestOnlyCryptoService] reports (32 bytes).
final Uint8List testDeviceSigningKey =
    Uint8List.fromList(List<int>.generate(32, (i) => 0x20 + i));

/// A stand-in for an Ed25519 signature (64 bytes) that depends on the key and
/// the message and nothing else: [TestOnlyCryptoService] signs and checks with
/// it, so tests exercise the app's wiring. The real signature is checked in
/// `invite_binding_native_test.dart` against the native engine.
Uint8List fakeInviteSignature(List<int> signingKey, List<int> message) {
  List<int> part(int tag) =>
      sha256(<int>[tag, ...signingKey, ...message]).toList();
  return Uint8List.fromList(<int>[...part(1), ...part(2)]);
}

class TestOnlyCryptoService
    implements
        CryptoService,
        DeviceSigningKeyCryptoService,
        InviteBindingCryptoService {
  // Windows clocks tick coarsely, so a timestamp alone repeats within a test.
  static int _keySequence = 0;

  /// Roster keys this device "holds", by `conversation|account|device`.
  final Map<String, Uint8List> memberKeys = <String, Uint8List>{};

  /// What [verifyInviteBinding] answers, when a test forces it.
  bool? forcedVerification;

  @override
  Future<EnrollmentCredential> createEnrollmentCredential(
      EnrollmentReservation reservation) async {
    return EnrollmentCredential(
      deviceKeyPackage: 'TEST_ONLY_DEVICE_KEY_PACKAGE'.codeUnits,
      signingKey: List<int>.filled(32, 1),
      challengeSignature: List<int>.filled(64, 2),
    );
  }

  @override
  Future<MessageEnvelope> encrypt(
      String conversationId, String plaintext) async {
    return MessageEnvelope(
      conversationId: conversationId,
      idempotencyKey:
          '${DateTime.now().microsecondsSinceEpoch}-${_keySequence++}',
      ciphertext: 'TEST_ONLY_CIPHERTEXT_LEN:${plaintext.length}'.codeUnits,
      cryptoProtocol: 'test-only-not-production',
      cryptoMetadata: const <String, Object?>{
        'warning': 'not-production-crypto'
      },
    );
  }

  @override
  Future<Uint8List> deviceSigningPublicKey({
    required String accountId,
    required String deviceId,
  }) async =>
      Uint8List.fromList(testDeviceSigningKey);

  @override
  Future<Uint8List> signInviteBinding({
    required String accountId,
    required String deviceId,
    required List<int> message,
  }) async =>
      fakeInviteSignature(testDeviceSigningKey, message);

  @override
  Future<bool> verifyInviteBinding({
    required List<int> signingKey,
    required List<int> message,
    required List<int> signature,
  }) async {
    final forced = forcedVerification;
    if (forced != null) return forced;
    final expected = fakeInviteSignature(signingKey, message);
    if (signature.length != expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (signature[i] != expected[i]) return false;
    }
    return true;
  }

  @override
  Future<Uint8List?> memberSigningKey({
    required String conversationId,
    required String accountId,
    required String deviceId,
  }) async =>
      memberKeys['$conversationId|$accountId|$deviceId'];

  @override
  Future<String> deviceLinkLocator(List<int> secret) async => "a" * 64;
}
