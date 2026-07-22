# Plan 03 — Mobile storage and production cryptography

This is the longest workstream and must be executed as separate cards. No
lower model may remove PM_CRYPTO_UNAVAILABLE or replace
UnavailableCryptoService before C13 is complete.

## C01 — Decide the encrypted local database

Audit references: LOG-03, PERF-01, TEST-04.

Objective:
Choose a supported Android/iOS transactional encrypted database and document
its key custody, migration, licensing, and failure behavior.

Read first:

- AGENTS.md dependency rules
- mobile/lib/storage/local_store.dart
- docs/crypto-protocol.md local-state contract
- docs/threat-model.md
- THIRD_PARTY_NOTICES.md

Steps:

1. Inventory required transactions: session identity, sync cursor, snapshots,
   outbox, per-group sealed MLS state, counter, drafts, and future search.
2. Research maintained Flutter/native options from primary documentation.
3. Verify exact direct and transitive licenses for AGPL compatibility.
4. Specify a random database key wrapped by platform secure storage; do not
   place bulk rows or plaintext in Keychain/EncryptedSharedPreferences.
5. Specify background-isolate/process coordination, schema migration,
   corruption, full-disk, rollback, reinstall, and backup behavior.
6. Write a small ADR and update THIRD_PARTY_NOTICES.md before adding packages.

Acceptance:

- The ADR selects one implementation with exact versions and rejected
  alternatives.
- Key custody and rollback behavior satisfy docs/crypto-protocol.md.
- No dependency is added before license review.
- The design has explicit Android and iOS test requirements.

## C02 — Build the encrypted database foundation

Depends on: C01.

Objective:
Create the smallest database wrapper, schema, migrations, and key-opening path
without moving application data yet.

Steps:

1. Add tables for account/session metadata, conversation cache, message
   envelopes, outbox, sync state, and sealed MLS group state.
2. Add unique keys and foreign keys for idempotency and conversation scope.
3. Open the database only after unwrapping the platform-protected key.
4. Fail closed on missing/wrong key, downgrade, or corrupt migration.
5. Serialize schema migration and background access.
6. Add unit tests plus Android/iOS integration-test hooks.

Acceptance:

- A transaction can atomically update multiple tables.
- The raw database is unreadable without the wrapped key in platform tests.
- Opening corrupt or newer-schema data does not silently reset it.
- No plaintext message fixture is added to server or mobile persistence tests.

## C03 — Migrate session, cache, cursor, and outbox

Depends on: C02.

Objective:
Remove the oversized read-modify-write secure-storage record and migrate its
non-crypto data transactionally.

Steps:

1. Introduce a new LocalStore implementation behind the existing interface.
2. Move snapshots and outbox to row-level tables.
3. Keep only the database key and minimal credentials in platform secure
   storage.
4. Write a one-time migration from veritra.account_state.v2/v3 that validates
   identity before import and deletes the old record only after commit.
5. Coordinate foreground and background-push access with one transaction
   discipline.
6. Add interleaving, process-death, corrupt-record, full-disk, and rollback
   tests.

Acceptance:

- Concurrent enqueue, catch-up, and outbox removal cannot lose one another.
- Cursor advancement commits with the cache changes it acknowledges.
- A failed migration leaves the old record intact and reports recovery steps.
- Large realistic ciphertext caches do not use secure-storage values.

## C04 — Commit MLS state and sync cursor atomically

Depends on: C03, C06.

Objective:
Guarantee that processing one MLS event cannot advance the cursor without its
new sealed group state, or commit state without the cursor.

Steps:

1. Define the transaction inputs and outputs for one incoming MLS message.
2. Store a monotonic counter and authenticated state metadata per group/device.
3. Seal state before the database transaction; commit sealed bytes, counter,
   derived local rows, and cursor together.
4. Reject counter rollback, group mismatch, and stale epoch.
5. Make duplicate delivery idempotent.
6. Add crash injection before seal, before commit, after commit, and before
   acknowledgement.

