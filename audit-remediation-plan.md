# Fable Audit Remediation Plan

## Audit summary

The standalone Fable defects are closed and the test/lint baseline is green.
The remaining release work is dominated by production MLS, platform-secure
state, dependent messaging UX, and evidence that spans Go, Rust, Flutter,
Android, and iOS. The server must remain ciphertext-only and the client must
remain fail-closed until the crypto implementation, platform bindings, and
independent review are complete.

`Plan.md` already exists as the product plan, so this dedicated file is used
instead of overwriting it.

## Missing surfaces

| Feature already implemented | Missing page or surface | Fix |
|---|---|---|
| Session identity includes username/account/device IDs | Full account profile | Add a reachable profile screen with copyable identity and device context; keep unsupported editing explicit |
| Ciphertext attachment APIs and storage | Mobile encrypted attachment picker/progress/download | Add client encryption boundary, transfer state, retry, and accessible file actions after MLS payload protection exists |
| Encrypted message submission | Persistent sending/failed/retry state | Add an encrypted outbox-backed status model and retry action |
| QR device-link flow | Production cryptographic continuity result | Bind QR/SAS approval to signed device credentials and show verified/failed state |
| Backup blob APIs | Client-encrypted backup creation/restore | Add recovery-key UX, authenticated manifest validation, rollback protection, and restore confirmation |

## Modernization list

- Replace global busy/error coupling in touched flows with operation-scoped
  immutable state.
- Replace transient send snackbars with durable outbox status and retry.
- Replace unlabeled composite controls with merged `Semantics`, explicit
  headings, live-region status, and minimum touch targets.
- Replace debug/raw identifiers as primary labels with username-first labels;
  keep copyable identifiers in details.
- Preserve Material 3 adaptive navigation, reduced-motion behavior, secure
  storage, and manual device-link fallback.

## Verification plan

- Rust: unit, negative, corruption, replay, interop-vector, formatting,
  Clippy, dependency audit, and C ABI tests.
- Go: unit, race, fuzz smoke, migration, backup/restore, WebSocket protocol,
  quota, contract, and black-box integration tests.
- Flutter: unit/widget/accessibility tests, coverage, encrypted-state rollback
  tests, and Android/iOS build jobs.
- Cross-layer: generated contract fixtures, two-device encrypted messaging,
  offline catch-up, revocation, recovery, and ciphertext-only persistence.
- Release: SPDX/license evidence, vulnerability gates, platform builds,
  screenshots/manual accessibility pass, two-device evidence, and independent
  security review before removing `PM_CRYPTO_UNAVAILABLE`.

## Order of work

1. Pin and license-review OpenMLS and its exact feature/dependency set.
2. Implement the Rust MLS core, durable state format, and reviewed C ABI.
3. Add Android/iOS secure-storage bindings and device credential continuity.
4. Wire Flutter only after native failure, rollback, and interop tests pass.
5. Add profile, attachments, outbox status, backup/recovery, and accessibility.
6. Add the excluded testing/coverage/platform gates.
7. Run full verification, update audit evidence, obtain independent review,
   and only then remove the release block.
