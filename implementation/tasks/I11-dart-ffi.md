# I11 — Complete Dart/native bindings

Goal: expose the reviewed ABI v2 safely to Dart.

Read:

- `crypto/rust/include/veritra_crypto.h`, `crypto/rust/src/ffi.rs`
- `mobile/lib/crypto/native_crypto_bindings.dart`
- `mobile/lib/crypto/crypto_service.dart`

Do:

1. Bind state create/restore and every group add/remove/update/commit/encrypt/decrypt operation.
2. Centralize return-code mapping, size bounds, ownership, freeing, and typed errors.
3. Copy native outputs before freeing and avoid secret-bearing debug strings.
4. Add ABI conformance tests for malformed inputs, double free prevention, and repeated calls.
5. Keep the app on `UnavailableCryptoService` until I25.

Done when: Dart can exercise the full ABI against the packaged native library with no leaks or ownership ambiguity.

Verify:

```powershell
Push-Location crypto/rust; cargo test --locked; Pop-Location
Push-Location mobile; flutter analyze; flutter test; Pop-Location
```
