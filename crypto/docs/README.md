# Crypto Boundary

The selected production direction is MLS through OpenMLS. This Rust crate now
pins OpenMLS 0.8.1 and contains a tested native core for signed key packages,
group creation/join, and authenticated application messages. It also exposes a
versioned C ABI scaffold and Rust-side credential/key-package boundary types.
All operational ABI calls still return `PM_CRYPTO_UNAVAILABLE` without reading
their arguments, so mobile or server code cannot treat the in-memory core as
production crypto before durable platform state is reviewed.

The public header is `rust/include/veritra_crypto.h`. ABI version 1 reserves:

- account ID, device ID, and signing public key inputs for device credentials
- caller-owned output buffers for key packages and encrypted/decrypted messages
- the versioned protocol identifier `mls10-openmls-v1`

Key-package size checks mirror the server transport boundary (64 bytes through
48 KiB). Passing that check does **not** verify an MLS key package.

OpenMLS 0.8.1, `openmls_rust_crypto` 0.5.1, and their supporting crates are
exactly pinned. All 151 locked third-party packages declare compatible license
choices recorded in `THIRD_PARTY_NOTICES.md`. No debug feature that exposes
message content or cryptographic material is enabled.

Before production message sending:

- implement reviewed ownership, allocation, and state-handle semantics behind the ABI
- replace in-memory provider state with atomic platform-protected persistence
- add MLS test vectors
- add mobile secure key storage
- update `docs/crypto-research.md`
- update `THIRD_PARTY_NOTICES.md`
