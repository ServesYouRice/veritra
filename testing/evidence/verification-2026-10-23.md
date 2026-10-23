# Verification sweep (2026-10-23)

Runtime checks for the cards whose board status reads "checks pending
(Codex, 2026-08-14)" (I29, I30, I31, I32, I35, I36, I37, I38, I40), plus QA01
and QA04. No feature changes. "No test" means no automated test covers the
criterion; inspection is not counted as a pass.

## Run

| Field | Value |
|---|---|
| Base commit | `1912edac5f2e8fd72691e5fac736df8be1fc253f` (main, PR #79 merge) |
| Working tree | base plus the two test-only fixes below, committed with this file |
| Host | Linux 6.18.44 x86_64, 4 shared vCPU (Intel Xeon), native toolchains, no containers |
| Go | go1.26.8 (pinned by `.go-version` and `server/go.mod`) |
| Rust | rustc/cargo 1.91.0 |
| Flutter | 3.44.0, Dart 3.12.0 |
| Python | 3.13.16 |
| Not present | `cargo-audit`, PowerShell, shellcheck |

## Commands and results

| Command | Result |
|---|---|
| `cd server && go test -race -p 2 -count=1 -v ./...` | pass: 14 packages, 139 top-level tests, 0 data races |
| `cd server && go vet ./...` and `gofmt -l .` | pass, clean |
| `cargo test --manifest-path crypto/rust/Cargo.toml --locked` | pass: 27 tests |
| `cargo test ... --locked --release release_profile` | pass: 2 tests (panic guard, overflow checks) |
| `cargo build ... --locked --release` | pass |
| `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings` | pass |
| `flutter pub get --enforce-lockfile`, `flutter analyze` | pass, no issues |
| `dart format --set-exit-if-changed .` | pass, 0 changed |
| `VERITRA_CRYPTO_LIBRARY=... flutter test` (full suite) | pass: 217, 2 skipped (live contract and demo e2e, run below) |
| `VERITRA_CRYPTO_LIBRARY=... flutter test test/attachment_crypto_test.dart` | pass: 11, 0 skipped |
| `scripts/test-api-contracts.sh` (port 18381) | pass: 4 tests against a live server |
| `scripts/test-demo-e2e.sh` (port 18382) | pass: 1 test, real OpenMLS clients, offline/restart |
| `scripts/check-demo-boundary.sh` | pass |
| `scripts/check-go-toolchain.sh` | pass; injected `.go-version` drift on a scratch copy exits 1 |
| `scripts/check-rust-audit-expiry.sh --self-test` | pass; a `--now` override is refused (exit 1) |
| `scripts/check-mobile-dependencies.sh` | pass |
| Five `scripts/*_test.py` fixture suites | pass (after fix 1) |
| `scripts/release-readiness.sh` (read-only) | blocked as expected: approval files missing |
| `docker build -f server/Dockerfile ...` | **blocked**: Docker Hub 429 on the pinned `golang` base image |
| `scripts/verify.sh` | **not run**: `cargo-audit` missing (script exits 2 by design); the sandbox also refused it |
| `scripts/audit-rust.sh` | **not run**: `cargo-audit` missing |
| `BenchmarkPasswordVerificationCosts -benchtime 3x` | runs; cost 10 about 55 ms, cost 12 about 220 ms on a shared CPU (not a policy measurement) |

## Fixes made (test and wrapper only)

1. `scripts/check-release-evidence_test.py`: after its first negative case,
   the fixture restored `production_crypto` without `reviewer_is_author`, so
   the next four negative cases (skipped job, pending review, author reviewer,
   container commit) failed with the leftover "production_crypto reviewer is not
   independent" error and passed vacuously. Each case now starts from valid
   evidence and must fail with its own message. Added binary-commit mismatch
   and malformed-digest cases. Validator, jobs and evidence semantics are
   unchanged.
2. `scripts/test.sh`, `scripts/test.ps1`: with no Python interpreter, both
   skipped the release-policy fixtures silently. QA01 requires a visible
   failure, so they now exit 1. Checked for `test.sh` with a PATH that has no
   Python (exit 1). Also checked: a failing fixture stops `test.sh` before Go
   runs (exit 3). `test.ps1` was not executed because PowerShell is not installed.

## Card → criterion → test

Go paths are relative to `server/`, Dart test files to `mobile/test/`.

| Card | Criterion | Test | Result |
|---|---|---|---|
| I29 | Sentinel capability absent from the app log, path and route | `internal/app/metrics_test.go` TestRequestLoggerUsesMatchedPatternAndNeverRawPath | pass |
| I29 | Absent from the configured proxy log | `deploy/caddy/Caddyfile` filter deletes the URI and `X-Recovery-Token` | no test |
| I29 | Old (path-borne) capability fails | `internal/httpapi/api_test.go` TestMetadataSearchBackupExportAndAccountDelete (legacy path → 404) | pass |
| I29 | Expired, replayed and rotated capabilities fail | `internal/storage/sqlite_test.go` TestRecoveryCapabilityExpiresAndConsumesAfterResumableTransfer | pass |
| I29 | Resume only within the approved exchange | TestRecoveryResumesFromTheClientsOffset; `content_handlers_test.go` TestRecoveryRangeRequiresSingleContiguousRange; storage lease test above | pass |
| I29 | New route rate-limited | `internal/app/rate_limit_test.go` TestRecoveryRouteUsesCredentialRateLimit (route class only, no 429 test) | pass (partial) |
| I29 | No body, key, token or ciphertext logged | Logger test covers the header and path only | partial |
| I30 | Plain and MLS pages processed | `demo_e2e_test.dart` "demo clients exchange every message type and work offline" | pass |
| I30 | Duplicate events | no mobile test (server side: TestMLSMessagesAreScopedIdempotentAndAtomic) | no test |
| I30 | Interruption at every commit boundary | `encrypted_local_store_test.dart` "MLS transition rolls back at every injected boundary", "crypto state and cursor roll back together"; `app_state_test.dart` "crypto state and cursor commit together and reject rollback" | pass |
| I30 | Cursor cannot outrun message persistence | `encrypted_local_store_test.dart` "sync event persists its ciphertext before the cursor and fences leases" | pass |
| I30 | Cursor expiry never jumps | `sync_recovery_test.dart` "an expired cursor asks for relink or backup, never a jump"; TestSyncRecoveryResponses | pass |
| I30 | Foreground/background overlap coalesces | `app_state_test.dart` "account sync owner coalesces overlapping requests", "paused push wake does not sync and resumes from the durable marker" | pass |
| I30 | Account switching | Lease fencing only; no AppState switch test | partial |
| I31 | 100/101 boundary keeps the oldest item | `encrypted_local_store_test.dart` "outbox capacity refuses the 101st item without eviction"; `app_state_test.dart` "full outbox refuses before encryption and keeps all entries" | pass |
| I31 | 99 boundary; second enqueue path | Only implicit in the fill loops | no test |
| I31 | Retries survive restart | "queued draft survives a database restart"; "failed encrypted envelope persists and retry reuses its key" | pass |
| I31 | Concurrent flushes coalesce | none for the message outbox | no test |
| I31 | 401/404/409/413/422/507 behaviour | Classification at `lib/core/app_state.dart:3061` is untested | no test |
| I31 | Accurate quota copy | none | no test |
| I32 | No false logged-out flash | none | no test |
| I32 | No old-account write after logout/switch | Lease fence only; no AppState test | partial |
| I32 | No live socket after teardown | `sync_service_test.dart` "dispose during an in-flight handshake leaves no open socket", "dispose does not wait out the reconnect backoff", "dispose is idempotent and connect after dispose is inert" | pass |
| I32 | No cursor change after a failed restore | `app_state_test.dart` "restore failure enters recovery without resetting the cursor" | pass |
| I35 | One sweep drains 1,200 per class | none | no test |
| I35 | Cancellation stops promptly | none | no test |
| I35 | Attachment rows and blobs stay consistent | `PruneExpiredContent` untested; only TestBlobDeletionReconciliationRetriesFailure and TestDeleteAttachmentCommitsDeletionQueueAtomically (non-retention path) | no test |
| I35 | Sustained ingest stays below backlog target | none | no test |
| I35 | Backlog metrics exposed | TestHTTPMetricsExposeBoundedOperationalSignals | pass |
| I36 | Recipient-lookup failure cannot lose fanout | `internal/messaging/service_test.go` TestCreateUsesRecipientsReturnedByCommit (no post-commit lookup); TestSyncEventFailureRollsBackDurableMutations. No injected failure in the recipient query | partial |
| I36 | 100-target bursts stay bounded | `internal/app/push_delivery_test.go` TestPushWakeDeliveryConcurrencyIsBounded (24 jobs, peak 8) | partial |
| I36 | Restart and partial provider failure keep wake work | TestPushWakeCancellationLeavesJobForLeaseExpiry, TestPushWakeTransientFailureSchedulesRetry, TestPushWakeSendTimeoutSchedulesRetry, TestPushWakeStoreWriteFailuresAreLoggedAndCounted | pass |
| I37 | Weak, malformed and placeholder production tokens fail | `internal/config/config_test.go` TestValidateSetupTokenUsesDecodedEntropyFloor, TestLoadRejectsWeakProductionSetupToken, TestValidateServeProductionPosture; `internal/app/deployment_test.go` TestProductionSetupTokenIsRequiredOnlyUntilOwnerExists | pass |
| I37 | Generated tokens work | `cmd/messenger-server/main_test.go` TestGenerateSetupTokenProducesValidToken | pass |
| I37 | Comparison through fixed-size hashes | TestSetupAuthorizationUsesResolvedIdentityAndToken (accept/reject only) | partial |
| I37 | Full tables neither fail open nor lock out | `internal/httpapi/login_backoff_test.go` (both tests); TestRateLimiterEvictsInsteadOfRefusingNewClients; TestLoginBackoffIsBoundedAndAccountPrivacySafe | pass |
| I37 | Reauth CPU/guessing budget | Route class only; no reauth backoff test | partial |
| I37 | T37C plumbing: rehash, cost range, idle/absolute lifetime | `internal/auth/auth_test.go` TestLegacyBcryptHashNeedsMigration, BenchmarkPasswordVerificationCosts; TestLoadPasswordCostRange; TestSessionIdleTouchKeepsAbsoluteLifetimeBounded | pass (rotation deferred) |
| I38 | Token without recent auth is rejected | TestAccountExportRequiresRecentAuthentication | pass |
| I38 | Export holds no reusable secret; schema v2 | TestMessageMarkersSyncSearchExportAndMembershipGuards; live `api_contract_test.dart` | pass |
| I38 | Audit event recorded; a failed write blocks export | none | no test |
| I38 | Client download does not log or expose the payload | none | no test |
| I40 T40A | Expiry guard with injected dates | `check-rust-audit-expiry.sh --self-test` (deadline −1 µs passes; deadline and +1 µs fail) | pass |
| I40 T40A | Release-mode panic and overflow guards | `cargo test --release` release_profile_* | pass |
| I40 T40B | Toolchain drift fails CI | `check-go-toolchain.sh` plus injected drift | pass |
| I40 T40B | Container compiler check and labels | `docker build` | blocked (Docker Hub 429) |
| I40 T40C | A rename cannot bypass the gate | `check-release-evidence_test.py` (missing approval) | pass (after fix 1) |
| I40 T40C | Incomplete matrix or unreviewed commit cannot publish | `check-release-evidence_test.py` (skipped job, pending, author); `check-ci-evidence_test.py` (missing/skipped job, wrong SHA, failed run) | pass (after fix 1) |
| I40 T40C | Tested commit equals packaged commit | `check-release-evidence_test.py` (binary and container commit); `write-release-evidence_test.py` propagation | pass |
| I40 T40D | Mobile dependency policy | `check-mobile-dependencies.sh` | pass |
| I40 T40D | Full gate has no environment skips | `verify.sh` | not run (`cargo-audit` missing) |
| QA01 | Malformed, wrong-commit, incomplete/skipped, multiple-run, approval-shape, propagation, image/digest, valid | Five fixture suites | pass (after fix 1) |
| QA01 | A fixture failure fails wrappers and CI | `test.sh` probe (exit 3); `ci.yml` `licenses` job runs the suites under `bash -e` (inspection) | pass |
| QA01 | Missing interpreter fails visibly | `test.sh` probe (exit 1) | pass (after fix 2); `test.ps1` not executed |
| QA04 | 1 byte and 1 MiB boundaries; manifest/framing bounds; tamper; wrong key/conversation/action/chunk count/size; truncation/extension; unsupported version; empty/oversized; cancellation; owned-file cleanup; pre-existing destination kept | `attachment_crypto_test.dart`, 11 tests on the real native library | pass |

## Residual blockers

- Container artifact check (T40B): needs Docker Hub access for the pinned
  `golang` digest.
- `verify.sh` and `audit-rust.sh`: need `cargo-audit` 0.22.2.
- `test.ps1`: needs a Windows/PowerShell run.
- Release readiness stays blocked until G24/G25 approval evidence exists (by design).
