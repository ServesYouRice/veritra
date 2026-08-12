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
malformed/foreign-message rejection, and group update/removal. Provider state
now serializes to a bounded AES-256-GCM envelope bound to account, device, and a
monotonic rollback counter; restart, corruption, wrong-key, wrong-identity, and
rollback tests fail closed. ABI v2 now has tested opaque device-handle
ownership, zeroing library-owned buffers, key-package generation,
enrollment-challenge signing, state sealing, and rollback-checked restore.
The same owned-handle ABI now covers create/join/add/remove/update,
commit processing, and application encrypt/decrypt with a two-device lifecycle
test. Both mobile bindings remain fail-closed until the complete path receives
independent review. The Flutter protected
record can already commit the envelope key, monotonic counter, and sync cursor
together through Android Keystore-backed encrypted storage or iOS Keychain
`ThisDeviceOnly` storage; it rejects non-increasing counters before writing.

The enrollment boundary now reserves final account/device IDs before key
generation. Rust signs a domain-separated proof covering the server challenge,
credential public key, and SHA-256 key-package commitment; Go verifies and
atomically consumes it for owner, invite, and linked-device enrollment. A
low-level Dart FFI binding validates ABI v2 and its ownership contract, but the
native libraries and full group orchestration are not yet wired into release
builds.
