# T33 — Poison-event and stale-device recovery

| Field | Contract |
|---|---|
| Consensus source | I33; LOG-08/PERF-03; L2/L9 |
| Routing snapshot (board wins) | Blocked by T30B |
| Risk | High release blocker |
| Executor | Strong |
| Advisor | Required for tombstone/recovery policy and MLS fail-closed review |
| Depends on | T30B |
| Blocks | Credible offline/reconnect behavior |
| Parallel safety | One owner for sync event classification and repair APIs |

## Objective

Prevent poison events from wedging catch-up without skipping MLS control work,
batch repair amplification, and surface an explicit stale-device recovery path.

## Read first

- `docs/audit-consensus.md` I33.
- Named Codex/Opus findings.
- `mobile/lib/core/app_state.dart`, `api_client.dart`, sync models/services;
  server sync/message handlers and storage as required.

## Invariants

- Missing/malformed/unavailable MLS control enters `recoveryRequired` without
  cursor advancement.
- Only a proven-expired application envelope may follow a documented tombstone.
- Network/auth/MLS-state failures never advance.

## Work

1. Define typed per-event failure classes and durable recovery states.
2. Implement safe tombstone policy only for proven-expired application data.
3. Add bounded deduplicated repair instead of per-event requests.
4. Map expired cursor to `device_recovery_required` and approved recovery choices.
5. Test malformed, missing, network, auth, duplicate and stale-device cases.

## Acceptance

- Tests prove no loop and no skipped MLS work.
- Reconnect bursts use bounded batch repair.
- Expired devices require relink/state transfer/backup, never a cursor jump.

## Required checks

```sh
cd mobile && flutter test test/app_state_test.dart test/api_contract_test.dart
cd server && go test ./internal/httpapi ./internal/storage
```
