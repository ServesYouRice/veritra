# QA06 — Test server push provider contracts

| Field | Contract |
|---|---|
| Confirmed source | `testing/review_findings.md` M3 at `3ee785d` |
| Canonical owner | T41 provider/platform readiness |
| Routing snapshot (board wins) | Blocked until I41 is eligible under D03 and I36 |
| Risk | High conditional push/privacy boundary |
| Executor | Balanced+advisor |
| Advisor | Required before adding a network seam or changing error classes |
| Depends on | Eligible T41 claim |
| Blocks | Trustworthy T41 and G24 push evidence |
| Parallel safety | Server push package only; may run beside QA08, not QA07 if helpers overlap |

## Objective

Prove FCM, APNs, and WebPush request construction, bounded responses, token
caching, target validation, and permanent/transient error classification
without making real provider or DNS requests.

## Read first

- `docs/audit-consensus.md` I41 and `implementation/tasks/T41-push-platform.md`.
- `server/internal/push/push.go`, `native.go`, and `push_test.go`.
- App delivery classification in `server/internal/app/app.go` so provider
  errors match QA07 expectations.

## Confirm first

Verify the current push tests only assert `GenericPayload` (or otherwise omit
the acceptance matrix below). If focused provider tests now cover it, return
`stale`. Do not claim I41 while its board dependency remains blocked.

## Allowed write set

- `server/internal/push/*_test.go`.
- `server/internal/push/push.go` and `native.go` only for a minimal deterministic
  test seam or a defect reproduced by the tests and approved by the advisor.

No provider SDK/dependency, network call, config format, log field, or payload
feature may be added.

## Invariants

- Payloads remain generic: no sender, message, conversation, endpoint, token,
  auth secret, or ciphertext.
- Tests use generated synthetic signing keys and injected HTTP transports.
- Private, loopback, link-local, multicast, unspecified, credentialed, redirect,
  and malformed WebPush targets fail before connection.
- `ErrSubscriptionGone` is permanent; rate limit, timeout, cancellation, and
  provider 5xx remain retryable unless the existing contract says otherwise.

## Work

1. Generate RSA/EC test keys in memory; cover empty/partial/invalid provider
   configuration without embedding credentials.
2. For FCM, inspect OAuth and message requests, generic data body, headers,
   bounded malformed responses, token reuse, near-expiry refresh, invalid
   target, gone/unregistered, rate-limit, 5xx, and cancellation.
3. For APNs, inspect host selection, topic/push-type/priority/collapse headers,
   generic background body, JWT reuse, invalid target, gone/bad-device-token,
   rate-limit, 5xx, and cancellation.
4. For WebPush, cover key/auth/URL bounds, forbidden address classes and
   redirects, gone statuses, non-success statuses, concurrency cancellation,
   and the generic payload. Stub resolution/dialing only if needed; never use
   the public network.
5. Add a router matrix for missing, mismatched, and configured providers.

## Acceptance

- The provider matrix is deterministic, offline, and race-safe.
- Exact generic request content and required headers are asserted.
- Permanent invalid/gone targets are distinguishable from transient failures.
- Token/JWT caches refresh at their current safe boundary without leaking
  values.
- `go test -race` passes and no dependency was added.

## Required checks

```sh
cd server && go test -race ./internal/push
cd server && go test ./internal/app ./internal/httpapi
```

## Advisor checkpoint

Before a production seam or error-class change, provide the failing provider
fixture and downstream QA07 outcome. Ask whether the change preserves SSRF,
generic-payload, retry, and secret-handling boundaries.

## Handoff

Use the workflow handoff with `Task: QA06`. List provider/status cases, confirm
zero external requests, and state whether production code changed.
