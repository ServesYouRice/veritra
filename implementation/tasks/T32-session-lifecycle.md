# T32 — Account-scoped session lifecycle

| Field | Contract |
|---|---|
| Consensus source | I32; LOG-03/LOG-04/UI-03/TEST-02/ARCH-06; P11 |
| Initial eligibility | Ready |
| Risk | High release blocker |
| Executor | Strong |
| Advisor | Required on lifecycle/generation design |
| Depends on | — |
| Blocks | T39, T48A, T49C |
| Parallel safety | Do not overlap T30B/T39 or other `AppState` lifecycle work |

## Objective

Make restore, sign-in, sign-out and account switch a deterministic serialized
state machine whose async work cannot commit under the wrong account/origin.

## Read first

- `docs/audit-consensus.md` I32 and named findings.
- `mobile/lib/core/app_state.dart`, `models.dart`, `local_store.dart`,
  `sync_service.dart`, realtime/socket paths and auth UI tests.

## Invariants

- Every post-await commit validates generation and canonical account/origin.
- Teardown is awaited; failed restore never resets a valid cursor.
- Startup exposes `initializing`, `ready` or `recoveryRequired`, not false logout.

## Work

1. Model explicit lifecycle states and ownership identity.
2. Add generation/cancellation checks at every async commit boundary.
3. Await sync/socket teardown and cancel stale startup work.
4. Remove catch-all cursor reset.
5. Add paused-future interleaving tests.

## Acceptance

- No false logged-out flash, old-account write, live socket after teardown or
  cursor mutation after failed restore.
- Canonically different origins/accounts never share local state.

## Required checks

```sh
cd mobile && flutter test test/app_state_test.dart test/encrypted_local_store_test.dart
```

