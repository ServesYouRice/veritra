# T36B — Durable, bounded generic wake jobs

| Field | Contract |
|---|---|
| Consensus source | I36 full fix; PERF-02/ARCH-03/NTH-14; P10 |
| Initial eligibility | After T36A |
| Risk | High when push is enabled |
| Executor | Strong |
| Advisor | Required on transactional outbox, privacy and retry design |
| Depends on | T36A |
| Blocks | T41, T47 |
| Parallel safety | One owner for message commit, wake schema and push workers |

## Objective

Persist privacy-minimized wake work transactionally and deliver it through
bounded provider workers that survive restart and partial provider failure.

## Read first

- `docs/audit-consensus.md` I36.
- PERF-02/ARCH-03/NTH-14 and Opus P10.
- Message service/storage, `server/internal/push/`, app worker lifecycle,
  migrations and metrics tests.

## Invariants

- Wake payloads are generic: no message text, sender name, token in logs or
  ciphertext body.
- Keep the modular monolith/SQLite design; no new service by default.
- Work is deduplicated, expiring, retryable and bounded.

## Work

1. Design a transactional wake outbox keyed by idempotent event/recipient.
2. Commit eligible work with the message/event transaction.
3. Add bounded per-provider workers, deadlines, retries, expiry and metrics.
4. Resume on restart and isolate partial provider failure.

## Acceptance

- Crash after message commit preserves eligible wake work.
- A 100-target burst stays within documented goroutine/socket bounds.
- Restart and partial provider failure converge without duplicate content leaks.

## Required checks

```sh
cd server && go test ./internal/messaging ./internal/push ./internal/storage ./internal/app
```

