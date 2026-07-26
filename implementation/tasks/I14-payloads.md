# I14 — Define encrypted app payloads

Goal: version, pad, authenticate, encrypt, decrypt, and render every MVP message action consistently.

Read:

- message models in server/mobile/crypto
- `implementation/archive/2026-07-26/docs/crypto-protocol.md`
- current message action handlers and UI

Do:

1. Define a bounded versioned client payload for text, reply, edit, delete, reaction, and attachment manifest.
2. Bind conversation, sender device, message/action ID, type, and version into authenticated context.
3. Specify padding and unknown-version failure behavior.
4. Allowlist the production protocol marker on every server mutation path.
5. Add round-trip, tamper, replay, wrong-conversation, and unknown-version tests.

Done when: supported actions render only after authentication; malformed or future payloads fail closed without losing sync progress.

Verify: Rust, server, and Flutter focused tests.

The server may validate envelope metadata but never parse plaintext payload content.
