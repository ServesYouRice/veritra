# T37C — Password cost migration and session rotation

| Field | Contract |
|---|---|
| Consensus source | I37 hardening scope; S4/S11 |
| Initial eligibility | Ready, noncritical subtask |
| Risk | Medium |
| Executor | Strong |
| Advisor | Required before changing KDF/session policy |
| Depends on | — |
| Blocks | Long-lived credential hardening |
| Parallel safety | Coordinate auth schema/handler changes with T37B/T38 |

## Objective

Provide a benchmarked password-cost migration path and rotate long-lived
sessions under explicit idle/absolute lifetime rules.

## Read first

- `docs/audit-consensus.md` I37.
- `docs/audits-opus/security-issues.md` S4/S11.
- `server/internal/auth/`, auth handlers, session storage/migration and tests.

## Invariants

- Do not switch KDFs without migration, rollback and measured device/server cost.
- Rotation cannot create two indefinitely valid credentials or break revocation.

## Work

1. Benchmark current password verification and define target cost.
2. Add versioned rehash-on-success or equivalent migration.
3. Define idle and absolute session limits plus rotation/revocation semantics.
4. Test legacy hash migration, concurrent rotation, expiry and revoked sessions.

## Acceptance

- Existing credentials migrate without plaintext handling.
- Old rotated/revoked sessions fail; valid active sessions transition safely.
- Performance target and residual risk are documented.

## Required checks

```sh
cd server && go test ./internal/auth ./internal/httpapi ./internal/storage
```

