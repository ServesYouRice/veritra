import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';

class TestOnlyCryptoService implements CryptoService {
  @override
  Future<List<int>> createDeviceKeyPackage() async {
    return 'TEST_ONLY_DEVICE_KEY_PACKAGE'.codeUnits;
  }

  @override
  Future<MessageEnvelope> encrypt(
      String conversationId, String plaintext) async {
    return MessageEnvelope(
      conversationId: conversationId,
      idempotencyKey: DateTime.now().microsecondsSinceEpoch.toString(),
      ciphertext: 'TEST_ONLY_CIPHERTEXT_LEN:${plaintext.length}'.codeUnits,
      cryptoProtocol: 'test-only-not-production',
      cryptoMetadata: const <String, Object?>{
        'warning': 'not-production-crypto'
      },
    );
  }
}
