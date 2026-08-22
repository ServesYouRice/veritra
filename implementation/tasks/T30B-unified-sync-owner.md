# T30B — One account-scoped sync owner

| Field | Contract |
|---|---|
| Consensus source | I30 final; LOG-01, ARCH-01, TEST-01, PERF-08 |
| Initial eligibility | After T30A |
| Risk | Critical release blocker |
| Executor | Strong |
| Advisor | Required on transaction/state-machine design and final adversarial review |
| Depends on | T30A |
| Blocks | T33, T49C |
| Parallel safety | Do not overlap T32/T33/T39 or other `AppState`/local-store work |

## Objective

Create one account-scoped engine that owns ordered events, dedupe, affected
ciphertext, MLS state and cursor commit as one durable unit.

## Read first

- `docs/audit-consensus.md` I30.
- LOG-01/ARCH-01/TEST-01/PERF-08 source sections.
- `mobile/lib/core/app_state.dart`, `mobile/lib/sync/sync_service.dart`,
  `mobile/lib/storage/local_store.dart`, `encrypted_database.dart`, crypto service interfaces.

## Invariants

- Cursor advancement cannot outrun ciphertext persistence or MLS state.
- One account/origin owns each transaction; background/foreground never race.
- Missing crypto fails closed.

## Work

1. Specify event transaction/state ownership and commit boundaries.
2. Move all cursor mutation behind one serialized account-scoped engine.
3. Apply event dedupe, affected message state and MLS state atomically.
4. Coalesce foreground, realtime and wake-triggered catch-up.
5. Add deterministic interruption tests at every commit boundary.

## Acceptance

- Plain and MLS pages, duplicates, restart, cursor expiry, overlap and account
  switch cannot skip or cross-account-commit work.
- Incremental events do not require broad snapshot rewrites without evidence.

## Required checks

```sh
cd mobile && flutter test test/app_state_test.dart test/encrypted_local_store_test.dart test/app_payload_test.dart
```

## Advisor checkpoint

Ask for a counterexample review of atomicity, cancellation, dedupe and crash
boundaries before coding and against the final diff.

