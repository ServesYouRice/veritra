# T47 — Privacy-safe observability and capacity contract

| Field | Contract |
|---|---|
| Consensus source | I47; DEP-12/TEST-07/PERF-10/ARCH-08/NTH-03; H4 |
| Routing snapshot (board wins) | Prepared; conditional for private alpha, required before GA/scale claim |
| Risk | High for production capacity claims |
| Executor | Balanced+advisor |
| Advisor | Review metric privacy, workload model and target validity |
| Depends on | T35, T36B |
| Blocks | Evidence-backed host sizing/alerts; T49D |
| Parallel safety | One owner for metric names, seed/load harness and operations contract |

## Objective

Define small-instance host tiers and prove privacy-safe latency, backlog,
resource, backup and recovery limits under reproducible load/failure scenarios.

## Read first

- `docs/audit-consensus.md` I47.
- Named source findings and Opus H4.
- App metrics, push/retention metrics, storage/realtime code, deployment config,
  `docs/operations.md` and existing performance tests.

## Invariants

- Metrics never label user, account, conversation, token, endpoint, message ID
  or ciphertext identifier.
- Targets describe supported SQLite/local-blob single-node operation.
- No scale claim without measured evidence.

## Work

1. Define representative datasets, host tiers and p95/p99/backlog targets.
2. Add missing queue, writer, disk, backup-age and provider-result metrics.
3. Build reproducible seed/load/soak plus restart/provider-stall scenarios.
4. Add alerts and operator runbooks before limits are exceeded.

## Acceptance

- Published tiers include latency/error/backlog/resource/backup/restore limits.
- Alerts fire in tests and stalled workloads converge after recovery.
- Metric label/privacy audit passes.

## Required checks

```sh
cd server && go test ./internal/app ./internal/storage ./internal/push ./internal/realtime
```
