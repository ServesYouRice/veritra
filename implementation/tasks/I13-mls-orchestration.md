# I13 — Implement conversation MLS flow

Goal: mobile devices create, join, update, and converge MLS groups through ciphertext-only server transport.

Read:

- `crypto/rust/src/mls.rs`, ABI/bindings
- mobile API, sync, state, and crypto services
- key-package and conversation server endpoints
- `implementation/archive/2026-07-26/docs/crypto-protocol.md`

Do:

1. Implement key-package replenish/claim and group create/join.
2. Deliver and process Welcome/commit messages with roster and conversation binding.
3. Handle offline epoch gaps, duplicate delivery, restart, and safe recovery.
4. Apply I12's atomic state/cursor rule to every transition.
5. Add two-device and group lifecycle integration fixtures using synthetic ciphertext only.

Done when: two devices can create/join a conversation, exchange encrypted application bytes, restart, and converge offline.

Verify: Rust tests, Flutter tests, and the available two-device integration harness.

Do not invent crypto or bypass signature/roster validation.
