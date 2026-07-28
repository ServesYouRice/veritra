# Implementation board

Status: **NO-GO** — production crypto remains fail-closed.

## User decisions

- [ ] **D01** Approve `drift` 2.34.3 + `sqlite3` 3.5.0 with the `sqlite3mc` hook and explicit ChaCha20; keep a random 256-bit hex key in device-bound `flutter_secure_storage` and fail closed if cipher/key checks fail. Tradeoff: more Dart/codegen surface than `sqflite_sqlcipher`, but a verified, current encryption path with typed transactional migrations. Blocks I09, I12, I18, I19.
- [ ] **D02** Keep encrypted backup/recovery in the first production release? Recommended: yes. Blocks I18 scope.
- [ ] **D03** Defer native APNs/FCM and calls until after core messaging? Recommended: yes.
- [ ] **D04** Minimize admin audit events by omitting block/member target IDs unless operationally required?
- [ ] **D05** Choose timing/budget for an independent protocol/mobile security review. Blocks I25.

## Ready

- None.

## Doing

- [ ] [I15 — Derive device-link SAS locally](tasks/I15-device-link.md)


## Blocked

- [ ] [I09 — Encrypted local database](tasks/I09-local-database.md) — D01
- [ ] [I18 — Encrypted backup and recovery](tasks/I18-backup-recovery.md) — D02
- [ ] [I25 — Independent review and release gate](tasks/I25-release-gate.md) — D05

## Backlog

- [ ] [I12 — Commit MLS state and cursor together](tasks/I12-mls-state.md) — after I09, I11
- [ ] [I13 — Implement conversation MLS flow](tasks/I13-mls-orchestration.md) — after I02, I04, I12
- [ ] [I14 — Define encrypted app payloads](tasks/I14-payloads.md) — after I13
- [ ] [I16 — Remove revoked devices from groups](tasks/I16-revocation.md) — after I04, I13, I15
- [ ] [I17 — Add encrypted attachment UX](tasks/I17-attachments.md) — after I07, I09, I14
- [ ] [I19 — Fix mobile sync, history, and outbox](tasks/I19-mobile-sync.md) — after I05, I09, I14
- [ ] [I20 — Add identity and safety UX](tasks/I20-safety-ux.md) — after I04, I14, I19
- [ ] [I26 — Verify peer identity out of band](tasks/I26-peer-verification.md) — after I13, I15, I20
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

- 2026-07-28: I21 — Enforced a tested single-writer process lock, one-time production setup secret lifecycle, readiness-first graceful drain, clean-host backup/restore drill, hardened deployment examples/runbook, and aligned pinned toolchains; the user-requested fresh Compose smoke remains reserved for the final pre-push gate.
- 2026-07-28: I23 — Hardened WebSocket handshakes and frame parsing, added fuzz/adversarial coverage for masking, fragmentation, bounds, control frames, UTF-8, close, lifecycle, slow clients, and proved trusted-proxy connection limits under the race detector.
- 2026-07-28: I22 — Added a migrated live-server contract suite covering every Flutter API route, typed JSON models, errors, and pagination with synthetic ciphertext; CI and aggregate tests pass.
- 2026-07-28: I11 — Bound the complete ABI v2 with typed errors, bounded secret handling, native finalization/idempotent close, and a passing Dart-to-Rust lifecycle conformance test; the app remains on the unavailable crypto service.
- 2026-07-28: I10 — Pinned Rust 1.90 mobile targets, added reproducible Android JNI/iOS XCFramework packaging with source/license metadata, linked the fail-closed ABI, and added CI symbol/build checks.
- 2026-07-28: I08 — Recommended exact Drift/SQLite3MC versions and a device-bound random-key design; documented the smaller-surface tradeoff for D01 approval.
- 2026-07-28: I07 — Made encrypted blob writes durable across file and directory sync, validated size and digest before reads, added authorized range downloads, and persisted deletion retries.
- 2026-07-28: I06 — Unified spoof-resistant HTTP/WebSocket/setup client identity, added strict enrollment and privacy-safe login backoff with bounded retry guidance, and made reference production setup fail closed.
- 2026-07-28: I05 — Added a scoped single-envelope repair endpoint and mobile sync repair-by-ID so old edits/deletes converge outside the newest page.
- 2026-07-28: I04 — Enforced unique two-account DMs and added scoped rosters plus safe group leave/removal with rank, last-owner, atomic lifecycle events, and explicit pending MLS coordination.
- 2026-07-28: I03 — Durable mutations and sync events are atomic for message edits/deletes, reactions, receipts, retention, calls, and device events; realtime publishing requires a committed event ID.
- 2026-07-28: I02 — Key-package claims now use migrated memberships transactionally; storage/API tests cover non-members, requester-device exclusion, and single-use behavior.
- 2026-07-28: I01 — Established a clean baseline; fixed the fail-closed setup notice, updated the scanner API callback, and removed the deprecated secure-storage option. Tests and lint pass; release readiness fails only at the intentional crypto gate.
- 2026-07-26: Consolidated active work; archived audits, old plans, and superseded docs.
