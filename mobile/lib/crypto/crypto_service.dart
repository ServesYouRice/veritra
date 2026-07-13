import '../core/models.dart';

abstract class CryptoService {
  Future<List<int>> createDeviceKeyPackage();
  Future<MessageEnvelope> encrypt(String conversationId, String plaintext);
}

class UnavailableCryptoService implements CryptoService {
  @override
  Future<List<int>> createDeviceKeyPackage() async {
    throw StateError(
        'Production MLS/OpenMLS device key package creation is not integrated');
  }

  @override
  Future<MessageEnvelope> encrypt(
      String conversationId, String plaintext) async {
    throw StateError('Production MLS/OpenMLS encryption is not integrated');
  }
}
