# Veritra implementation tasks

This directory turns [`docs/audit-consensus.md`](../docs/audit-consensus.md)
into claimable execution contracts. The consensus remains authoritative for
scope and decisions; [`docs/board.md`](../docs/board.md) remains authoritative
for status. These files add implementation-sized boundaries and must not be
used to weaken either source.

Production messaging remains **NO-GO**. Never remove
`PM_CRYPTO_UNAVAILABLE` or replace `UnavailableCryptoService` before G25 is
complete.

## Start here

1. Read [`KANBAN.md`](KANBAN.md), [`WORKFLOW.md`](WORKFLOW.md), and
   [`docs/board.md`](../docs/board.md).
2. Choose the first task whose board status and dependencies make it eligible.
3. Read only that task, its named audit sections, and its starting code paths.
4. Confirm the defect still exists before editing.
5. Implement the smallest complete solution, run every required check, and
   request the named advisor review when required.
6. Update the board and consensus in the same change. One coordinator owns
   those updates when agents run in parallel.

## Execution order

Tasks in one row may run in parallel only when their actual write sets do not
overlap. T29 and T40A are intentionally first.

| Wave | Tasks | Rule |
|---|---|---|
| 0 | T29 → T40A; then T40B-T40D | Contain the capability leak, then make release controls executable. |
| 1 | T30A-T39 | Restore sync, lifecycle, outbox, retention, auth and key invariants. Respect each dependency. |
| 2 | T41-T45C | Complete promised push/call, first-run, accessibility and recovery paths. |
| 3 | T44A-T48B | Close prepared quality, deployment, operations and transport work. |
| 4 | T49A-T49D | Measure first; implement only against a named target. |
| External | G24, G25, G27 | Evidence, independent review and upstream crypto gates. |
| Deferred | T50 | Do not claim before its product trigger. |

## Task index

“Strong” means the strongest generally available coding/reasoning model.
“Balanced+advisor” means a capable everyday coding model with a stronger
advisor at the task's checkpoints. See [`WORKFLOW.md`](WORKFLOW.md).

