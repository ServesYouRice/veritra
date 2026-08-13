# T45A — Backup/restore and migration atomicity

| Field | Contract |
|---|---|
| Consensus source | I45 engine scope; DEP-04/DEP-05/DEP-10/TEST-08; R5 |
| Initial eligibility | Blocked under D02 |
| Risk | High release blocker |
| Executor | Strong |
| Advisor | Required before activation/rollback design and after fault tests |
| Depends on | T29, T39 |
| Blocks | T45B/T45C |
| Parallel safety | One owner for CLI backup/restore/migrate and storage activation |

## Objective

Make concurrent invocation, staging, activation and rollback crash-safe so the
original instance remains recoverable under every named failure.

## Read first

- `docs/audit-consensus.md` I45.
- Named deployment/testing findings and Opus R5.
- `server/cmd/messenger-server/main.go`, `main_test.go`, storage SQLite backup
  helpers, migrations and `docs/operations.md`.

## Invariants

- Unique invocation-owned staging only; never recursively clean an unresolved path.
- Activation has provenance, fsync/journal and explicit rollback boundaries.
- Migration rollback across incompatible schema means verified restore, not wishful down migration.

## Work

1. Replace fixed/colliding stage paths with validated owned staging.
2. Add preflight/provenance markers and durable activation order.
3. Define rollback behavior for DB, blobs and SQLite companion files.
4. Add fault injection for disk full, permission, corruption and process death.

## Acceptance

- Concurrent/pre-existing paths cannot damage each other.
- Every injected failure leaves original or rollback state recoverable.
- Clean-host restore validates database plus blobs.

## Required checks

```sh
cd server && go test ./cmd/messenger-server ./internal/storage
```

