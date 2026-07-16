# Crypto Research

## Candidates

### MLS / OpenMLS

OpenMLS is a Rust implementation of Messaging Layer Security (MLS), RFC 9420, under MIT. It is designed for group messaging and supports key packages, commits, group state, and mobile build targets. This aligns with DMs, private groups, communities, and channels.

Risks:

- MLS application integration is non-trivial.
- Multi-device UX, backups, and recovery require careful product decisions.
- Flutter FFI bindings require separate mobile engineering work.

### Signal / libsignal

libsignal is production-grade and AGPL-3.0. It has Rust internals and Java/Swift/TypeScript bindings. It is excellent for one-to-one and Signal-style group messaging but brings service and client assumptions that are less direct for self-hosted community/channel semantics.

### Matrix Crypto

Matrix offers a mature E2EE ecosystem and lessons around device verification, backup, and sync. Reusing the whole stack would make this project feel like a Matrix client/server instead of a simple self-hosted messenger and would import substantial complexity.

## Decision

Use MLS/OpenMLS as the preferred production crypto direction. In this MVP foundation, implement:

- device and key-package metadata
- crypto boundary interfaces
- encrypted envelope types
- ciphertext-only server persistence
- tests proving plaintext is not stored
- loud non-production markers until OpenMLS client integration is complete

No custom crypto primitives are permitted.

## Pinned implementation baseline

As of 2026-07-16, the native core pins OpenMLS 0.8.1 with the RustCrypto 0.5.1
provider and Rust 1.90. Interoperability tests cover signed single-use key
package validation, group creation/join, bidirectional application messages,
and malformed/foreign-message rejection. The mobile ABI intentionally remains
fail-closed until provider state is atomically protected by Android Keystore and
iOS Keychain wrapping and the complete binding receives independent review.
