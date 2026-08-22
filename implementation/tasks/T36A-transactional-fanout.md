# T36A — Transactional fanout recipients

| Field | Contract |
|---|---|
| Consensus source | I36 minimal fix; LOG-07, L4 |
| Initial eligibility | Ready |
| Risk | High when push is enabled |
| Executor | Balanced+advisor |
| Advisor | Review commit/failure boundary |
| Depends on | — |
| Blocks | T36B |
| Parallel safety | Do not overlap T36B message/fanout interface changes |

## Objective

Remove the post-commit recipient lookup failure window by returning the
authorized recipient set from the transaction that commits message and event.

## Read first

- `docs/audit-consensus.md` I36.
- LOG-07 and Opus L4.
- `server/internal/messaging/service.go`, message/content stores,
  HTTP message handlers, push interfaces and tests.

## Invariants

- The server still stores ciphertext only.
- Recipient data is authorization output, not durable push work; T36B still
  supplies crash-after-commit durability.

## Work

1. Reproduce injected post-commit lookup failure.
2. Return recipients from the commit transaction/service result.
3. Remove the redundant post-commit lookup.
4. Preserve idempotency and authorization behavior.

## Acceptance

- Injected lookup failure cannot produce committed message plus lost recipients.
- Existing send/idempotency/authorization tests pass.

## Required checks

```sh
cd server && go test ./internal/messaging ./internal/httpapi ./internal/storage
```

