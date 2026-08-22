# T29 — Recovery capability secrecy and lifecycle

| Field | Contract |
|---|---|
| Consensus source | I29; SEC-01, SEC-08, S2 |
| Initial eligibility | Ready, first |
| Risk | High release blocker |
| Executor | Strong |
| Advisor | Required after protocol sketch and before final diff |
| Depends on | — |
| Blocks | T40A sequencing; T45A/T45C |
| Parallel safety | Run alone until the live leak is contained; overlaps HTTP logging, auth and backup storage |

## Objective

Remove recovery capabilities from URLs/logs and give them an explicit,
resumable but bounded lifecycle without exposing backup plaintext or keys.

## Read first

- `docs/audit-consensus.md` I29 and SEC-01 correction.
- `docs/audits-codex/security-issues.md` SEC-01/SEC-08.
- `docs/audits-opus/security-issues.md` S2.
- `server/internal/httpapi/api.go`, `content_handlers.go`.
- `server/internal/app/app.go`, `server/internal/storage/content_store.go`.
- Relevant HTTP/storage tests and `deploy/caddy/Caddyfile`.

## Invariants

- Never log token, request body, ciphertext body or decryption material.
- An interrupted ranged download remains resumable only inside the approved
  short-lived exchange; do not consume the capability before safe completion.
- Credential routes use strict rate limiting and fixed route patterns.

## Work

1. Reproduce the sentinel leak in current code.
2. Replace the path capability with a fixed route and header credential.
3. Use matched `r.Pattern` logging with constant `unmatched` fallback.
4. Implement expiry plus replay/rotation semantics compatible with resume.
5. Add incident guidance for capability rotation and log purge.
6. Test application and configured proxy logs with sentinel values.

## Acceptance

- Sentinel capability appears in no URL, application/proxy log or error.
- Old, expired and replayed capabilities fail.
- Interrupted approved transfers can resume; unauthorized reuse cannot.
- The fixed route is credential-rate-limited.

## Required checks

```sh
cd server && go test ./internal/httpapi ./internal/storage ./internal/app
./scripts/test-api-contracts.sh
```

## Advisor checkpoint

Ask whether the proposed exchange is replay-safe, range-safe and race-safe, and
for counterexamples around completion, restart, concurrent requests and expiry.

