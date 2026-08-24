# Veritra implementation tasks

This directory contains only unfinished, blocked, prepared, external, or
verification contracts derived from
[`docs/audit-consensus.md`](../docs/audit-consensus.md).
[`docs/board.md`](../docs/board.md) is the only source of eligibility and
status. A contract describes scope; it never makes itself claimable.

Production messaging remains **NO-GO**. Never remove
`PM_CRYPTO_UNAVAILABLE` or replace `UnavailableCryptoService` before G25 is
complete.

## Start here

1. Read `AGENTS.md`, [`KANBAN.md`](KANBAN.md), and
   [`WORKFLOW.md`](WORKFLOW.md).
2. Confirm the current board status and dependencies.
3. Open only the selected contract, its named consensus section, and starting
   code paths.
4. Reproduce the remaining gap before editing.
5. Make the smallest complete change and run every required check.
6. Update the board and consensus in the same change.

Do not browse Git history for removed task files or raw audits unless a current
contract cites a specific revision and path.

## Live contract index

The routing summary below reflects the board on 2026-08-24. Recheck the board
before every claim.

| Contract | Current routing |
|---|---|
| [T33](tasks/T33-sync-recovery.md) | Blocked until I30 verification is complete |
| [T34](tasks/T34-mls-control-outbox.md) | Blocked until the I31 pattern is verified |
| [T37C](tasks/T37C-password-session.md) | Partial; rotation and cost promotion remain policy/toolchain deferred |
| [T39](tasks/T39-database-key-recovery.md) | Blocked by I32 |
| [T41](tasks/T41-push-platform.md) | Blocked by I36; conditional under D03 |
| [T42B](tasks/T42B-native-call-lifecycle.md) | Design approval required before native edits |
| [T43C](tasks/T43C-accessibility-evidence.md) | Implementation present; automated and device evidence remain |
| [T44A](tasks/T44A-api-state-quality.md) | Prepared after release blockers |
| [T44B](tasks/T44B-conversation-quality.md) | Prepared after release blockers |
| [T44C](tasks/T44C-product-coherence.md) | Prepared after release blockers |
| [T45A](tasks/T45A-backup-restore-atomicity.md) | Blocked by I29 and I39 |
| [T45B](tasks/T45B-backup-operations.md) | Blocked by T45A |
| [T45C](tasks/T45C-mobile-recovery.md) | Blocked by I29, I39, and T45A |
| [T46](tasks/T46-deployment-hardening.md) | Prepared |
| [T47](tasks/T47-capacity-observability.md) | Prepared; depends on I35 and I36 |
| [T48A](tasks/T48A-transport-log-privacy.md) | Prepared; depends on I32 |
| [T48B](tasks/T48B-websocket-tls.md) | Prepared after T48A |
| [T49A](tasks/T49A-server-benchmarks.md) | Measure after correctness work |
| [T49B](tasks/T49B-storage-benchmarks.md) | Measure after correctness work |
| [T49C](tasks/T49C-mobile-benchmarks.md) | Measure after T30B and I32 verification |
| [T49D](tasks/T49D-admission-limits.md) | Measure after T47 |
| [T50](tasks/T50-deferred-roadmap.md) | Deferred behind D06/product trigger |
| [G24](tasks/G24-signed-device-evidence.md) | External signed-device evidence |
| [G25](tasks/G25-independent-review.md) | External independent review and activation |
| [G27](tasks/G27-crypto-advisories.md) | Upstream/review blocked |

The reviewed testing follow-ups live in
[`tasks/test-followups/`](tasks/test-followups/README.md). Their QA IDs are
children of the canonical cards and do not create eligibility.

Completed implementation contracts were removed from the working tree under
D09. Their results remain in the board and consensus; their exact historical
contracts are recoverable at `bfb3922`.
