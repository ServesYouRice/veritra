# Crypto Boundary

The selected production direction is MLS through OpenMLS. This Rust crate exposes
a versioned C ABI scaffold and Rust-side credential/key-package boundary types.
All operational ABI calls still return `PM_CRYPTO_UNAVAILABLE` without reading
their arguments, so mobile or server code cannot treat this scaffold as
production crypto.

The public header is `rust/include/veritra_crypto.h`. ABI version 1 reserves:

- account ID, device ID, and signing public key inputs for device credentials
- caller-owned output buffers for key packages and encrypted/decrypted messages
- the versioned protocol identifier `mls10-openmls-v1`

Key-package size checks mirror the server transport boundary (64 bytes through
48 KiB). Passing that check does **not** verify an MLS key package.

OpenMLS dependency review recorded on 2026-07-15 found the upstream `openmls`
0.8.1 crate and optional `openmls_rust_crypto` 0.5.1 provider, both MIT. They
are not dependencies yet: the complete transitive license set and mobile
platform build must be reviewed before committing a lockfile. No debug feature
that exposes message content or cryptographic material may be enabled.

Before production message sending:

- pin OpenMLS and its provider after complete transitive license/platform review
- implement reviewed ownership, allocation, and state-handle semantics behind the ABI
- add MLS test vectors
- add mobile secure key storage
- update `docs/crypto-research.md`
- update `THIRD_PARTY_NOTICES.md`
