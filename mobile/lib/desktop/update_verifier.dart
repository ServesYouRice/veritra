import 'dart:typed_data';

import '../crypto/native_crypto_bindings.dart';
import 'update_installer.dart';
import 'update_service.dart';
import 'update_trust.dart';

/// The native check: `NativeCryptoBindings.updateFeedVerify` (crypto ABI 27).
typedef UpdateFeedVerify = bool Function({
  required List<int> publicKey,
  required List<int> message,
  required List<int> signature,
});

final RegExp _publicKeyHex = RegExp(r'^[0-9a-f]{64}$');

/// The verifier this build uses: [Ed25519UpdateSignatureVerifier] once the
/// owner has compiled an update key into the app ([updateFeedPublicKeyHex],
/// 64 lowercase hex characters), and [FailClosedUpdateSignatureVerifier]
/// while it is empty or malformed, so no request is made without a key.
UpdateSignatureVerifier updateSignatureVerifierForBuild({
  String publicKeyHex = updateFeedPublicKeyHex,
  UpdateFeedVerify? verify,
}) {
  final verifier = Ed25519UpdateSignatureVerifier(
    publicKeyHex: publicKeyHex,
    verify: verify,
  );
  return verifier.isConfigured
      ? verifier
      : const FailClosedUpdateSignatureVerifier();
}

/// W12: checks the feed's detached Ed25519 signature in the native library
/// (`pm_crypto_update_feed_verify`): strict Ed25519 over
/// `"veritra-update-feed-v1"` followed by the exact feed bytes, under the
/// update key. Dart has no Ed25519 of its own and adds none.
///
/// [isConfigured] is true only for a key of exactly 64 lowercase hex
/// characters. Every doubt is a `false`: no key, no signature, a signature
/// that is not 64 bytes, an empty or oversized feed, a library that does not
/// load or refuses the call.
class Ed25519UpdateSignatureVerifier implements UpdateSignatureVerifier {
  Ed25519UpdateSignatureVerifier({
    String publicKeyHex = updateFeedPublicKeyHex,
    UpdateFeedVerify? verify,
  })  : _publicKey = _parseKey(publicKeyHex),
        _verify = verify;

  final Uint8List? _publicKey;
  UpdateFeedVerify? _verify;

  static Uint8List? _parseKey(String hex) {
    if (!_publicKeyHex.hasMatch(hex)) return null;
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  @override
  bool get isConfigured => _publicKey != null;

  @override
  Future<bool> verify({
    required List<int> data,
    required List<int>? signature,
  }) async {
    final key = _publicKey;
    if (key == null ||
        signature == null ||
        signature.length != 64 ||
        data.isEmpty ||
        data.length > maxUpdateFeedBytes) {
      return false;
    }
    try {
      final check = _verify ??= NativeCryptoBindings.load().updateFeedVerify;
      return check(publicKey: key, message: data, signature: signature);
    } catch (_) {
      return false;
    }
  }
}

/// The update service of a desktop build, as `DesktopServices` starts it.
///
/// Owner decision (2026-11-21): automatic checks are on by default once the
/// update key and this verifier exist, with the Settings switch to turn them
/// off. While the key is empty the verifier fails closed and nothing is
/// requested. Only Windows has the channel, and only a per-user install
/// downloads and starts an installer ([isPerUserWindowsInstall]); an
/// all-users install reports an available update and nothing more.
UpdateService createDesktopUpdateService({
  required UpdateSettings settings,
  required bool isWindows,
  required String executable,
  required Map<String, String> environment,
  required int currentBuild,
  void Function()? onQuitForUpdate,
  String publicKeyHex = updateFeedPublicKeyHex,
  UpdateFeedVerify? verify,
  UpdateClient? client,
  UpdateInstaller? installer,
  DateTime Function()? now,
}) {
  final perUser = isWindows &&
      isPerUserWindowsInstall(executable: executable, environment: environment);
  return UpdateService(
    settings: settings,
    currentBuild: currentBuild,
    platform: isWindows ? 'windows' : 'unsupported',
    client: client,
    verifier: updateSignatureVerifierForBuild(
      publicKeyHex: publicKeyHex,
      verify: verify,
    ),
    installer: perUser
        ? installer ??
            UpdateInstaller(
              downloader: const HttpUpdateDownloader(),
              digester: CertutilFileDigester(environment: environment),
              launcher: const InnoInstallerLauncher(),
            )
        : null,
    onQuitForUpdate: onQuitForUpdate,
    now: now,
  );
}
