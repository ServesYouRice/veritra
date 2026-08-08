# Testing and Verification Gaps

## Current verification evidence

| Check | Audit result | Important limitation |
|---|---|---|
| `scripts/test.ps1` | Passed Go, Rust, and Flutter suites | 79 Flutter tests passed with 2 environment-dependent skips |
| `scripts/lint.ps1` | Passed formatting, vet, Clippy, Flutter analysis, and Dart formatting | Static success does not cover runtime interleavings or device integrations |
| `go test -race ./...` | Passed in a pinned Go container | Race detector covers exercised Go paths only |
| `scripts/release-readiness.sh` | Failed as designed | Reports that production MLS crypto is not wired |
| Live setup/health smoke | Passed on an isolated container | Not a full deployment or browser UI test |
| Browser/device visual run | Not available in this audit environment | Must remain an explicit release verification item |

The successful baseline is meaningful: the repository is not starting from a broken test state. One Flutter run also emitted Drift's warning that the database class was instantiated multiple times against the same executor; that warning should be treated as evidence for a targeted storage-concurrency test, not dismissed as test noise.

## Findings

### TEST-01 - No regression test protects MLS state from background cursor advancement

- **Severity:** Critical
- **Location:** `mobile/lib/push/background_push.dart`; `mobile/lib/core/app_state.dart`, sync catch-up tests
- **Description:** There is no test in which background wake fetches MLS events, the app later resumes, and every event is processed exactly once by the production crypto path before the durable cursor advances. The current background implementation can skip that processing entirely.
- **Why it matters for production:** This is a silent cryptographic state-divergence failure. Ordinary API and widget tests can remain green while real users become unable to decrypt future messages.
- **Recommended fix:** Add a deterministic integration test with a fake server event stream and a real/native or contract-faithful crypto adapter. Exercise normal pages, process interruption between crypto and cursor commit, duplicate events, cursor expiry, full resync, foreground/background overlap, and account switch. Assert atomic state plus cursor persistence.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** LOG-01; native ABI test environment; sync transaction redesign.

### TEST-02 - Session lifecycle interleavings are not covered

- **Severity:** High
- **Location:** `mobile/lib/main.dart`; `mobile/lib/core/app_state.dart`; `mobile/lib/sync/sync_service.dart`
- **Description:** Tests do not cover restore-versus-render, logout during catch-up, account switch during an in-flight request, dispose during WebSocket connect, or secure-storage/database open failure. These are the paths behind several identified races.
- **Why it matters for production:** Mobile lifecycle and network scheduling make these interleavings routine rather than exceptional. Stale data can be written after logout or resources can outlive their owning session.
- **Recommended fix:** Introduce controllable futures/fake clocks and write state-machine tests that pause each async boundary. Assert generation/account ownership before every commit, idempotent cancellation, zero post-logout writes, and stable user-visible startup states.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** LOG-03, LOG-04, LOG-12; UI-03.

### TEST-03 - Durable outbox limits, retries, and failure recovery are under-tested

- **Severity:** High
- **Location:** Mobile encrypted outbox, MLS outbox, message retry scheduling, composer tests
- **Description:** The suite does not demonstrate behavior at 100/101 pending envelopes, process death after encryption, local write failure, permanent versus retryable server errors, retry timer wakeup, or MLS control-message retry after a transient failure.
- **Why it matters for production:** Outbox correctness is the boundary between user intent and durable delivery. The present cap can silently delete accepted content, and retryable work can remain stuck indefinitely.
- **Recommended fix:** Specify outbox invariants and add boundary/property tests: no silent loss, stable idempotency keys, monotonic retry schedule, bounded backoff, restart recovery, preserved composer content before durable acceptance, and observable/manual recovery for blocked items.
- **Blocker before production:** Yes before enabling messaging.
- **Related risks or dependencies:** LOG-02, LOG-06, LOG-11; UI-02.

### TEST-04 - There is no signed real-device, visual, or accessibility release matrix

