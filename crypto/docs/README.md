# Crypto Boundary

The selected production direction is MLS through OpenMLS. This Rust crate now
pins OpenMLS 0.8.1 and contains a tested native core for signed key packages,
group creation/join, and authenticated application messages. It also exposes a
versioned C ABI and Rust-side credential/key-package boundary types. ABI v2 has
tested opaque device handles, zeroing owned buffers, credential public-key
export, enrollment-challenge signing, key-package creation, state sealing, and
rollback-checked restore, plus group create/join/add/remove/update, commit
processing, and application encrypt/decrypt. The legacy handle-free
encrypt/decrypt entry points still return `PM_CRYPTO_UNAVAILABLE`, so mobile code cannot
treat the native core as production crypto before the full path is wired and
reviewed.

The server now reserves final account/device IDs before key generation and
atomically verifies and consumes a signed enrollment proof covering the server
challenge, Ed25519 public key, and SHA-256 key-package commitment. The Flutter
client models this preflight, and its low-level Dart FFI binding validates ABI
v2 and uses the owned device/buffer calls. Native libraries are not yet packaged
into Android/iOS builds or wired as the production service.

The public header is `rust/include/veritra_crypto.h`. ABI version 2 defines:

- account/device-bound opaque handles with exactly-once destruction
- library-owned, zero-on-free output buffers
- enrollment challenge signing with the MLS credential key
- sealed provider-state export and rollback-checked restore
- the versioned protocol identifier `mls10-openmls-v1`

Key-package size checks mirror the server transport boundary (64 bytes through
48 KiB). Passing that check does **not** verify an MLS key package.

OpenMLS 0.8.1, `openmls_rust_crypto` 0.5.1, and their supporting crates are
exactly pinned. All 151 locked third-party packages declare compatible license
choices recorded in `THIRD_PARTY_NOTICES.md`. No debug feature that exposes
message content or cryptographic material is enabled.

Before production message sending:

- connect the native ABI to the mobile protected record; the Flutter store now
  atomically writes the 32-byte state key, sealed state envelope, monotonic
  counter, and sync cursor through Android Keystore-backed encrypted storage or
  iOS Keychain (`ThisDeviceOnly`) storage
- add MLS test vectors
- obtain independent protocol and mobile-binding review
