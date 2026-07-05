# Testing Gaps — Veritra Audit (audits-fable)

Coverage analysis and missing test classes. The project is unusually well-tested for an MVP foundation (23 Go server tests, 2 Dart test files with ~20 cases, a Rust fail-closed test, and CI running test/vet/fmt/analyze across all three languages). This file is about the gaps that matter for production confidence, and the tests that would have caught the defects in the other audit files.

**Severity scale:** Critical / High / Medium / Low / Nice-to-have.

---

## What exists (baseline)

- **Server (`server/internal/httpapi/api_test.go`, 12 tests):** plaintext-field rejection, ciphertext envelope acceptance, JSON trailing-document rejection, message lifecycle + sync routes, membership-scoped writes, metadata search + backup + export + delete, attachment invalid-metadata rollback, password-login requires device ID, logout/device-revocation session invalidation, non-production key-package rejection, device-linking approval flow, cursor pagination.
- **Server (`server/internal/storage/sqlite_test.go`, 11 tests):** invite/device/envelope flow, retention metadata persistence, expired-message hide+prune, retention caps expiry, timestamp sort ordering, markers/sync/search/export/membership guards, search ranking + allowlist, no-substring-enumeration, expired invite, device-link approval-before-session, migration checksum drift rejection.
- **Server:** `auth_test.go` (password hashing/verify), `push_test.go` (generic payload), `domain/permissions_test.go` (role permissions).
- **Mobile (`mobile/test/app_state_test.dart`, `ui_features_test.dart`):** state transitions and some widget/feature behavior, using `MemoryLocalStore` + `TestOnlyCryptoService`.
- **Crypto:** Rust `production_crypto_fails_closed`.

The security-critical invariants (no plaintext persistence, membership scoping, timing-equalized login, migration integrity) are genuinely well covered. Good.

---

## Summary table

| ID | Title | Severity |
|---|---|---|
| TEST-1 | No test catches the SEC-1 role-demotion authz hole | High |
| TEST-2 | No test exercises the client's actual channel-create payload (LOG-1) | High |
| TEST-3 | No WebSocket protocol tests (ping/pong, masking, close) — LOG-2 uncaught | High |
| TEST-4 | No concurrency tests (idempotency race LOG-6, connection caps) | Medium |
| TEST-5 | No contract tests between Dart client and Go server | Medium |
| TEST-6 | No storage-quota / large-upload / disk-exhaustion tests (SEC-4) | Medium |
| TEST-7 | Mobile sync/catch-up coalescing (LOG-7) and 401 handling (LOG-5) untested | Medium |
| TEST-8 | No coverage measurement or threshold in CI | Medium |
| TEST-9 | No end-to-end / integration test spanning server + a real client | Medium |
| TEST-10 | Backup/restore and blob-consistency paths untested | Medium |
| TEST-11 | No negative/fuzz tests on input validation (username, sizes, enums) | Low |
| TEST-12 | Rate limiter and trusted-proxy XFF parsing lightly tested | Low |
| TEST-13 | No load/soak test to surface goroutine/connection leaks | Low |

---

## TEST-1 — Role demotion authz hole is untested

- **Severity:** High
- **Gap:** `api_test.go` tests that a caller cannot grant a role *above* their own, but nothing tests re-adding an existing higher-ranked member with a *lower* role (SEC-1). The upsert-demotion path has zero coverage.
- **Add:** A test where a moderator posts `{account_id: <owner>, role: member}` and asserts 403 (after the fix) — and, as a guard against regressions, that an existing member's role is never silently changed by the "add" endpoint.

## TEST-2 — Client's real channel payload is untested

- **Severity:** High
- **Gap:** Channel creation is exercised server-side only with valid kinds; no test sends `kind: 'text'` (the mobile default, LOG-1). The 100%-failure bug slipped through because the server tests and the client defaults were never checked against each other.
- **Add:** A server test that POSTs the exact body the Dart client sends (including `kind: 'text'`) and asserts the intended outcome (either a mapped 400 or a corrected default). Pairs with TEST-5.

## TEST-3 — No WebSocket protocol tests

- **Severity:** High
- **Gap:** `websocket.go` (handshake, masking enforcement, frame size cap, ping/pong, close) has no unit tests. The ping/pong omission (LOG-2) that causes perpetual reconnects would have been caught by a test asserting the server replies to a client ping with a pong.
- **Add:** Tests that (a) reject an unmasked client frame, (b) reject oversized frames, (c) respond to a ping with a pong, (d) close cleanly on a close frame, (e) reject cross-origin upgrades. These are pure protocol tests against the hijacked conn.

## TEST-4 — No concurrency tests

- **Severity:** Medium
- **Gap:** The idempotency race (LOG-6) and any hub/registration races are untested. All storage tests are single-threaded.
- **Add:** A test firing two concurrent `SaveMessageEnvelope` calls with the same `(device, idempotency_key)` and asserting exactly one row + both callers get the envelope (no 500). A hub test registering/unregistering concurrently under `-race`.

