# Veritra Production Audit Plan

**Audit date:** 2026-07-21  
**Scope:** Repository-wide production-readiness review  
**Constraint:** Audit only. No application, infrastructure, dependency, or test code will be changed.

## Audit objective

Determine whether Veritra can safely support real self-hosted users, identify concrete launch blockers, and give developers an evidence-based fix order. Findings will be checked against the current tree rather than copied from roadmap documents or earlier audits.

## System inventory

| Area | Current implementation |
| --- | --- |
| Server | Go 1.25 modular monolith using `net/http`; one executable with serve, migration, backup, restore, doctor, and account-recovery commands |
| Database | SQLite through `modernc.org/sqlite`; 17 forward migrations; WAL-backed reader/writer routing |
| Realtime | Durable sync-event log plus a custom RFC 6455 WebSocket implementation and in-memory fan-out hub |
| Mobile | Flutter for Android and iOS; Material 3 UI; `ChangeNotifier` application state; secure-storage-backed local record |
| Cryptography | Rust/OpenMLS crate and C ABI; mobile production binding/orchestration remains intentionally fail-closed |
| Attachments/backups | Client-encrypted blob contracts with local filesystem storage and SQLite metadata |
| Authentication | Invite-only accounts; bcrypt passwords; device secrets; hashed bearer sessions; Ed25519 enrollment proofs; recent-auth gates |
| Push | Generic Web Push and Android UnifiedPush path; APNs/FCM deferred |
| Deployment | Scratch container, Docker Compose/Caddy, systemd example, GitHub Actions release and verification workflows |

## Core user flows to trace

1. First boot, setup authorization, owner enrollment, and initial session creation.
2. Invite creation, registration enrollment, account/device creation, and login.
3. Device linking, local verification, approval, session issuance, and revocation.
4. DM/group/community/channel creation, membership and role changes, and account blocking.
5. Encrypted message send, idempotency, durable sync, WebSocket delivery, catch-up, local outbox, and message history.
6. Reactions, edits, deletes, replies, retention, receipts, typing, and notification preferences.
7. Encrypted attachment and backup upload, download, quotas, pruning, operator backup, and restore.
8. Push subscription and generic wake delivery.
9. Admin account/invite/audit operations and user export/deletion.
10. Self-hosted install, TLS proxying, upgrades, observability, recovery, and release packaging.

## Review workstreams

### 1. UI and accessibility

- Inventory every reachable Flutter screen and embedded setup page.
- Trace navigation and compare UI surfaces with server-supported capabilities.
- Review loading, empty, failure, offline, destructive-action, form-validation, responsive, keyboard, screen-reader, and large-text behavior.
- Inspect representative mobile layouts through widget tests or rendered screenshots when the local toolchain permits it.

### 2. Logic and data integrity

- Trace state transitions and async interleavings across `AppState`, local persistence, sync, and outbox processing.
- Check server transactions, idempotency, membership/role rules, pagination, retention, blob lifecycle, and failure recovery.
- Cross-check embedded SQL against all migrations and API response models against the Dart client.

### 3. Security and privacy

- Verify authentication, authorization, proxy trust, setup bootstrap, rate limiting, session/device revocation, WebSocket parsing, and SSRF controls.
- Verify that message/attachment plaintext cannot cross server persistence, logging, push, search, export, or admin boundaries.
- Review crypto/FFI failure modes and clearly separate implementation review from the required independent protocol audit.

### 4. Performance and reliability

- Inspect hot queries, full-cache rewrites, sync amplification, fan-out, connection limits, upload/download behavior, cleanup jobs, and SQLite contention.
- Judge scalability against the documented single-node target rather than hyperscale requirements.

### 5. Tests, deployment, and operations

- Run the repository's safe baseline checks without changing source.
- Review unit/integration/widget/crypto coverage, CI platform jobs, dependency/license controls, release gates, container hardening, proxy defaults, backups, upgrades, rollback, monitoring, and incident documentation.

## Evidence and severity rules

- Every issue must name the affected path plus a function, route, component, or feature area.
- Claims will be based on code paths, tests, configuration, or command output; speculative risks will be labeled as such.
- **Critical:** core security/privacy or functionality is unusable or can cause catastrophic compromise/data loss.
- **High:** launch must stop until fixed.
- **Medium:** material production failure or trust risk; fix before launch where practical.
- **Low:** bounded risk or polish debt that can be scheduled.
- **Nice-to-have:** optional improvement with measurable product or engineering value.
- Each finding will state impact, fix, blocker status, and dependencies.

## Verification plan

- Run the Windows test and lint scripts if the required Docker/toolchains are available.
- Run the explicit release-readiness gate and record expected versus unexpected failures.
- Review test discovery/counts and CI workflows even when platform-specific jobs cannot run locally.
- Inspect the setup page directly; use Flutter test rendering for mobile visual evidence if available.
- Re-check every final finding against current code immediately before writing the reports.

## Deliverables

- `ui-issues.md`
- `logical-issues.md`
- `nice-to-haves.md`
- `security-issues.md`
- `performance-issues.md`
- `testing-gaps.md`
- `deployment-risks.md`
- `production-readiness.md`

## Planned review order

1. Baseline and architecture inventory.
2. Server routes, stores, migrations, and authorization.
3. Mobile state, persistence, API client, and all screens.
4. Crypto boundary, push, realtime, blobs, and recovery.
5. Tests, CI, packaging, and deployment documentation.
6. Evidence reconciliation, severity assignment, blocker list, and recommended fix waves.