Acceptance:

- Every crash point restores either the complete old state or complete new
  state.
- A lower counter or incompatible state fails closed with recoverable UX.
- Duplicate events never perform a second MLS transition.

## C05 — Package the Rust library for Android and iOS

Audit references: LOG-02, DEP-03.

Objective:
Produce pinned native libraries for supported architectures with reproducible
metadata, but do not activate them in the app yet.

Read first:

- crypto/rust/Cargo.toml and Cargo.lock
- crypto/rust public ABI
- mobile Android and iOS build files
- release workflow
- THIRD_PARTY_NOTICES.md

Steps:

1. Define supported Android ABIs and iOS device/simulator architectures.
2. Build with release hardening and sensitive debug features disabled.
3. Generate/check ABI headers and symbol/version metadata.
4. Link artifacts into unsigned CI release builds.
5. Add checksums, license notices, and provenance inputs.
6. Test load/unload and ABI version rejection on each platform.

Acceptance:

- Clean Android and iOS builds link the exact pinned ABI.
- Unsupported ABI/version fails before any key/state operation.
- Artifacts contain no test keys, debug secrets, or absolute developer paths.
- Production service remains unavailable.

## C06 — Complete the Dart/native binding

Depends on: C05.

Objective:
Expose every reviewed ABI v2 operation with safe ownership, bounded inputs,
zeroization expectations, and typed errors.

Steps:

1. Map create/restore/seal/free, key-package, group create/join, add/remove,
   update, commit, application encrypt/decrypt, and exporter operations.
2. Wrap native buffers with one ownership rule and deterministic release.
3. Convert ABI errors into stable Dart categories without including secret
   bytes.
4. Enforce length limits and protocol version before native calls.
5. Add leak, double-free, use-after-free, corrupt-input, and repeated-lifecycle
   tests.
6. Keep orchestration out of the binding layer.

Acceptance:

- Every public ABI operation has a binding test.
- Native memory ownership is explicit and leak-checked.
- No private key, state, plaintext, or ciphertext is logged.
- Binding errors fail closed.

## C07 — Implement conversation MLS orchestration

Depends on: S01, C04, C06.

Objective:
Implement the documented group lifecycle without inventing new cryptography.

Steps:

1. Implement key-package replenishment and atomic claim.
2. Implement group creation plus initial roster commit before application data.
3. Deliver and process Welcome/commit messages through durable sync.
4. Validate server roster hints against authenticated MLS membership.
5. Implement epoch-gap recovery without skipping verification.
6. Handle offline add/update/remove convergence and key-package exhaustion.
7. Commit each state transition through C04.
8. Build deterministic multi-device test scenarios before UI activation.

Acceptance:

- DM, group, and channel lifecycles match docs/crypto-protocol.md.
- Missing/invalid commits, credentials, or epochs fail closed.
- Server membership is never treated as cryptographic proof.
- Offline devices converge or show a recoverable blocked state.

## C08 — Derive device-link SAS locally

Audit reference: SEC-02.

Depends on: C06 and stable credential encoding.

Objective:
Replace the server-authored verification code with a short authentication
string derived independently on both devices.

Steps:

1. Specify a domain-separated transcript containing both device credentials,
   account/device IDs, link nonce, and protocol version.
2. Canonically encode and hash the transcript locally on both devices.
3. Derive a human-comparable SAS with reviewed collision/usability tradeoffs.
4. Bind approval to the transcript hash and reject replay/credential changes.
5. Keep the server link state as transport/authorization, not trust proof.
6. Add vectors and two-device UX tests.

Acceptance:

- A malicious server cannot choose two independent SAS values that both
  devices accept for different credentials.
- Both devices derive the same value from the same transcript.
- Approval fails after any credential/transcript change.
- No private key or SAS secret is sent to or generated by the server.

## C09 — Define and implement authenticated application payloads

Depends on: C07.

Objective:
Encode, pad, authenticate, encrypt, decrypt, and render each supported payload
type consistently.

