# QA07 — Test durable push delivery outcomes

| Field | Contract |
|---|---|
| Confirmed source | `testing/review_findings.md` M3 at `3ee785d` |
| Canonical owner | T41 delivery verification; implemented T36B job store |
| Initial eligibility | Blocked until I41 is eligible under D03 and I36 |
| Risk | High conditional durability/privacy boundary |
| Executor | Balanced+advisor |
| Advisor | Required before changing retry timing, leases, or store interfaces |
| Depends on | Eligible T41; QA06 error contract |
| Blocks | Trustworthy T41/G24 wake delivery evidence |
| Parallel safety | One owner for `internal/app` push-worker tests and related seams |

## Objective

Prove that `drainPushWakeBatch`/`deliverPushWake` map every provider outcome to
the correct complete, retry, retire, abandon, metric, and privacy-safe log
behavior while respecting concurrency and cancellation.

## Read first

- `docs/audit-consensus.md` I36/I41 and T36B/T41 contracts.
- `server/internal/app/app.go` push worker, app metrics tests, the push provider
  interface, and `server/internal/storage/push_wake_store.go` plus its tests.

## Confirm first

Verify storage claim/retry tests exist but no focused app test invokes
`drainPushWakeBatch` or `deliverPushWake`. If an app-level suite now covers all
outcomes below, return `stale`. Respect the I41 board block.

## Allowed write set

- New `server/internal/app/push_wake_test.go` and narrow app test helpers.
- `server/internal/app/app.go` only for a deterministic seam or reproduced
  defect approved by the advisor.
- Storage test helpers, but not migrations or production storage semantics.

Do not change provider payloads/configuration, retry limits, metrics schema, or
logs merely to make assertions convenient.

## Invariants

- Successful delivery completes exactly one current leased job.
- Invalid/gone targets retire the subscription; transient failures retry with
  bounded backoff; stale/missing subscriptions are abandoned.
- Parent cancellation does not convert work into success or permanent loss.
- Logs and metric labels contain no endpoint, token, auth secret, account,
  device, message, conversation, or ciphertext identifier.
- Tests use direct calls/channels and controlled providers, not long sleeps.

## Work

1. Build a table-driven fake provider returning success,
   `ErrSubscriptionGone`, `ErrInvalidTarget`, transient error, timeout, and
   parent cancellation.
2. Seed real temporary SQLite jobs and call the worker directly. Assert job and
   subscription state after each outcome, including refresh-not-found and
   completion/retry/retire failures that the existing interfaces can inject.
3. Measure concurrent sends with a blocking fake and prove the configured
   worker bound is never exceeded and cancellation releases workers.
4. Assert attempted/delivered/failed/abandoned counters for each outcome.
5. Capture `slog` output with sentinel endpoint/token/auth values and prove none
   appear even on claim, refresh, completion, retirement, and retry errors.

## Acceptance

- Every provider outcome has one deterministic durable-state assertion.
- Retry/retire/complete behavior matches QA06 error classes and never loses a
  transient job silently.
- Concurrency stays bounded and the race detector passes.
- Privacy sentinels are absent from logs and labels.
- No timing constant or durable schema changed without approval.

## Required checks

```sh
cd server && go test -race ./internal/app ./internal/storage ./internal/push
```

## Advisor checkpoint

Before altering app/store production code, send the failing state transition,
lease/attempt values, and proposed seam or fix. Ask for cancellation and
duplicate-delivery counterexamples.

## Handoff

Use the workflow handoff with `Task: QA07`. Report the outcome/state matrix and
the exact privacy sentinels checked, without printing their generated values.
