# T30A — Contain background sync data loss

| Field | Contract |
|---|---|
| Consensus source | I30 interim; LOG-01, TEST-01 |
| Initial eligibility | Ready |
| Risk | Critical release blocker |
| Executor | Balanced+advisor |
| Advisor | Review wake-marker/cursor behavior before final diff |
| Depends on | — |
| Blocks | T30B |
| Parallel safety | Do not overlap T30B/T32; all touch mobile lifecycle state |

## Objective

Stop background push from advancing the durable cursor past plain messages or
MLS work. Background execution becomes a bounded wake signal only.

## Read first

- `docs/audit-consensus.md` I30.
- `docs/audits-codex/logical-issues.md` LOG-01 and
  `docs/audits-codex/testing-gaps.md` TEST-01.
- `mobile/lib/push/background_push.dart`, `mobile/lib/storage/local_store.dart`,
  `mobile/lib/core/app_state.dart`, related mobile tests.

## Invariants

- Background work never commits a cursor without committing every affected
  envelope/MLS state.
- `full_resync_required` never authorizes a blind cursor jump.

## Work

1. Add a regression test proving current normal-page message loss.
2. Replace background catch-up mutation with a durable, idempotent wake marker.
3. Make foreground ownership consume/coalesce that marker safely.
4. Cover repeated pushes, process restart and expired cursor.

## Acceptance

- Background normal pages and full-resync responses discard no envelope.
- Background execution never changes the durable sync cursor.
- Repeated wakes coalesce and foreground sync resumes once.

## Required checks

```sh
cd mobile && flutter test test/app_state_test.dart test/encrypted_local_store_test.dart
```

