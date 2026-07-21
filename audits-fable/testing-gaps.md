# Testing Gaps

Current state: Go tests (~2,100 lines incl. race-enabled CI), 13 Rust tests, 34 Flutter tests, compose smoke job, gofmt/vet/clippy/analyze gates, license gate. Good hygiene — but coverage is concentrated on auth/enrollment/storage happy paths, and one shipped Critical bug proves the gaps are real.

---

## T-1. Key-package claim flow has zero coverage — and it's broken

- **Severity:** Critical (evidence, not just risk)
- **Location:** `Store.ClaimConversationKeyPackages` (`key_package_store.go`), route `POST /api/v1/conversations/{id}/key-packages/claim`
- **Gap:** No store test, no HTTP test. Consequence: the nonexistent-table bug (logical L-1) shipped and passes CI today.
- **Fix:** Store-level test: two accounts in one conversation, device A publishes packages, device B claims → asserts atomic claim, exclusion of requester's own device, `ErrKeyPackageUnavailable` when a member device has none. HTTP test for the 409 mapping.

## T-2. No schema-vs-query consistency check

- **Severity:** High
- **Gap:** Store methods embed raw SQL; nothing guarantees every referenced table/column exists in the migrated schema unless a test happens to execute that exact method.
- **Fix:** Cheap version: a test that opens a migrated in-memory DB and calls **every** exported store method once (even with empty data) — SQLite parses/plans the query and fails on missing relations. This single test would have caught L-1.

## T-3. Proxy-topology behavior is untested

- **Severity:** High
- **Gap:** No tests for: client-IP resolution through `X-Forwarded-For` with trusted proxies (rate limiter), WS registration limits behind a proxy (logical L-2), or `setupAuthorized` with a same-host proxy (security S-1). These are exactly the behaviors that differ between dev (direct) and prod (proxied).
- **Fix:** Table-driven tests on `rateLimiter.clientIP`; a hub test registering >20 clients with one RemoteAddr but distinct XFF; a `setupAuthorized` test matrix (token set/unset × loopback/proxied).

## T-4. Custom WebSocket parser has no fuzz or adversarial tests

- **Severity:** High
- **Location:** `server/internal/realtime/websocket.go`; existing `websocket_test.go` covers the cooperative path
- **Gap:** No malformed-frame tests (bad RSV bits, unmasked frames, oversize control frames, fragmentation, 64-bit length edge cases), no `testing.F` fuzz target.
- **Fix:** Add `FuzzDrainClientFrames` over a `net.Pipe`; assert the goroutine always terminates and never panics. Run in CI with a small corpus.

## T-5. Retention/prune sweeper edge cases untested

- **Severity:** Medium
- **Gap:** No test for: shared attachment referenced by one expired + one live message (logical L-8), orphan-blob reaping grace period, sweeper behavior when blob deletion fails (L-9), idempotency-key reuse after expiry (the delete-then-check dance in `saveMessageEnvelope`).
- **Fix:** Store tests with controlled clocks (`now` is already parameterized on the prune APIs — good design, use it).

## T-6. Mobile: no tests for the concurrency-sensitive core

- **Severity:** High
- **Gap:** `SecureLocalStore` read-modify-write interleaving (logical L-3) is untestable as written and untested; `_catchUpSyncEvents` re-entrancy (`_catchingUpSync`/`_catchUpRequested`), full-resync recovery (`full_resync_required` path), outbox flush ordering/poison handling (L-7), and 401-during-catch-up session teardown all lack tests. Existing widget tests cover screens; `app_state_test.dart` covers happy paths.
- **Fix:** After serializing the store (L-3 fix), add interleaved-operation tests with a fake async storage that yields between read and write; state-machine tests for catch-up with scripted event pages and injected failures.

## T-7. No end-to-end API contract test

- **Severity:** Medium
- **Gap:** The mobile `ApiClient` and the Go handlers are only linked by convention (JSON key spellings, status codes, pagination fields like `next_before`). `REMAINING-WORK.md` already names "generated API-contract checks" as missing. A drift (e.g. renaming `next_before`) would pass both suites.
- **Fix:** Either an OpenAPI spec with server-side validation middleware in tests + generated Dart client, or golden-file contract tests: run the real server binary, drive the full flows (setup → invite → register → link → message → sync), snapshot responses.

## T-8. Two-device E2E and platform jobs (documented, restated for completeness)

- **Severity:** High (already tracked in `REMAINING-WORK.md`)
- **Gap:** No crypto-dependent two-device suite; Android/iOS release-build jobs and the compose smoke job exist in CI but their hosted-runner behavior is listed as unverified; no MLS interop vectors.
- **Fix:** As planned in `REMAINING-WORK.md`; add the two-device suite skeleton now (against fake crypto) so only the crypto swap is needed later.

## T-9. Backup/restore CLI round-trip untested

- **Severity:** Medium
- **Location:** `server/cmd/messenger-server/main.go` (`backup`, `restore`, rollback logic ~200 lines of careful but intricate file juggling)
- **Gap:** No test creates a backup, corrupts a blob/manifest, and asserts restore refuses + rolls back; no test of the legacy database-only restore warning path; no test that `-wal`/`-shm` companions are removed.
- **Fix:** These are pure-Go integration tests over temp dirs — cheap to add, high confidence value for the operator-facing recovery story.

## T-10. Miscellaneous coverage holes worth closing

| Area | Missing case |
|---|---|
| `ManageConversationMember` | DM-expansion rejection (once L-4 is fixed); rank-escalation matrix is partially covered |
| `routeTimeouts` | Deadline classes per path (would catch L-5) |
| `deliverPush` | `ErrSubscriptionGone` disables target; context-expiry mid-loop |
| `SearchMetadata` | LIKE-escape behavior (`%`, `_` in queries) |
| `exportAccount` | Pagination + `next_before` correctness |
| Rate limiter | Auth vs general class split; bucket-table cap behavior (429 on table full) |
| Flutter | Mojibake/i10n string sweep (a simple non-ASCII lint would have caught UI-3) |
| CI | No coverage-threshold gate (coverage.out is produced but unchecked); `REMAINING-WORK.md` already plans "security-invariant coverage thresholds" |

---

**Priority order:** T-2 (one test, catches a class) → T-1 → T-3 → T-4 → T-6 → T-9 → T-5/T-7/T-10 → T-8 (with the crypto work).
