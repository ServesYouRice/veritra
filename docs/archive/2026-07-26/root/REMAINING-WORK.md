# Remaining Work

Updated: 2026-07-18

This is the only active work tracker. Historical audits and duplicate TODO/plan
files were removed after their live requirements were rechecked against the
current tree.

## Production release blocker: mobile MLS integration

The Rust OpenMLS core and ABI v2 now implement tested device ownership, sealed
state, signed enrollment, group create/join/add/remove/update, commit handling,
and application encrypt/decrypt. The server reserves final account/device IDs,
verifies enrollment proofs, consumes key packages atomically, and remains
ciphertext-only. Call signaling accepts only the strict encrypted-envelope
schema.

Production remains intentionally blocked because these pieces are unfinished:

- Package the Rust library for supported Android and iOS architectures and link
  it into signed release builds.
- Finish the Dart/native binding for state restore and every group operation;
  connect it to the protected record and replace `UnavailableCryptoService`
  only after the complete path works.
- Implement mobile conversation MLS orchestration: key-package replenishment
  and claim, group creation, Welcome/commit delivery, roster validation,
  epoch-gap recovery, updates, removals, and offline convergence.
- Replace the server-issued device-link verification number with a QR/SAS value
  derived and checked locally from the old and new device credentials.
- Define, encode, pad, authenticate, encrypt, decrypt, and render all payload
  types: messages, replies, edits, deletes, reactions, attachment manifests,
  and encrypted call signaling.
- Rotate credentials and remove revoked devices from every affected MLS group,
  including devices that return after being offline.
- Add client-encrypted backup creation/recovery and rollback-safe restore.
- Add mobile encrypted attachment upload/download UX after attachment-key
  derivation is reviewed.
- Add standard MLS/interoperability vectors and recorded evidence covering
  multiple devices, restart, offline recovery, corruption, rotation, and
  revocation. Existing Rust tests are implementation tests, not independent
  interoperability evidence.
- Run two-real-device Android/iOS release tests and obtain an independent
  security review of protocol, FFI, storage, device linking, recovery, and
  failure behavior.

Until all items above pass, keep `PM_CRYPTO_UNAVAILABLE`,
`UnavailableCryptoService`, and `scripts/release-readiness.sh` fail-closed.

## Other unfinished product work

- Optional APNs and FCM adapters still require provider credential, entitlement,
  payload-privacy, and dependency/license review. Web Push plus Android
  UnifiedPush are implemented.
- WebRTC/LiveKit media and 1:1 call UX remain deferred until call E2EE and media
  dependency review are complete. The server signaling lifecycle is present.
- Client-side plaintext message search depends on production decryption and an
  encrypted local index.
- PostgreSQL/S3 adapters remain optional future scale work; SQLite/local blobs
  are the supported single-node design.

## Verification and external evidence still needed

- Run the newly added GitHub CI race, Android release-build, iOS no-codesign
  build, and fresh-volume Compose smoke jobs in GitHub; local tests cannot prove
  hosted runner/platform behavior.
- Add generated API-contract checks, security-invariant coverage thresholds,
  and the crypto-dependent two-device end-to-end suite.
- Complete a manual TalkBack and VoiceOver pass on real devices.
- Preserve the generated SPDX SBOM and platform dependency notices with every
  release.

## Current local verification

- Go server tests pass, including enrollment binding/replay, call-envelope,
  last-seen throttling, storage, and HTTP tests.
- Rust tests pass: 13 tests covering ABI ownership/state and MLS lifecycle.
- Flutter analysis passes with zero issues; all 34 Flutter tests pass.
- `scripts/test.ps1`, `scripts/lint.ps1`, and the direct-dependency license gate
  pass.
- `scripts/release-readiness.sh` fails as intended with `production MLS crypto
  is not wired`.