| Task | Initial eligibility | Executor | Depends on | Contract |
|---|---|---|---|---|
| T29 | Ready, first | Strong | — | [Recovery capability secrecy](tasks/T29-recovery-capability.md) |
| T30A | Ready | Balanced+advisor | — | [Background sync containment](tasks/T30A-background-sync-containment.md) |
| T30B | After T30A | Strong | T30A | [Unified sync owner](tasks/T30B-unified-sync-owner.md) |
| T31 | Ready | Strong | — | [Lossless message outbox](tasks/T31-message-outbox.md) |
| T32 | Ready | Strong | — | [Account-scoped session lifecycle](tasks/T32-session-lifecycle.md) |
| T33 | Blocked | Strong | T30B | [Poison-event and stale-device recovery](tasks/T33-sync-recovery.md) |
| T34 | Blocked | Strong | T31 pattern | [Reliable MLS control outbox](tasks/T34-mls-control-outbox.md) |
| T35 | Ready | Balanced+advisor | — | [Retention and prune convergence](tasks/T35-retention-pruning.md) |
| T36A | Ready | Balanced+advisor | — | [Transactional fanout recipients](tasks/T36A-transactional-fanout.md) |
| T36B | After T36A | Strong | T36A | [Durable bounded wake jobs](tasks/T36B-durable-wake-jobs.md) |
| T37A | Ready | Balanced+advisor | — | [Setup-token hardening](tasks/T37A-setup-token.md) |
| T37B | Ready | Strong | — | [Credential rate limiting](tasks/T37B-auth-rate-limits.md) |
| T37C | Ready | Strong | — | [Password and session hardening](tasks/T37C-password-session.md) |
| T38 | Ready | Strong | — | [Safe account export](tasks/T38-account-export.md) |
| T39 | Blocked | Strong | T32 | [Fail-closed database-key recovery](tasks/T39-database-key-recovery.md) |
| T40A | Ready after T29; due 2026-08-29 | Balanced+advisor | T29 sequencing | [Rust exception expiry](tasks/T40A-rust-exception-expiry.md) |
| T40B | Ready after T40A | Balanced+advisor | T40A | [Toolchain and artifact parity](tasks/T40B-toolchain-parity.md) |
| T40C | Ready after T40A | Strong | T40A | [Positive release gate](tasks/T40C-release-gate.md) |
| T40D | Ready after T40A | Balanced+advisor | T40A | [Dependency and verification policy](tasks/T40D-dependency-verification.md) |
| T41 | Blocked, D03 | Balanced+advisor | T36B | [Push registration and platform readiness](tasks/T41-push-platform.md) |
| T42A | Ready, D03 | Strong | — | [Call authorization state machine](tasks/T42A-call-authorization.md) |
| T42B | Ready, D03 | Strong | design approval | [Native call lifecycle](tasks/T42B-native-call-lifecycle.md) |
| T43A | Ready | Balanced+advisor | — | [Control contrast](tasks/T43A-control-contrast.md) |
| T43B | Ready | Balanced+advisor | — | [First-run connection flow](tasks/T43B-first-run.md) |
| T43C | After T43A/T43B | Balanced+advisor | T43A, T43B | [Accessibility and visual evidence](tasks/T43C-accessibility-evidence.md) |
| T44A | Prepared | Balanced | release blockers | [API and stale-state quality](tasks/T44A-api-state-quality.md) |
| T44B | Prepared | Balanced | release blockers | [Conversation and form quality](tasks/T44B-conversation-quality.md) |
| T44C | Prepared | Balanced | release blockers | [Product/platform coherence](tasks/T44C-product-coherence.md) |
| T45A | Blocked, D02 | Strong | T29, T39 | [Backup/restore atomicity](tasks/T45A-backup-restore-atomicity.md) |
| T45B | Blocked, D02 | Strong | T45A | [Backup operations and restore drills](tasks/T45B-backup-operations.md) |
| T45C | Blocked, D02 | Strong | T29, T39, T45A | [Mobile recovery workflow](tasks/T45C-mobile-recovery.md) |
| T46 | Prepared | Balanced+advisor | release blockers | [Supported deployment hardening](tasks/T46-deployment-hardening.md) |
| T47 | Prepared | Balanced+advisor | T35, T36B | [Observability and capacity contract](tasks/T47-capacity-observability.md) |
| T48A | Prepared | Balanced+advisor | T32 | [Transport lifecycle and log privacy](tasks/T48A-transport-log-privacy.md) |
| T48B | Prepared | Strong | T48A | [WebSocket and LAN TLS assurance](tasks/T48B-websocket-tls.md) |
| T49A | Measure | Balanced | correctness tasks | [Server read/write benchmarks](tasks/T49A-server-benchmarks.md) |
| T49B | Measure | Balanced+advisor | correctness tasks | [Blob and quota benchmarks](tasks/T49B-storage-benchmarks.md) |
| T49C | Measure | Balanced | T30B, T32 | [Mobile state/render benchmarks](tasks/T49C-mobile-benchmarks.md) |
| T49D | Measure | Strong | T47 | [Admission limits and architecture decision](tasks/T49D-admission-limits.md) |
| T50 | Deferred | Strong only at trigger | D06/product trigger | [Deferred roadmap](tasks/T50-deferred-roadmap.md) |
| G24 | External | Coordinator | implementation complete | [Signed-device release evidence](tasks/G24-signed-device-evidence.md) |
| G25 | External | Independent reviewer | G24, G27, all blockers | [Independent review and activation](tasks/G25-independent-review.md) |
| G27 | External/upstream | Strong+advisor | upstream stable release | [Crypto advisory closure](tasks/G27-crypto-advisories.md) |

## Source-package coverage

| Consensus package | Execution tasks |
|---|---|
| I29 | T29 |
| I30 | T30A, T30B |
| I31 | T31 |
| I32 | T32 |
| I33 | T33 |
| I34 | T34 |
| I35 | T35 |
| I36 | T36A, T36B |
| I37 | T37A, T37B, T37C |
| I38 | T38 |
| I39 | T39 |
| I40 | T40A, T40B, T40C, T40D |
| I41 | T41 |
| I42 | T42A, T42B |
| I43 | T43A, T43B, T43C |
| I44 | T44A, T44B, T44C |
| I45 | T45A, T45B, T45C |
| I46 | T46 |
| I47 | T47 |
| I48 | T48A, T48B |
| I49 | T49A, T49B, T49C, T49D |
| I50 | T50 |
| I24 | G24 |
| I25 | G25 |
| I27 | G27 |
