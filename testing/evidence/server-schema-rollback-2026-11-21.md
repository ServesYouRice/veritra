# Server rollback across a schema change (rehearsal, 2026-11-21)

Closes the STATE "Deploy, untested here: rollback across a schema change" row
as far as a local run can. Not covered: Kubernetes/Flux, a live R2 restore.

## What the server does

`Store.Migrate` applies the migrations it carries and, for every one already
applied, checks the stored checksum. It never looks for applied migrations it
does not carry. So an older binary pointed at a newer database **starts** and
serves; it does not refuse, re-apply or drop anything. Two things were pinned
in tests and one was added:

- `TestMigrateOnANewerDatabaseLeavesUnknownMigrationsAloneAndStillRefusesEdits`
  (`server/internal/storage/migration_checksum_test.go`): newer database plus
  an older migration set starts twice, keeps both rows and the newer
  migration's data, rolls forward again unchanged, and an edited known
  migration is still refused (`checksum mismatch`).
- New: the server logs `database_schema_newer_than_binary` (WARN, names only:
  count, first and newest unknown migration, a hint) at start when the database
  holds migrations the binary does not know
  (`Store.UnknownAppliedMigrations`, `app.warnNewerSchema`;
  `server/internal/app/schema_warning_test.go`). It does not refuse: whether
  the newer migrations were additive is the operator's call (docs/operations.md,
  "Upgrade and rollback"), and a refusal would break the documented Flux revert
  path. Only binaries built from this change onward print it, so a rollback
  to a release older than this one stays silent.

## The rehearsal

`scripts/rehearse-schema-rollback.sh OLD_REV` builds the server at HEAD and at
`OLD_REV`, starts HEAD on a fresh data directory (development mode, loopback),
runs the deployment smoke client's first-run steps (owner setup, login,
attachment, push registration), stops it, starts the OLD binary on the same
data directory (the rollback), runs the smoke client's `verify` (login, old
data intact, new writes) plus a probe that creates a community, then starts
HEAD again and verifies once more. All data is throwaway. Local only, no
network.

| OLD revision | migrations crossed | old binary starts | `verify` on the old binary | community create probe on the old binary | HEAD again |
|---|---|---|---|---|---|
| `d25dfbd` (K1-6, 0081 is the newest) | 0082 to 0094 including 0082 (drops `communities.name` and `channels.name`), 0084 and 0092 (table rebuilds) | yes, `/readyz` 200 | ok | `{}` body: 400. **`{"name": ...}` body: HTTP 500** (the column is gone) | ok, 201 |
| `8eb373f` (0093 is the newest) | 0094 only (new tables and triggers) | yes | ok | same as HEAD (201 / 400) | ok |
| `e9aef04` (before 8eb373f) | 0090 to 0094 | **no**: `migration 0090_l2_sealed_tokens.sql checksum mismatch` | n/a | n/a | ok |

## Findings

1. **A rollback across a non-additive migration starts, passes health and the
   smoke checks, and then fails on the routes whose tables changed** (500 on
   community create at `d25dfbd`; only the access log shows it, the server
   logs no error line). `/readyz` and a login/attachment check do not detect
   it. The operations rule stands: across an incompatible migration restore
   the matching pre-upgrade backup (below the table). With this change a
   release carrying the new warning tells the operator at the next rollback.
2. **Two byte-different versions of an applied migration existed.** Commit
   `8eb373f` made `0090_l2_sealed_tokens.sql` and
   `0091_l2_sealed_envelopes.sql` byte-identical to the sealed branch's, which
   differs from the earlier text by one comment word each ("D123" to "D122").
   The checksum covers the whole file, so a database migrated by a build from
   the other line refuses to start on the current code (`checksum mismatch`),
   the third row above. Nothing was released and there are no real
   deployments (D55), so nothing is stranded; but a comment-only edit to a
   migration is still a schema change to the checker. A test that pins the
   checksums of the migrations already on `main` would catch the next one.
3. Rolling forward again after a rollback worked in every row: nothing is
   lost, because the older binary adds no schema of its own.

## Reproduce

```
GOCACHE=<dir> scripts/rehearse-schema-rollback.sh d25dfbd <workdir>
```

Each run prints one block like the table row. Revisions with fewer migrations
than HEAD whose migration files are a strict subset of HEAD's are needed:
`0080_retire_backup_recovery_tokens.sql` (renumbered to 0081 later) makes the
old binary apply a migration HEAD never knew, which the first attempt showed
(applied count 75 against HEAD's 74).
