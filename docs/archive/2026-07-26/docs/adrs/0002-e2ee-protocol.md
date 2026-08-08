# ADR 0002: E2EE Protocol Direction

## Status

Accepted for MVP direction; production integration incomplete.

## Decision

Target MLS through OpenMLS for production E2EE. The MVP server stores only encrypted envelopes and device/key-package metadata. It must not implement custom cryptography or pretend test doubles are production encryption.

## Consequences

- Message send APIs accept ciphertext only.
- Server-side tests reject plaintext fields and scan storage for plaintext sentinels.
- Flutter crypto remains behind an abstraction until Rust/OpenMLS bindings are added.

