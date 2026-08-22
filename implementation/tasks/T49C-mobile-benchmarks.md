# T49C — Mobile state and render benchmarks

| Field | Contract |
|---|---|
| Consensus source | I49 mobile scope; PERF-09/ARCH-02/NTH-15; P5/P6/P8/U9/U10 |
| Initial eligibility | Measure after lifecycle/sync correctness |
| Risk | Conditional on measured device limits |
| Executor | Balanced |
| Advisor | Before broad state decomposition or persistence migration |
| Depends on | T30B, T32 |
| Blocks | Evidence-backed mobile refactor child tasks |
| Parallel safety | Profiling is read-only; resulting tasks must not overlap active AppState work |

## Objective

Measure root rebuilds, theme recreation, per-bubble lookups, repair merges and
tab-state loss on representative low-end devices before decomposing state.

## Read first

- `docs/audit-consensus.md` I49.
- Named source findings.
- `mobile/lib/main.dart`, `app_state.dart`, `app_shell.dart`, chat screens,
  theme and relevant widget tests.

## Invariants

- T30B/T32 account ownership and atomicity outrank render optimization.
- Preserve tab/history state and crypto-gated honesty.
- No broad architecture rewrite without profile evidence and rollback.

## Work

1. Define seeded conversations/messages and frame/rebuild/write targets.
2. Profile startup, sync burst, scrolling, repair and tab switch.
3. Identify exact rebuild/lookup/write causes.
4. Create small child tasks with before/after profile and correctness tests.

## Acceptance

- Profiles are reproducible and bound to device/toolchain/commit.
- Each proposed refactor names a target, invariant and rollback.
- No optimization is marked complete from widget-test timing alone.

## Required checks

```sh
cd mobile && flutter test
cd mobile && flutter analyze
```

