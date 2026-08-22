# T35 — Retention and attachment-prune convergence

| Field | Contract |
|---|---|
| Consensus source | I35; LOG-05/PERF-05; L5/L6 |
| Initial eligibility | Ready |
| Risk | High release blocker |
| Executor | Balanced+advisor |
| Advisor | Review transaction/materialization and cancellation bounds |
| Depends on | — |
| Blocks | T47 final evidence |
| Parallel safety | One owner for prune SQL, blob reconciliation and retention metrics |

## Objective

Drain eligible retention work in bounded yielding loops and use one stable
message set for message, attachment-link and blob deletion.

## Read first

- `docs/audit-consensus.md` I35.
- LOG-05/PERF-05 and L5/L6.
- `server/internal/storage/content_store.go`, blob deletion store,
  `server/internal/app/app.go`, migrations 0005/0007/0009/0019 and tests.

## Invariants

- Do not rewrite sync/audit pruning that already drains.
- Cancellation remains prompt; loops have work/time ceilings.
- Blob deletion cannot outpace surviving attachment rows.

## Work

1. Materialize one message-ID set per prune transaction.
2. Drain the four named non-draining paths in bounded yielding loops.
3. Add required indexes only with query evidence.
4. Export privacy-safe backlog count/age metrics.
5. Test 1,200-row and sustained-ingest convergence.

## Acceptance

- One scheduled sweep drains 1,200 eligible rows per class.
- Cancellation stops promptly and attachment/blob state stays consistent.
- Sustained ingest remains below a documented backlog target.

## Required checks

```sh
cd server && go test ./internal/storage ./internal/app
```