- **Severity:** High
- **Location:** Mobile release verification and `mobile/test/`
- **Description:** Widget tests exist, but there is no automated golden matrix or documented signed-build run across supported Android/iOS devices, text scaling, orientation, screen readers, reduced motion, and platform lifecycle transitions.
- **Why it matters for production:** Native loading, keychain/keystore behavior, push callbacks, background execution, layout, and accessibility differ from host/widget environments. A green unit suite cannot validate them.
- **Recommended fix:** Add golden/semantics coverage in CI and require a signed-device checklist on release candidates. Include cold start, upgrade with existing encrypted data, background/terminated push, offline send, attachment transfer, call permissions, VoiceOver/TalkBack, 200% text, and small-screen layout.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** UI-04; SEC-05; mobile signing and distribution pipeline.

### TEST-05 - External push and call integrations lack end-to-end staging evidence

- **Severity:** High
- **Location:** FCM, APNs, UnifiedPush, Web Push, WebSocket wake, WebRTC/TURN integration paths
- **Description:** Provider adapters have tests, but the audit found no release evidence using real provider credentials/devices and an independently hosted TURN service. The local Flutter suite skipped environment-dependent integration coverage.
- **Why it matters for production:** Credentials, entitlements, token rotation, provider payload constraints, NAT behavior, and OS background policies are common production-only failure points.
- **Recommended fix:** Maintain a privacy-safe staging environment and device pool. Test register, rotate, revoke, invalid-token cleanup, background and terminated wake, provider outage/backoff, multi-device fanout, call setup behind restrictive NAT, permission denial, and interrupted calls. Never use production user endpoints in test fixtures.
- **Blocker before production:** Yes for advertising push or calls.
- **Related risks or dependencies:** LOG-09, LOG-10; APNs/FCM credentials; TURN operations; visible-notification decision.

### TEST-06 - Publishing is not structurally gated on the full CI result

- **Severity:** High
- **Location:** `.github/workflows/release.yml`; `.github/workflows/ci.yml`; `scripts/release-readiness.sh`
- **Description:** The tag-triggered release job does not depend on a completed CI workflow/job. Its local readiness script checks only narrow source markers, so a release can begin concurrently with or independently of failing tests, scans, or platform contracts.
- **Why it matters for production:** Human convention is weaker than an enforced release dependency. A correctly named tag can publish artifacts without the evidence the project says is required.
- **Recommended fix:** Make release consume an immutable commit that has required protected checks, or call the complete reusable verification workflow and depend on it. Require crypto review evidence, vulnerability policy, ABI/live contract, reproducible build metadata, and signed-artifact verification before publish.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** DEP-01; repository branch/tag protection; release attestation policy.

### TEST-07 - Capacity, cleanup, and failure-mode tests do not represent sustained production load

- **Severity:** High
- **Location:** Server load/soak tests, retention sweeper, realtime hub, push fanout, conversation queries
- **Description:** The suite does not demonstrate sustained ingest above cleanup throughput, reconnect storms, slow push providers, large conversation history, large event gaps, or database/backup behavior near supported limits.
- **Why it matters for production:** Current defects such as the 500-row cleanup ceiling and unbounded push goroutines emerge with time and concurrency, not in short functional tests.
- **Recommended fix:** Add reproducible load and soak scenarios with seeded realistic data. Assert bounded backlog, latency percentiles, memory/goroutine counts, database growth, checkpoint health, cleanup convergence, and recovery after provider/database stalls.
- **Blocker before production:** Yes before publishing a capacity envelope.
- **Related risks or dependencies:** PERF-01 through PERF-05 and PERF-10; observability.

### TEST-08 - Backup, restore, and migrations lack fault-injection coverage

- **Severity:** High
- **Location:** Backup/restore commands; SQLite migrations; deployment upgrade/rollback tests
- **Description:** Existing tests do not cover pre-existing staging paths, concurrent invocations, name collisions, disk-full conditions, corrupt archives, missing blobs, permission failures, process termination during activation, or upgrade/rollback across supported schema versions.
- **Why it matters for production:** Recovery tooling is used during incidents when operator error and partial infrastructure failure are already likely. Untested destructive edge cases can turn a recoverable outage into data loss.
- **Recommended fix:** Build disposable end-to-end recovery tests with checksummed fixtures and fault injection. Verify the original instance is untouched on every pre-commit failure, restored DB/blob consistency, fsync/atomic activation assumptions, migration compatibility, and documented rollback boundaries.
- **Blocker before production:** Yes before storing irreplaceable user data.
- **Related risks or dependencies:** DEP-04, DEP-05, DEP-09, DEP-10.

