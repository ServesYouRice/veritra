# T37B — Credential rate limits and bounded backoff tables

| Field | Contract |
|---|---|
| Consensus source | I37 limiter scope; SEC-04/SEC-07; S3/S9 |
| Initial eligibility | Ready |
| Risk | High for reauth; Medium lockout/availability |
| Executor | Strong |
| Advisor | Required on abuse model and fail-open/fail-closed behavior |
| Depends on | — |
| Blocks | Safe privileged actions |
| Parallel safety | One owner for auth routing, login backoff and limiter tables |

## Objective

Put reauthentication under a strict credential budget and make bounded
backoff/rate-limit storage resist table pressure without global lockout or fail-open.

## Read first

- `docs/audit-consensus.md` I37.
- SEC-04/SEC-07 and S3/S9.
- `server/internal/httpapi/api.go`, `auth_handlers.go`, `login_backoff.go`,
  app rate limiter and tests.

## Invariants

- Do not label metrics with username, token, IP or device identifiers.
- Table pressure cannot disable all new entries or bypass existing backoff.
- Error/timing behavior does not reveal credential validity.

## Work

1. Classify reauth as a credential endpoint with per-session/account/source budget.
2. Fix full-table sweep/eviction and insertion behavior.
3. Bound global limiter storage without refusing every new client.
4. Meter anonymous occupancy/evictions and add adversarial tests.

## Acceptance

- Reauth stays within documented CPU/guessing budget.
- Sustained table pressure neither fails open nor locks out all new users.
- Reset/expiry behavior remains correct.

## Required checks

```sh
cd server && go test ./internal/httpapi ./internal/app
```

