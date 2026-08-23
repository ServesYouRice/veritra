# QA09 — Test historical upgrades and failed-migration rollback

| Field | Contract |
|---|---|
| Confirmed source | `testing/review_findings.md` M5 at `3ee785d` |
| Canonical owner | T45A migration/restore atomicity |
| Initial eligibility | Blocked by I29 and I39 with T45A |
| Risk | High migration/recovery boundary, test-only scope |
| Executor | Balanced+advisor |
| Advisor | Required before any production migration/store edit |
| Depends on | Eligible T45A claim |
| Blocks | T45A upgrade and rollback evidence |
| Parallel safety | Storage tests only; do not overlap T45A migration implementation |

## Objective

When T45A becomes eligible, prove representative historical databases upgrade
forward through current migrations and that a failing migration rolls back its
schema changes and migration record together. Do not add down migrations.

## Read first

- `docs/audit-consensus.md` I45 and
  `implementation/tasks/T45A-backup-restore-atomicity.md`.
- `server/internal/storage/sqlite.go`, migration tests around
  `TestMigrateRejectsEditedAppliedMigration`, and `server/migrations/`.
- Data introduced by migrations 0021, 0024, 0026, 0027, and 0028.

## Confirm first

Verify current tests cover clean migration, repeat application, and checksum
tamper but do not build/seed upgrades from pre-0021, pre-0024, and pre-0028
states or inject a partially executed failing migration. If all are now
covered, return `stale`. Until I29/I39 are complete, return `blocked` without
editing.

## Allowed write set

- `server/internal/storage/sqlite_test.go` or a new focused migration test.
- Text-only test fixture helpers under `server/internal/storage/testdata/` if
  they reduce duplication.

Do not edit any existing migration SQL, `sqlite.go`, backup/restore production
code, or generate a binary database fixture without advisor approval.

## Invariants

- Migrations move forward only; no downgrade/down-migration is introduced.
- Fixtures use actual historical migration prefixes and representative seeded
  rows, not a hand-waved current schema.
- A failing migration leaves neither its partial schema objects nor its
  `schema_migrations` record; already committed earlier migrations may remain.
- Seeded ciphertext stays synthetic and is never interpreted as plaintext.

## Work

1. Build temporary databases by applying actual migrations through 0020, 0023,
   and 0027. Seed rows valid for each historical schema, close, reopen, then
   apply the full embedded migration set.
2. At each checkpoint, verify prior data survives and the new MLS/recovery,
   durable push, session lifetime, and call authorization fields/indexes have
   the documented defaults and constraints.
3. Apply the full set a second time and assert no duplicate mutation.
4. Create an in-memory test migration whose SQL creates/mutates an object and
   then fails inside the same migration. Assert both the object/mutation and
   its migration record are absent after the error.
5. Verify a corrected replacement with the same version can subsequently
   apply, and retain the existing checksum-tamper rejection test.

## Acceptance

- All three historical checkpoints upgrade on a reopened database with seeded
  data intact and current invariants present.
- The injected failing migration is atomic with its migration record.
- Reapply/checksum behavior still passes.
- No production migration, schema, or down path changed.

## Required checks

```sh
cd server && go test -race ./internal/storage
cd server && go test ./cmd/messenger-server
```

## Advisor checkpoint

Before any write outside tests, provide the exact historical schema, seed data,
failure SQL, and observed state. Ask whether the fixture models a supported
upgrade and whether a production change belongs in a separate T45A task.

## Handoff

Use the workflow handoff with `Task: QA09`. Name each migration cutoff and
post-upgrade invariant; confirm all migration SQL files are unchanged.

