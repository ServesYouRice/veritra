# I15 — Derive device-link SAS locally

Goal: both devices compare the same credential-bound SAS without trusting a server-authored value.

Read:

- device-link server handlers/storage and mobile screen
- device credential encoding in Rust/ABI
- `implementation/archive/2026-07-26/docs/crypto-protocol.md`

Do:

1. Define a domain-separated transcript containing both credentials, account, link nonce, and protocol version.
2. Derive the SAS independently on old and new devices.
3. Bind approval to the transcript hash; reject replay, expiry, or credential changes.
4. Keep the server as relay/state coordinator only.
5. Test maliciously substituted credentials and mismatched transcripts.

Done when: a server cannot make two different credential pairs display an accepted match.

Verify: Rust vector tests, server link tests, and Flutter link-flow tests.