### TEST-09 - The default local test command omits important contract suites

- **Severity:** Medium
- **Location:** `scripts/test.ps1` and equivalent developer entry points
- **Description:** The normal test script does not execute Go race detection, the live server/mobile contract, or the native host ABI path by default. In this audit, the Flutter run reported two skipped integration tests because the required server/native library was not configured.
- **Why it matters for production:** Developers can reasonably interpret the default green command as complete while the most integration-sensitive paths were skipped.
- **Recommended fix:** Provide a clearly named fast command and a canonical `verify` command that fails, rather than skips, when release-required prerequisites are absent. Print a machine-readable summary of executed and skipped suites. Keep race/contract/native checks required in CI.
- **Blocker before production:** No if CI enforces every omitted suite; currently related to TEST-06.
- **Related risks or dependencies:** Developer container setup; CI duration and caching.

### TEST-10 - There are no enforced coverage thresholds or fuzz/property campaigns

- **Severity:** Medium
- **Location:** Go, Rust FFI, Dart storage/sync, parsers, API payload validation
- **Description:** Go can produce a coverage profile, but the repository does not enforce risk-based coverage or run fuzz/property tests over untrusted binary and JSON boundaries. Rust FFI has good defensive code but limited hostile-input campaign evidence.
- **Why it matters for production:** Coverage percentage alone is insufficient, but completely unenforced coverage permits critical state-machine and parser paths to regress unnoticed. Fuzzing is especially valuable at the native boundary.
- **Recommended fix:** Track coverage by critical package and require explicit review for regressions. Add fuzz/property tests for FFI lengths/ownership, sync event parsing, attachment ranges, URL validation, token decoding, idempotency, and outbox invariants. Run longer campaigns on schedule.
- **Blocker before production:** No, provided the specific critical gaps above are closed.
- **Related risks or dependencies:** Stable seed corpus; sanitizer-compatible native builds.

### TEST-11 - Dependency assurance is incomplete across the full stack

- **Severity:** Medium
- **Location:** Dart/Flutter and Gradle dependency scanning; Rust advisory policy; CI supply-chain checks
- **Description:** CI scans Go and Rust, but no equivalent Dart/Flutter or Gradle vulnerability/license policy was found. The audit test output reported 25 newer incompatible Dart packages and a retracted `build_daemon 4.1.3` development dependency. Rust advisories are temporarily waived under a documented constrained-reachability exception that expires on 2026-08-29.
- **Why it matters for production:** Mobile transitive dependencies and build tooling are part of the release supply chain. Temporary advisory exceptions can silently become permanent without an enforced expiry.
- **Recommended fix:** Add lockfile-aware Dart and Android dependency review/scanning, fail on retracted packages, automate exception expiry, and produce an SBOM for server and mobile artifacts. Upgrade only with regression testing; newer is not automatically safer.
- **Blocker before production:** The unresolved production crypto advisory/review gate is a blocker; the broader tooling gap is not independently blocking.
- **Related risks or dependencies:** SEC-03; plugin/tool availability; dependency update compatibility.

## Minimum release verification gates

- [ ] Background and foreground sync prove atomic MLS-state/cursor behavior.
- [ ] Session restore/logout/account-switch races pass deterministic tests.
- [ ] Outbox boundary, restart, retry, and failure tests prove no silent loss.
- [ ] Signed Android and iOS builds pass the device/accessibility matrix.
- [ ] Real provider push and TURN scenarios pass in staging.
- [ ] Release publication requires all protected CI checks.
- [ ] Retention and push fanout converge under the documented load envelope.
- [ ] Backup/restore and migrations pass fault-injection and rollback drills.
- [ ] Release-required suites cannot be silently skipped.
- [ ] Crypto advisory exceptions are resolved or explicitly re-approved before expiry.
