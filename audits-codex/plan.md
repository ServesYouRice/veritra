# Audit remediation plan

> Implementation status: see [status.md](status.md). The remaining hard blocker is production MLS (R-02); OPS-17 is explicitly deferred maintainability work. Testing gaps remain excluded by request.

## Audit summary

The 2026-07-11 audit describes 75 findings against a ciphertext-first but
non-production messenger. The 2026-07-13 baseline is green for the repository's
Dockerized Go, Rust, and Flutter tests and linters; the pulled QR/community work
also closes or changes parts of R-05 and MOB-17, so every finding will be
revalidated before editing.

Testing-gap work is out of scope by request. This excludes OPS-07 and the final
"Verification gap recorded by this audit" section; normal regression checks for
implemented changes remain part of verification.

## Missing surfaces

| Implemented foundation | Missing surface | Fix |
|---|---|---|
| Device-link API | Production verification/scanning flow | Bind approval to verified key material and complete the mobile flow |
| Invites table/create route | Invite management | Add scoped list and revoke operations and owner UI |
| Attachment/backup storage | Authorized retrieval and lifecycle | Add metadata/list/get/delete contracts and enforce ownership/budgets |
| Community/channel writes | Durable community read model | Add scoped reads and consistent channel navigation |
| Call records/signaling | Call lifecycle | Add bounded versioned state transitions, expiry, and cleanup |
| Account/session controls | Password rotation/recovery and recent auth | Add explicit secure flows without weakening E2EE |
| Mobile shell | Android/iOS projects | Generate reviewed platform projects and secure defaults |

## Modernization and correctness work

- Release gates R-01 through R-14: close the setup race, transactional and
  authorization failures, restore/config/container hazards, mobile build drift,
  crypto/platform gaps, and deletion wording/policy.
- Security SEC-01 through SEC-19: enforce role, membership, identity,
  conversation, message-reference, idempotency, caching, export, blob,
  community, reaction, call, and session invariants.
- Mobile MOB-01 through MOB-23: make sync durable and paginated, harden network
  lifecycle and URL handling, fix offline auth behavior/navigation/search,
  improve accessibility/localization, and add durable encrypted client state.
- Operations OPS-01 through OPS-06 and OPS-08 through OPS-19: make backup,
  readiness, deployment, scripts, supply chain, pruning, timeouts, realtime,
  SQLite, pagination, metrics, and instance configuration match their promises.
- Preserve server ciphertext-only storage, generic push payloads, privacy-safe
  logs, fail-closed crypto, and reduced-motion/accessibility behavior.

## Verification plan

- Run focused Go/Flutter/Rust checks after each batch.
- Run `scripts/test.ps1` and `scripts/lint.ps1` after integrated changes.
- Build and inspect runnable mobile/platform artifacts when platform work lands.
- Keep audit documents as evidence; record closed or intentionally superseded
  findings instead of deleting historical reports.

## Order of work

1. Release-gate security and data-integrity fixes.
2. Mobile build, sync, navigation, and lifecycle fixes.
3. Missing product surfaces and production crypto/storage boundaries.
4. Operations, deployment, performance, and supply-chain fixes.
5. Full verification and audit status update.
