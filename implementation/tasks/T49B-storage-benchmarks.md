# T49B — Blob, quota and storage-layout benchmarks

| Field | Contract |
|---|---|
| Consensus source | I49 storage scope; PERF-06/PERF-07/NTH-16; P1/P3/P9/S5 |
| Routing snapshot (board wins) | Measure after correctness blockers |
| Risk | Conditional; S5 may require admission hardening |
| Executor | Balanced+advisor |
| Advisor | Required before changing integrity verification, quota accounting or blob layout |
| Depends on | T35 correctness; T47 targets where available |
| Blocks | Evidence-backed storage child tasks |
| Parallel safety | Benchmark read-only; do not overlap T35/T45 storage migrations |

## Objective

Measure blob verification/range I/O, quota transaction scans, pre-admission
disk use and directory reconciliation before selecting any optimization.

## Read first

- `docs/audit-consensus.md` I49.
- Named source findings.
- Upload/local blob implementation, content quota store, blob reconciliation,
  migrations and storage tests.

## Invariants

- Integrity verification cannot be weakened for speed.
- Quota is enforced before unbounded body/disk use and remains race-safe.
- Local blobs remain the supported design until measured evidence says otherwise.

## Work

1. Benchmark full/range download, upload admission, quota SQL and directory sweep.
2. Record disk, CPU, query plans and correctness invariants.
3. Create one child task per missed target with migration and rollback.
4. Include adversarial oversized/concurrent uploads in the admission decision.

## Acceptance

- Reproducible baselines and explicit targets exist for every named path.
- Any proposed cache/index/layout keeps checksum and quota correctness.
- No implementation lands solely from speculative audit severity.

## Required checks

```sh
cd server && go test -run '^$' -bench . -benchmem ./internal/storage ./internal/uploads
```
