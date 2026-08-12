# Testing and Verification Gaps

**Audit date:** 2026-07-21

## Baseline results

| Check | Result | Evidence |
| --- | --- | --- |
| `./scripts/test.ps1` | **Fail** | Server packages run, then `server/websetup.TestSetupNoticeFailsClosed` fails; later phases are skipped. |
| Direct Rust `cargo test` in pinned container | Pass | 13 passed, 0 failed. |
| Direct Flutter `flutter test` in pinned container | **Fail** | 27 test cases pass; one test library fails to load because `QrScanScreen` does not compile. |
| `./scripts/lint.ps1` | **Fail** | Go/Rust checks complete; Flutter analyzer reports one compile error and one secure-storage deprecation. |
| `scripts/release-readiness.sh` | **Expected fail** | `release blocked: production MLS crypto is not wired`. |
| Rendered UI review | Blocked | Flutter does not compile; no in-app browser was available for `/setup`. |

## Findings

### TEST-01 — The committed server baseline is red

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `server/websetup/index.html`; `server/websetup/websetup_test.go:8-27` |
| Blocker before production | **Yes** |

**Description:** The setup page's copy no longer matches the safety assertions in `TestSetupNoticeFailsClosed`. The first missing phrase is “Setup Is Not Available In This Build.”

**Why it matters:** A release cannot be trusted when the normal server test command fails, especially on first-owner safety messaging.

**Recommended fix:** Reconcile the reviewed page/test contract and require the full server suite in branch protection before merge/release.

**Risks/dependencies:** Preserve the no-form/fail-closed behavior and setup-token warning; do not weaken the test merely to turn CI green.

### TEST-02 — The committed mobile baseline is red

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `mobile/lib/features/auth/qr_scan_screen.dart:83`; mobile analyze/test/build jobs |
| Blocker before production | **Yes** |

**Description:** The locked scanner package rejects the three-argument `errorBuilder`. Analyze fails and one test library cannot compile.

**Why it matters:** Passing tests in unrelated files do not establish a buildable application.

**Recommended fix:** Correct the callback contract, add direct widget coverage for scanner error state, and run clean Android/iOS release builds in CI.

**Risks/dependencies:** Keep dependency locks and compiler versions aligned across local scripts and CI.

### TEST-03 — No test exercises the broken key-package claim path

| Field | Detail |
| --- | --- |
| Severity | Critical |
| Location | `server/internal/storage/key_package_store.go`; storage/API tests |
| Blocker before production | **Yes** |

**Description:** No migration-backed test calls `ClaimConversationKeyPackages` or `POST .../key-packages/claim`, so references to the nonexistent `conversation_members` table shipped undetected.

**Why it matters:** The most important server operation for MLS roster creation is completely broken despite broad server test coverage.

**Recommended fix:** Add store and HTTP integration tests covering success, missing package atomic rollback, two devices per account, revoked/expired package exclusion, duplicate/concurrent claims, and nonmember denial.

**Risks/dependencies:** Use generated opaque test bytes, never real plaintext/message fixtures. Include a schema-query smoke test where practical.

### TEST-04 — Mobile persistence concurrency and capacity are untested

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `mobile/lib/storage/local_store.dart`; `mobile/test/app_state_test.dart` |
| Blocker before production | **Yes** |

**Description:** Tests use an in-memory implementation and validate sequential round trips. They do not interleave cursor, outbox, snapshot, background push, and crypto-state writes or exercise platform size/failure behavior.

**Why it matters:** The production `SecureLocalStore` can lose updates and erase state while tests remain green.

**Recommended fix:** After moving to an encrypted database, add deterministic concurrency, crash-at-commit, corrupt-record, rollback-counter, full-disk, and background-isolate tests on Android/iOS.

**Risks/dependencies:** Crypto state/cursor atomicity is a security invariant; mocks alone are insufficient.

### TEST-05 — Proxy-sensitive setup, throttling, and realtime behavior lacks integration coverage

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | app rate limiter, `setupAuthorized`, `syncWebSocket`, Compose/Caddy smoke tests |
| Blocker before production | **Yes** |

**Description:** Tests do not run the full trusted-proxy chain to verify client IP resolution, spoof rejection, per-IP realtime limits, or loopback setup authorization.

**Why it matters:** Both owner takeover risk and documented Caddy connection failure depend on topology that unit tests miss.

**Recommended fix:** Add an end-to-end proxy fixture with distinct forwarded clients, untrusted spoof attempts, setup with/without token, and more than 20 legitimate realtime sockets.

**Risks/dependencies:** Test both bundled bridge networking and common host-loopback proxy deployments.

