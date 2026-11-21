import 'package:private_messenger/desktop/update_service.dart';

/// Test-only: a verifier that accepts every feed, so a test can reach the
/// code after the signature check. The shipped default accepts nothing
/// ([FailClosedUpdateSignatureVerifier]).
class AcceptingUpdateVerifier implements UpdateSignatureVerifier {
  const AcceptingUpdateVerifier();

  @override
  bool get isConfigured => true;

  @override
  Future<bool> verify({
    required List<int> data,
    required List<int>? signature,
  }) async =>
      true;
}
