# T38 — Safe account export

| Field | Contract |
|---|---|
| Consensus source | I38; SEC-02/NTH-19; H3 |
| Initial eligibility | Ready |
| Risk | High release blocker |
| Executor | Strong |
| Advisor | Review exported schema and reusable-secret exclusions |
| Depends on | — |
| Blocks | Trustworthy user data controls |
| Parallel safety | Coordinate recent-auth/session changes with T37B/T37C |

## Objective

Require recent authentication, exclude every reusable credential and expose a
versioned export whose message content remains ciphertext.

## Read first

- `docs/audit-consensus.md` I38.
- `docs/audits-codex/security-issues.md` SEC-02 and NTH-19.
- Account export handler/store, auth middleware, mobile download path and tests.

## Invariants

- Never export push `auth_secret`, bearer/session/recovery secrets or plaintext.
- Never log export body, ciphertext body or dynamic capability.

## Work

1. Enumerate export fields and classify reusable secrets.
2. Require `withRecentAuth` and emit a privacy-minimized audit event.
3. Version/document the schema and ciphertext semantics.
4. Bound/download safely on mobile without logging payloads.

## Acceptance

- Bearer-only requests fail without recent auth.
- Fixtures prove no reusable secret is present.
- Schema, authorization and mobile download tests pass.

## Required checks

```sh
cd server && go test ./internal/httpapi ./internal/storage
cd mobile && flutter test test/api_contract_test.dart
```

