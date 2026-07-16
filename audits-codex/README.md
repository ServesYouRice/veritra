# Audit remaining work

Updated: 2026-07-13

The 2026-07-11 audit contained 75 findings. Of these, 73 are closed, one
release blocker remains, and one testing-gap finding is excluded by request.
The original reports and closed-finding evidence remain available in Git
history.

## R-02 - Complete production end-to-end encryption

The protocol and rollback rules are specified. The server already atomically
publishes, expires, exports, prunes, and single-use claims conversation-scoped
MLS key packages. It remains ciphertext-only.

Complete all of the following before a production release:

- Pin and license-review an exact OpenMLS release and its dependency/features
  set; update `THIRD_PARTY_NOTICES.md`.
- Implement the Rust OpenMLS core and reviewed Android/iOS bindings. Replace
  the default `UnavailableCryptoService` only when the full path is complete.
- Bind each MLS credential to the authenticated account and device. Require a
  signed server nonce and verified QR/SAS data for device approval.
- Generate, securely retain, upload, replenish, expire, and consume signed
  single-use key packages. Reject invalid, reused, expired, or incompatible
  packages.
- Implement direct, group, and channel MLS lifecycle: create, welcome, add,
  remove, update, roster validation, epoch-gap handling, and revoked-device
  removal.
- Encrypt and decrypt padded authenticated application payloads, including the
  protected metadata needed for replies, edits, deletes, reactions, and
  attachments. Never send plaintext message content to the server.
- Store signing keys, HPKE keys, and MLS group state using Android Keystore and
  iOS Keychain protection. Commit state, epoch, and sync cursor atomically;
  corruption or rollback must fail closed.
- Implement credential/key rotation and device revocation across every affected
  group, including offline-device convergence.
- Implement client-encrypted backup and recovery. Recovery secrets must never
  reach the server; validate hashes, KDF parameters, and rollback counters.
- Produce interoperability evidence for group creation, add/remove/update,
  application messages, exporters, multiple devices, offline recovery,
  corruption, and revocation.
- Obtain independent security review of the protocol, bindings, storage,
  recovery, and failure behavior; resolve all release-blocking findings.

Until every item is complete, retain `PM_CRYPTO_UNAVAILABLE`, the fail-closed
crypto service, and the release-readiness block.

Current implementation note (2026-07-16): exact OpenMLS dependencies are
license-reviewed and pinned. The Rust core covers signed key packages, group
create/add/join/update/remove, authenticated messages, and identity-bound
encrypted provider-state restart with corruption and rollback rejection. The
platform key wrapping, mobile ABI, recovery, broader interop evidence, and
independent review remain release-blocking.

## Completion evidence

- Two real devices can register, verify, send, receive, and decrypt.
- Add/remove, rotation, revocation, offline catch-up, and recovery work without
  exposing plaintext or weakening membership rules.
- Android and iOS release builds use the reviewed native crypto bindings.
- Interop vectors and independent security review are recorded.
- `scripts/test.ps1`, `scripts/lint.ps1`, and
  `scripts/release-readiness.sh` pass.

## Excluded testing-gap work - OPS-07

This remains outside the requested remediation scope:

- server race and integration coverage;
- migration and backup/restore coverage;
- fresh-volume Compose smoke coverage;
- generated API contract coverage;
- crypto vectors as CI coverage;
- two-device sync/end-to-end coverage;
- Android and iOS build jobs;
- accessibility and widget coverage;
- minimum coverage thresholds for security invariants.

Normal regression checks for implemented work are still required.