## TEST-5 — No client/server contract tests

- **Severity:** Medium
- **Gap:** Field names, enum values, status codes, and pagination params are duplicated across Dart and Go with no shared source of truth or contract test. LOG-1 (enum), LOG-16 (search type never emitted), and any future field rename can drift silently.
- **Add:** Either a shared OpenAPI/JSON schema both sides validate against, or a golden-payload test set that both the Go handlers and Dart models parse. At minimum, a Go test asserting the JSON shapes the Dart models expect (keys like `next_before`, `device_link`, `claim_token`).

## TEST-6 — No storage-quota / large-upload tests

- **Severity:** Medium
- **Gap:** Upload endpoints are tested for the invalid-metadata rollback path only. There is no test for the 50/100 MiB caps being enforced, no test of many-uploads accumulation, and (because quotas don't exist yet, SEC-4) nothing to test there.
- **Add:** After implementing quotas: tests that the Nth byte over quota is rejected, that oversized bodies return 413, and that a rejected upload leaves no orphan blob (extends the existing rollback test).

## TEST-7 — Mobile sync coalescing and 401 handling untested

- **Severity:** Medium
- **Gap:** `_catchUpSyncEvents` single-flight/coalescing (LOG-7) and the absent 401/session-expiry flow (LOG-5) have no tests. `app_state_test.dart` uses in-memory fakes but doesn't simulate overlapping events or a 401 mid-session.
- **Add:** State tests injecting a fake `ApiClient` that (a) returns overlapping event bursts to assert no dropped signals after the coalescing fix, and (b) returns 401 to assert the app transitions to the connect screen and stops the sync loop.

## TEST-8 — No coverage measurement in CI

- **Severity:** Medium
- **Gap:** CI runs tests but never measures or gates coverage (`go test -cover`, `flutter test --coverage`). There's no visibility into what's untested and no ratchet preventing regressions.
- **Add:** Emit coverage in CI, publish it, and set a floor (start at current level, ratchet up). Focus the floor on `httpapi`, `storage`, `auth`, and mobile `core/`.

## TEST-9 — No end-to-end test

- **Severity:** Medium
- **Gap:** Every test is a unit/integration test within one language. Nothing spins up the server and drives it through a real client session (register → link → send → sync → receive). Cross-layer bugs (LOG-1, LOG-4 silent membership, LOG-2 reconnect) live exactly in these seams.
- **Add:** A black-box E2E harness (Go test server + HTTP/WS client, or a scripted Dart integration test against a local server) covering the core happy path and the top failure paths. Use `TestOnlyCryptoService` so it runs without real crypto.

## TEST-10 — Backup/restore and blob consistency untested

- **Severity:** Medium
- **Gap:** `BackupTo` (VACUUM INTO), CLI `restore` (WAL-lock probe, companion cleanup), and DB↔blob consistency (OPS-3) have no automated tests.
- **Add:** A test that writes data, backs up, mutates, restores, and asserts the restored DB matches the backup; a test asserting restore refuses when the WAL appears locked. A consistency check test that flags rows whose blobs are missing.

## TEST-11 — Thin negative/fuzz coverage on validation

- **Severity:** Low
- **Gap:** Username validation doesn't exist (LOG-9) so nothing tests it; size limits and enum validation have limited negative cases. `containsPlaintextMessageKey` (a recursive JSON walker) is a good fuzz target and isn't fuzzed.
- **Add:** Go fuzz tests for `decodeRawJSON`/`containsForbiddenPlaintextKey` and table-driven negative tests for every input validator once they exist.

## TEST-12 — Rate limiter / XFF parsing lightly tested

- **Severity:** Low
- **Gap:** The trusted-proxy XFF walk (`clientIP`) and bucket saturation behavior (SEC-11) have no dedicated tests; subtle spoofing bugs here are security-relevant.
- **Add:** Table-driven tests for `clientIP` with spoofed/legit XFF chains and trusted/untrusted proxies; a test of the auth-bucket vs general-bucket limits.

## TEST-13 — No load/soak test for leaks

- **Severity:** Low
- **Gap:** No test exercises many concurrent WebSocket connections over time to surface goroutine/connection leaks (relevant to SEC-10, OPS-5, and the WS write-path fix for LOG-2).
- **Add:** A soak test (or manual runbook) opening/closing many WS connections and asserting goroutine count returns to baseline; run periodically, not per-commit.

---

## Highest-value tests to add first

1. **TEST-3 (WebSocket ping/pong)** and **TEST-1 (role demotion)** — each would have caught a shipped blocker/high finding.
2. **TEST-5 / TEST-2 (contract + real client payloads)** — closes the client/server drift class that produced LOG-1 and LOG-16.
3. **TEST-9 (E2E happy path)** — the single highest-leverage safety net for a multi-language messaging system.
4. **TEST-8 (coverage gating)** — makes all subsequent gaps visible and prevents regressions.
