# T49A — Server read-model and write-lock benchmarks

| Field | Contract |
|---|---|
| Consensus source | I49 server scope; PERF-01/PERF-04/ARCH-05; L13/P2/P4/P7 |
| Routing snapshot (board wins) | Measure after correctness blockers |
| Risk | Conditional on measured limits |
| Executor | Balanced |
| Advisor | Only before schema/read-model migration or architectural replacement |
| Depends on | Correctness tasks and T47 datasets/targets where available |
| Blocks | Evidence-backed optimization child tasks |
| Parallel safety | Read-only benchmarks may run in parallel; one owner per resulting write surface |

## Objective

Measure conversation reads, sync bounds, realtime registration, device-seen
writes and typing-state growth; create a child implementation task only where a
named target is missed.

## Read first

- `docs/audit-consensus.md` I49 performance rule.
- Named source findings.
- Conversation/sync/device storage, realtime hub, typing paths and existing tests.

## Invariants

- Benchmark first; retain SQLite/modular monolith absent measured failure.
- Dataset, hardware/toolchain and query plan are recorded.
- Optimization preserves authorization, durability and retention semantics.

## Work

1. Define representative small/large datasets and latency/lock targets.
2. Benchmark/query-plan each named path before changes.
3. For every missed target, create one child task with invariant, migration,
   rollback and before/after benchmark.
4. Apply only small proven indexes/caches within an approved child task.

## Acceptance

- Every named path has reproducible baseline and target.
- No unmeasured stack replacement or broad refactor lands under this task.
- Child tasks are independent and trace back to I49 IDs.

## Required checks

```sh
cd server && go test -run '^$' -bench . -benchmem ./internal/storage ./internal/realtime
```
