# Crypto Boundary

The selected production direction is MLS through OpenMLS. This Rust crate now
pins OpenMLS 0.9.0 and contains a tested native core for signed key packages,
group creation/join, and authenticated application messages. It also exposes a
versioned C ABI and Rust-side credential/key-package boundary types. ABI v6 has
tested opaque device handles, zeroing owned buffers, credential public-key
export, enrollment-challenge signing, key-package creation, state sealing, and
rollback-checked restore, plus group create/join/add/remove/update, staged
membership commits, commit processing, and application encrypt/decrypt. The legacy handle-free
encrypt/decrypt entry points still return `PM_CRYPTO_UNAVAILABLE`, so mobile code cannot
treat the native core as production crypto before the full path is wired and
reviewed.

The server now reserves final account/device IDs before key generation and
atomically verifies and consumes a signed enrollment proof covering the server
challenge, Ed25519 public key, and SHA-256 key-package commitment. The Flutter
client models this preflight, and its low-level Dart FFI binding requires ABI
version 6 exactly (`native_crypto_bindings.dart`) and uses the owned
device/buffer calls. Native libraries are packaged for Android/iOS, while the
production service remains behind the release gate.

The public header is `crypto/rust/include/veritra_crypto.h`, which pins
`PM_CRYPTO_ABI_VERSION` at 6. That version defines:

- account/device-bound opaque handles with exactly-once destruction
- library-owned, zero-on-free output buffers
- enrollment challenge signing with the MLS credential key
- sealed provider-state export and rollback-checked restore
- conversation-bound Welcome processing and credential-bound member addition
- the versioned protocol identifier `mls10-openmls-v1`
- sender binding (ABI 5): `pm_crypto_group_decrypt` takes the claimed sender
  account and device and returns `PM_CRYPTO_SENDER_MISMATCH` (-5) when the
  authenticated MLS credential differs (decision D25)
- staged membership commits (ABI 6, card I51):
  `pm_crypto_group_stage_commit` builds one commit adding and removing any
  number of devices without merging it; `pm_crypto_group_merge_pending_commit`
  and `pm_crypto_group_clear_pending_commit` settle it after the server's
  answer; `pm_crypto_group_epoch` reports the epoch and whether a commit waits.
  Groups keep two past epochs for decryption only (`max_past_epochs`).

Key-package size checks mirror the server transport boundary (64 bytes through
48 KiB). Passing that check does **not** verify an MLS key package.

OpenMLS 0.9.0, `openmls_rust_crypto` 0.6.0, and their supporting crates are
exactly pinned (Rust 1.91 or newer). All 205 locked third-party packages declare
compatible license choices recorded in `THIRD_PARTY_NOTICES.md`. Sealed state
uses envelope format version 2; version 1 blobs written under OpenMLS 0.8.1 fail
closed. No debug feature that exposes
message content or cryptographic material is enabled.

Before production message sending:

- connect the native ABI to the mobile protected record; the Flutter store now
  atomically writes the 32-byte state key, sealed state envelope, monotonic
  counter, and sync cursor through Android Keystore-backed encrypted storage or
  iOS Keychain (`ThisDeviceOnly`) storage
- add MLS test vectors
- obtain independent protocol and mobile-binding review

## Change log since the Stage 1 freeze

The crypto surface (ABI v5, payload semantics, local schema v7) froze after
Stage 1. Every later change is listed here for the G25 reviewer.

- **Stage 5, I33 (2026-09-24):** no ABI or payload change. Sync stops,
  without advancing the cursor, at any MLS control message it cannot apply,
  and at any application message it cannot decrypt unless the message has
  provably expired. The expired-message tombstone commits only the cursor and
  an `expired:<event>:<target>` marker. The durable recovery record lives in
  local metadata (`sync.recovery`) and holds no content or key material.
- **Stage 5, I34 (2026-09-24):** local schema v8 adds `attempt_count`,
  `next_attempt_at`, `failure_class` and `terminal` to
  `local_mls_outbox_entries` (additive migration). Messages from one MLS
  transition are now queued with increasing `queued_at`, so they are delivered
  in the order OpenMLS produced them; before, a transition's messages shared a
  timestamp and were ordered by their random idempotency key. A rejected
  control message is kept and pauses only its conversation.
- **Stage 5, I51 (2026-09-24):** ABI v6 (additive: the four functions
  above; the v5 functions are unchanged). New groups keep message secrets for
  two past epochs so a message sent just before a commit still decrypts; this
  slightly widens the forward-secrecy window. Group creation, membership
  changes and revocation removals now queue one staged commit bundle (commit,
  one Welcome for all added devices, roster change) that the server accepts
  only on the group's current epoch; this device merges its commit only after
  acceptance and drops it after a refusal, so a lost race never forks the
  group. Application envelopes carry `mls_epoch` in `crypto_metadata` (the
  epoch is already visible in the MLS header), which the server uses to
  withhold older-epoch messages from devices that joined later.
- **Stage 5, I45 (2026-09-24):** the mobile backup plaintext is format
  version 2: it adds the decrypted history and reactions (D27) to the
  identity, MLS state and queues it already carried; version 1 still
  restores. Encryption is unchanged (chunked AES-256-GCM with a device-held
  key; the server sees only ciphertext and a recovery-token hash). Recovery
  downloads may resume from any offset the server has sent, and the
  capability is still consumed only when a transfer reaches the end.