### TEST-06 — Mutation/event atomicity has no failure-injection coverage

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | edit/delete/reaction/receipt/retention/call/device handlers and stores |
| Blocker before production | **Yes** |

**Description:** Tests generally call the state mutation and `SaveSyncEvent` separately, mirroring the defect instead of proving one transaction. No test fails event insertion after a successful mutation.

**Why it matters:** Offline convergence and deletion propagation can silently break only under partial failures.

**Recommended fix:** Expose transactional service methods and inject failures before commit; assert neither state nor event commits alone and that successful responses always carry a durable positive event ID.

**Risks/dependencies:** Include retry/idempotency tests so client retries do not duplicate reactions or state transitions.

### TEST-07 — Custom WebSocket parsing has no fuzz or conformance suite

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `server/internal/realtime/websocket.go`; realtime tests |
| Blocker before production | No, if replaced with a reviewed library |

**Description:** Basic examples are covered, but random/truncated frames, 64-bit lengths, fragmentation sequences, repeated control frames, slow reads, and state transitions are not fuzzed.

**Why it matters:** Hand-written network parsers fail in combinations conventional unit cases do not anticipate.

**Recommended fix:** Add native Go fuzz targets plus protocol conformance tests, run under `-race`, and retain seed corpus regressions for every defect.

**Risks/dependencies:** Ensure fuzz failures never print tokens or frame payloads that may contain sensitive ciphertext.

### TEST-08 — There is no client/server contract test

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | Go handlers/models; `mobile/lib/core/api_client.dart`; CI |
| Blocker before production | **Yes** before enabling messaging |

**Description:** Dart API parsing is tested against handwritten maps/fakes, not a live Go server or generated schema. Search result promises, pagination, error codes, sync payload shape, and feature omissions drift independently.

**Why it matters:** Integration defects appear only on real flows, as the schema/query and search mismatches demonstrate.

**Recommended fix:** Maintain a privacy-reviewed OpenAPI/JSON-schema contract or shared fixtures, then run black-box Flutter/Dart integration tests against an ephemeral migrated server.

**Risks/dependencies:** Fixtures must contain opaque synthetic ciphertext only and must not encourage server plaintext models.

### TEST-09 — Production crypto has no complete interoperability/device matrix

| Field | Detail |
| --- | --- |
| Severity | Critical |
| Location | Rust tests, mobile tests, CI, `docs/crypto-protocol.md` required evidence |
| Blocker before production | **Yes** |

**Description:** Rust unit tests cover core two-device lifecycle, but there are no shipped Dart/native integration tests, cross-platform vectors, offline epoch convergence, restart/reinstall/rollback cases, or device-removal end-to-end tests.

**Why it matters:** Correct primitives do not prove correct orchestration, storage, or FFI ownership on phones.

**Recommended fix:** Add deterministic vectors for create/add/remove/update/application/exporter flows and a real-device Android/iOS matrix covering backgrounding, process death, offline membership changes, corrupted state, and key-package exhaustion.

**Risks/dependencies:** Independent review should evaluate the final tested implementation, not only the Rust crate.

### TEST-10 — Backup/restore and deployment recovery are not tested end to end

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `server/cmd/messenger-server/main.go` backup/restore; CI; deployment smoke tests |
| Blocker before production | **Yes** for production data durability |

**Description:** There are no command-level tests that create an instance backup, corrupt DB/blob/manifest variants, restore under downtime, verify checksums/migrations, and prove rollback preservation.

**Why it matters:** An untested backup is not a recovery capability.

**Recommended fix:** Add isolated filesystem integration tests and a scheduled CI rehearsal that backs up a synthetic instance, restores it into a clean data directory, runs `doctor`, and verifies ciphertext hashes/metadata.

**Risks/dependencies:** Never run restore against the workspace or production paths; use validated temporary directories.

### TEST-11 — UI, accessibility, and load gates are too shallow

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | mobile widget tests; GitHub workflows; server benchmarks |
| Blocker before production | No, but required before general availability |

**Description:** Only a small subset of screens has widget coverage; there are no goldens, semantics/dynamic-type checks, end-to-end user journeys, load/soak tests, or minimum coverage thresholds.

**Why it matters:** Navigation, responsive, accessibility, and capacity regressions can pass unit-oriented CI.

**Recommended fix:** Add core-flow widget/integration tests, focused golden breakpoints, semantics checks, synthetic load profiles, and practical coverage thresholds that fail on regression rather than rewarding raw percentage.

**Risks/dependencies:** Golden tests should be limited to stable high-value layouts; synthetic load data must contain no real content.

