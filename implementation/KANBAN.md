# Implementation board

Status: **NO-GO** — production crypto remains fail-closed.

## User decisions

- [ ] **D01** Approve the encrypted mobile database selected by I08. Blocks I09, I12, I18, I19.
- [ ] **D02** Keep encrypted backup/recovery in the first production release? Recommended: yes. Blocks I18 scope.
- [ ] **D03** Defer native APNs/FCM and calls until after core messaging? Recommended: yes.
- [ ] **D04** Minimize admin audit events by omitting block/member target IDs unless operationally required?
- [ ] **D05** Choose timing/budget for an independent protocol/mobile security review. Blocks I25.

## Ready

- [ ] [I01 — Establish a clean baseline](tasks/I01-baseline.md)

## Doing

- None.

## Blocked

- [ ] [I09 — Encrypted local database](tasks/I09-local-database.md) — D01
- [ ] [I18 — Encrypted backup and recovery](tasks/I18-backup-recovery.md) — D02
- [ ] [I25 — Independent review and release gate](tasks/I25-release-gate.md) — D05

## Backlog

- [ ] [I02 — Fix key-package claims](tasks/I02-key-packages.md) — after I01
- [ ] [I03 — Make mutations and events atomic](tasks/I03-atomic-events.md) — after I01
- [ ] [I04 — Enforce DM and member lifecycle](tasks/I04-membership.md) — after I02, I03
- [ ] [I05 — Add old-message repair](tasks/I05-sync-repair.md) — after I03
- [ ] [I06 — Harden proxy, setup, and throttles](tasks/I06-proxy-auth.md) — after I01
- [ ] [I07 — Make encrypted blobs durable](tasks/I07-blobs.md) — after I01
- [ ] [I08 — Select the encrypted mobile database](tasks/I08-database-decision.md) — after I01
- [ ] [I10 — Package Rust for Android/iOS](tasks/I10-native-packaging.md) — after I01
- [ ] [I11 — Complete Dart/native bindings](tasks/I11-dart-ffi.md) — after I10
- [ ] [I12 — Commit MLS state and cursor together](tasks/I12-mls-state.md) — after I09, I11
- [ ] [I13 — Implement conversation MLS flow](tasks/I13-mls-orchestration.md) — after I02, I04, I12
- [ ] [I14 — Define encrypted app payloads](tasks/I14-payloads.md) — after I13
- [ ] [I15 — Derive device-link SAS locally](tasks/I15-device-link.md) — after I11
- [ ] [I16 — Remove revoked devices from groups](tasks/I16-revocation.md) — after I04, I13, I15
- [ ] [I17 — Add encrypted attachment UX](tasks/I17-attachments.md) — after I07, I09, I14
- [ ] [I19 — Fix mobile sync, history, and outbox](tasks/I19-mobile-sync.md) — after I05, I09, I14
- [ ] [I20 — Add identity and safety UX](tasks/I20-safety-ux.md) — after I04, I14, I19
- [ ] [I26 — Verify peer identity out of band](tasks/I26-peer-verification.md) — after I13, I15, I20
- [ ] [I21 — Harden production deployment](tasks/I21-deployment.md) — after I06, I07
- [ ] [I22 — Add live API contracts](tasks/I22-api-contracts.md) — after I04, I05
- [ ] [I23 — Test proxy and WebSocket adversarial paths](tasks/I23-proxy-websocket.md) — after I06
- [ ] [I24 — Build signed apps and run real-device checks](tasks/I24-release-builds.md) — after I16–I23, I26

## Later

- Measure before performance changes: query plans, load, soak, push fan-out.
- Profiles/avatars, local content search, desktop, multi-account, passkeys.
- Product polish: `veritra://` invite URI and QR, mute, drafts, richer empty states.
- Encrypted extensions: link previews, voice notes, client-side import.
- Moderation reports and post-quantum readiness need a product trigger first.
- Dead-code and wrapper cleanup only after blockers; do not churn active seams.
- Native push and calls follow D03.
- Session inventory and audit-metadata changes follow D04.
- Out of scope: federation, Postgres, S3, NATS.

## Done

- 2026-07-26: Consolidated active work; archived audits, old plans, and superseded docs.
