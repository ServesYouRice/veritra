# T45B — Scheduled off-host backups and restore drills

| Field | Contract |
|---|---|
| Consensus source | I45 operations scope; DEP-09/NTH-04; R8/H1 |
| Initial eligibility | Blocked under D02 |
| Risk | High release blocker |
| Executor | Strong |
| Advisor | Review secret handling, retention and recovery objective |
| Depends on | T45A |
| Blocks | G24 restore evidence |
| Parallel safety | Coordinate deployment files with T46 and metrics with T47 |

## Objective

Ship a supported scheduled encrypted off-host backup path with age monitoring,
retention and disposable clean-host restore drills.

## Read first

- `docs/audit-consensus.md` I45.
- DEP-09/NTH-04 and Opus R8/H1.
- Backup CLI, `deploy/`, `docs/operations.md`, app/metrics tests.

## Invariants

- Backup destination credentials stay out of logs/environment dumps where avoidable.
- A successful backup is not claimed until restore is verified.
- Server backup data remains encrypted/ciphertext-only.

## Work

1. Define supported schedule, retention, off-host copy and recovery objective.
2. Add deployment timer/job using file-based secrets where applicable.
3. Emit privacy-safe last-success/age/failure metrics and alerts.
4. Automate disposable clean-host restore verification.

## Acceptance

- Scheduled off-host backup and retention run unattended.
- Stale/failing backup alerts before the recovery objective is missed.
- Clean-host DB/blob restore drill passes and is recorded.

## Required checks

```sh
cd server && go test ./cmd/messenger-server ./internal/app ./internal/storage
```