Payloads:

- message
- reply/thread
- edit
- delete
- reaction
- attachment manifest
- encrypted call signaling

Steps:

1. Version one canonical payload schema and maximum sizes.
2. Include routing references inside the authenticated payload.
3. Define padding classes and validation after decryption.
4. Reject server-visible hint mismatches.
5. Add positive, corrupt, cross-type, replay, oversize, and unknown-version
   vectors.
6. Only after tests pass, replace placeholder bubble rendering.

Acceptance:

- No payload type has a plaintext fallback.
- Unknown type/version and mismatched routing data fail closed.
- Edit/delete/reaction authorization is authenticated end to end.
- Padding and size behavior is documented.

## C10 — Add encrypted attachment UX

Depends on: C09, C03, S06, D04.

Objective:
Encrypt attachments on device, upload/download ciphertext, and decrypt only
after integrity/authentication succeeds.

Steps:

1. Define key derivation and authenticated manifest fields.
2. Encrypt and thumbnail locally; never upload plaintext or server thumbnails.
3. Persist resumable progress in the encrypted database.
4. Use Range-enabled authorized downloads.
5. Verify ciphertext hash and AEAD before exposing plaintext to the viewer.
6. Add cancellation, retry, disk-full, wrong-key, and tamper tests.

Acceptance:

- Server storage, logs, push, tests, and metadata contain no plaintext
  filename/content/thumbnail.
- Interrupted transfers resume safely.
- Tampered ciphertext never renders.

## C11 — Add client-encrypted backup and recovery

Depends on: C04, C09.

Objective:
Create and restore user-held-key backups without admin key escrow.

Steps:

1. Version and authenticate the manifest, account/device scope, KDF parameters,
   object hashes, and rollback counter.
2. Generate/display the recovery secret only on the client.
3. Encrypt before upload and verify periodically.
4. Restore into staging, validate everything, then atomically activate.
5. Explain that password reset does not recover message keys.
6. Add stolen-backup, wrong-key, corrupt-manifest, partial-upload, downgrade,
   and rollback tests.

Acceptance:

- Server never receives the recovery secret or plaintext backup.
- Restore cannot overwrite working state before full validation.
- Rollback and cross-account restore are rejected.
- Recovery UX states permanent-loss conditions honestly.

## C12 — Rotate and remove revoked device credentials

Depends on: C07, M03.

Objective:
Remove a revoked device from every affected MLS group, including after offline
returns.

Steps:

1. Persist pending rotation/removal work per group.
2. Commit credential update/remove operations with retry and epoch ordering.
3. Prevent revoked devices from claiming packages or fetching new handshake
   data.
4. Handle groups where no authorized online device can create the commit.
5. Add offline revocation and reinstatement-negative tests.

Acceptance:

- Server revocation never falsely claims cryptographic removal.
- Remaining devices converge on a roster without the revoked credential.
- The revoked device cannot regain access by replaying stale state.

## C13 — Produce release evidence and remove the fail-closed gate

Depends on: C01 through C12, V08.

Objective:
Remove the release gate only after complete cross-platform evidence and an
independent review.

Steps:

1. Run deterministic protocol/interoperability vectors.
2. Run Android and iOS real-device matrices for restart, background, offline
   epochs, corruption, backup, link, rotation, and revocation.
3. Complete dependency/SBOM/platform-notice review.
4. Freeze the protocol/recovery implementation and commission independent
   protocol, FFI, storage, and mobile key-handling review.
5. Remediate findings and bind evidence to the release commit.
6. Replace UnavailableCryptoService and remove PM_CRYPTO_UNAVAILABLE only in
   the final reviewed change.
7. Run the full release gates and signed artifact workflow.

Acceptance:

- Every requirement in docs/crypto-protocol.md Required review evidence passes.
- Independent findings are closed or documented as accepted non-blocking risk.
- Release-readiness passes for the intended reason.
- No plaintext fallback exists.
