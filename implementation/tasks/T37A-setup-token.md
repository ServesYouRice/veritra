# T37A — Setup-token entropy and comparison

| Field | Contract |
|---|---|
| Consensus source | I37 setup scope; S1/S10 |
| Initial eligibility | Ready |
| Risk | High setup blocker |
| Executor | Balanced+advisor |
| Advisor | Review entropy/encoding and fixed-size comparison |
| Depends on | — |
| Blocks | Secure first-run deployment |
| Parallel safety | Coordinate config/auth-handler edits with T37B |

## Objective

Generate at least 32 random bytes, validate decoded entropy rather than string
length, reject placeholders and compare a fixed-size representation.

## Read first

- `docs/audit-consensus.md` I37.
- `docs/audits-opus/security-issues.md` S1/S10.
- `server/internal/config/config.go`, setup/auth handlers, config/auth tests,
  deployment examples and operations docs.

## Work

1. Define one supported encoding and decoded minimum.
2. Reject malformed, weak and known placeholder production tokens at startup.
3. Update generation guidance to use a CSPRNG with at least 32 bytes.
4. Compare fixed-size hashes in constant time.

## Acceptance

- Weak/malformed/placeholder tokens fail startup.
- Generated valid tokens work; length differences do not create a comparison oracle.

## Required checks

```sh
cd server && go test ./internal/config ./internal/auth ./internal/httpapi
```

