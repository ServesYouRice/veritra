# T46 — Supported deployment hardening

| Field | Contract |
|---|---|
| Consensus source | I46; DEP-03/DEP-07/DEP-08/DEP-11; R4/R9 |
| Routing snapshot (board wins) | Prepared |
| Risk | Medium; required for “supported deployment” claim |
| Executor | Balanced+advisor |
| Advisor | Review artifact trust, secret delivery and sandbox compatibility |
| Depends on | Release blockers; coordinate T40B/T45B |
| Blocks | Supported Compose/systemd claim |
| Parallel safety | One owner for deploy files and instance-lock resource identity |

## Objective

Make supported Compose/systemd consume the tested attested image, lock actual
DB/blob resources, use file-based secrets, reconcile deadlines and run under a
compatible least-privilege profile.

## Read first

- `docs/audit-consensus.md` I46.
- Named Codex/Opus findings.
- `deploy/`, `server/Dockerfile`, `server/cmd/messenger-server/instance_lock.go`,
  config, release workflow and deployment tests.

## Invariants

- Supported production Compose does not rebuild mutable source.
- Secrets do not appear in logs/config dumps; no broad filesystem capability.
- Hardening cannot break SQLite/local-blob writes, backup, restore, push or TURN.

## Work

1. Consume a versioned digest produced/tested by release.
2. Canonicalize and lock actual overridden DB/blob resources.
3. Add file-secret support and migrate supported examples.
4. Reconcile shutdown/drain/upload timeouts.
5. Add compatible `cap_drop`, read-only filesystem and systemd restrictions.

## Acceptance

- Supported paths use tested digest and reject overlapping ownership.
- Secret sentinels stay out of logs/config dumps.
- Full hardened startup/upload/backup/restore/push/TURN smoke passes.

## Required checks

```sh
cd server && go test ./cmd/messenger-server ./internal/app
./scripts/test.sh
```
