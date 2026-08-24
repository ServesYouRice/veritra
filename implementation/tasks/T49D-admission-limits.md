# T49D — Evidence-backed per-account admission limits

| Field | Contract |
|---|---|
| Consensus source | I49 admission/architecture scope; NTH-16; S6 |
| Routing snapshot (board wins) | Measure, then decide |
| Risk | Security/availability conditional |
| Executor | Strong |
| Advisor | Required on abuse model, defaults and migration behavior |
| Depends on | T47 capacity contract |
| Blocks | Defensible account creation limits |
| Parallel safety | One owner for account-level quotas and creation transactions |

## Objective

Use measured host capacity and abuse scenarios to define race-safe per-account
conversation/community/channel limits without changing the storage architecture.

## Read first

- `docs/audit-consensus.md` I49 decision rule and reconciled source IDs
  S6/NTH-16.
- Conversation/community creation handlers/stores, config and T47 evidence.

## Invariants

- Limits are enforced transactionally and do not reveal other accounts' state.
- Defaults are derived from supported host tiers, not arbitrary audit numbers.
- Operators get bounded configuration and privacy-safe metrics.

## Work

1. Model resource/abuse cost using T47 datasets.
2. Propose defaults, maximums and operator override bounds.
3. Obtain advisor/coordinator approval before implementation.
4. Implement atomic admission and typed client errors with race tests.

## Acceptance

- Decision record links measured capacity to defaults.
- Concurrent creates cannot exceed limit or corrupt uniqueness.
- Client/operator errors are actionable without identifier leakage.

## Required checks

```sh
cd server && go test ./internal/httpapi ./internal/storage
```
