# T44A — Bounded API decoding and contained stale/error state

| Field | Contract |
|---|---|
| Consensus source | I44 API/state scope; LOG-13/SEC-10/UI-09/UI-10/NTH-08/NTH-11; L8/L11/L14/L15 |
| Initial eligibility | Prepared; claim after release blockers |
| Risk | Mixed Medium/Low |
| Executor | Balanced |
| Advisor | Only if API-schema or security boundary changes |
| Depends on | Release blockers or an explicit prerequisite need |
| Blocks | Stable client error contract |
| Parallel safety | Coordinate API client/AppState edits with T30-T33 and T44B |

## Objective

Give every server error a bounded typed client path, cap pagination/decoding,
and contain refresh/search failures without raw errors or global stale-state loss.

## Read first

- `docs/audit-consensus.md` I44.
- Named source findings.
- `mobile/lib/core/api_client.dart`, `errors.dart`, `models.dart`, `app_state.dart`,
  search/device screens, API contract tests and server error writers.

## Invariants

- Never surface raw stack/implementation errors or log response/ciphertext bodies.
- Binary/error reads and paging loops have explicit limits.
- A local refresh failure preserves last known safe state and exposes retry.

## Work

1. Inventory server error codes and define shared typed mappings.
2. Bound error/download bodies, casts, time parsing and pagination iterations.
3. Contain search/device refresh failures with stale/error state and retry.
4. Add versioned API contract fixtures and drift checks.

## Acceptance

- Every server code has a client mapping or deliberate generic class.
- Malformed/binary/oversized responses and paging caps fail predictably.
- Raw implementation errors never reach user UI.

## Required checks

```sh
cd mobile && flutter test test/api_contract_test.dart test/app_state_test.dart test/ui_actionable_test.dart
./scripts/test-api-contracts.sh
```

