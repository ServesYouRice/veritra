# T34 — Reliable MLS control outbox

| Field | Contract |
|---|---|
| Consensus source | I34; LOG-06, TEST-03 MLS scope; L3 |
| Initial eligibility | Blocked until T31 worker pattern exists |
| Risk | High release blocker |
| Executor | Strong |
| Advisor | Required on per-group ordering and terminal semantics |
| Depends on | T31 pattern |
| Blocks | Safe MLS transition/revocation delivery |
| Parallel safety | Do not overlap message-outbox storage changes without coordination |

## Objective

Deliver MLS control work durably and in group order; a terminal item fails only
its affected group/device closed while unrelated groups continue.

## Read first

- `docs/audit-consensus.md` I34.
- LOG-06/TEST-03 and Opus L3.
- Mobile MLS outbox code in `app_state.dart`, `local_store.dart`, crypto service,
  API client; server MLS handlers/stores.

## Invariants

- Never delete a terminal control item merely to unblock later same-group work.
- Existing revocation drains before another transition.
- Retries are durable, bounded and serialized by affected group.

## Work

1. Reuse T31 worker states without conflating application and MLS policy.
2. Persist attempts/next retry and classify terminal errors.
3. Isolate failed groups while scheduling unrelated groups.
4. Add connectivity/timer wake and revocation restart handling.

## Acceptance

- Transient/permanent/restart/revocation tests preserve order and transitions.
- Failed group enters recoverable closed state; unrelated group progresses.
- No unhandled future or duplicate transition.

## Required checks

```sh
cd mobile && flutter test test/app_state_test.dart test/encrypted_local_store_test.dart
cd server && go test ./internal/httpapi ./internal/storage
```

