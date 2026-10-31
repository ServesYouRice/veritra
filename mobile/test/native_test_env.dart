import 'dart:io';

/// Gating for tests that need the native crypto library (TASK-098).
///
/// VERITRA_CRYPTO_LIBRARY is the path of a built libprivate_messenger_crypto.
/// Without it the native tests are skipped, so a developer can still run
/// `flutter test`. With VERITRA_REQUIRE_NATIVE_CRYPTO=1 they are not skipped:
/// they run and fail in setUp, so a verification run that forgot to build or
/// export the library cannot pass with them skipped.
const nativeCryptoLibraryVariable = 'VERITRA_CRYPTO_LIBRARY';
const requireNativeCryptoVariable = 'VERITRA_REQUIRE_NATIVE_CRYPTO';

String? get nativeCryptoLibraryPath {
  final path = Platform.environment[nativeCryptoLibraryVariable];
  return path == null || path.isEmpty ? null : path;
}

bool get nativeCryptoRequired =>
    Platform.environment[requireNativeCryptoVariable] == '1';

/// The `skip:` value for a native test: a reason when the library is absent
/// and not required, otherwise false.
Object nativeCryptoSkip() =>
    nativeCryptoLibraryPath == null && !nativeCryptoRequired
        ? '$nativeCryptoLibraryVariable not set'
        : false;

/// The library path, for setUp. Throws when native tests run without one.
String requireNativeCryptoLibrary() =>
    nativeCryptoLibraryPath ??
    (throw StateError(
      '$requireNativeCryptoVariable=1 but $nativeCryptoLibraryVariable is not '
      'set: build the native crypto library and export its path',
    ));
