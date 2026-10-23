# Verification sweep (2026-10-23)

Runtime checks for the cards whose board status reads "checks pending
(Codex, 2026-08-14)" (I29, I30, I31, I32, I35, I36, I37, I38, I40), plus QA01
and QA04. Gaps found by the first pass now have tests (listed per card), and
two real defects those tests exposed are fixed. "No test" means no automated
test covers the criterion; inspection is not counted as a pass.

## Run

| Field | Value |
|---|---|
| Base | `fb65019` (`agent/friendly-shannon-1thz1r`, on main `89a437e`) |
| Tested commit | `40fc635293977956dfa5bb437e6e02d6fef68054` (all code and tests below) |
| Host | Linux 6.18.44 x86_64, 4 shared vCPU (Intel Xeon), native toolchains |
| Go | go1.26.10 (pinned by `.go-version`, `server/go.mod`, Dockerfile) |
| Rust | rustc/cargo 1.91.0; OpenMLS 0.9.2; cargo-audit 0.22.2 |
| Flutter | 3.44.0, Dart 3.12.0 |
| Python | 3.13.16 |
| Not present | PowerShell, shellcheck |

## Commands and results (tested commit)

| Command | Result |
|---|---|
| `scripts/verify.sh` (`GOFLAGS=-p=2`, native crypto library, contract port 18381) | **pass**: all ten steps (`status: pass`) |
| ├ go-race: `go test -race -coverprofile ./...` | pass: 14 packages, 0 races; unchanged packages reused Go's test cache from an identical earlier run |
| ├ go-lint: `gofmt -l`, `go vet ./...` | pass |
| ├ rust-release: `cargo test --release --locked`, `fmt --check`, `clippy -D warnings` | pass: 27 tests in release mode (panic and overflow guards included); fmt and clippy clean |
| ├ dart-coverage: `flutter test --coverage`, `flutter analyze`, `dart format` | pass: 328 tests, 2 skipped (live contract and demo e2e, run separately); analyze and format clean |
| ├ coverage-floor (Go 50.0, Flutter 43.0) | pass: Go 60.60%, Flutter 60.34% |
| ├ mobile-dependencies, licenses | pass |
| ├ rust-audit (`scripts/audit-rust.sh`) | pass: 206 crates, 0 vulnerabilities, 1 allowed `unmaintained` warning (`proc-macro-error2`) |
| ├ release-policy-fixtures (five `*_test.py`) | pass (after fix 3) |
| └ api-contracts (`scripts/test-api-contracts.sh`) | pass: 19 tests against a live server |
| `cargo test --locked` (debug) | pass: 27 |
| `flutter test test/attachment_crypto_test.dart` (native library) | pass: 11, 0 skipped |
| `scripts/test-demo-e2e.sh` (port 18382) | pass: 1 test, real OpenMLS clients, offline/restart |
| `scripts/check-demo-boundary.sh`, `check-go-toolchain.sh` | pass |
| Injected `.go-version` drift (1.26.11) on a scratch copy | exit 1, as required |
| `check-rust-audit-expiry.sh --self-test`; `--now` override | pass; override refused |
| `test.sh` with no Python / with a failing fixture | exit 1 / exit 3 before Go runs |
| `scripts/release-readiness.sh` (first pass, read-only) | blocked as expected: approval files missing |
| Caddy 2.11.4 (pinned digest) with the repo Caddyfile, sentinel request | before fix: leaks (see I29); after fix: no sentinel in any log line |
| `docker build -f server/Dockerfile` | **blocked**: `go mod download` cannot verify the sandbox proxy's TLS CA. The pinned base image reports `go1.26.10`, matching the Dockerfile gate |

## Defects found and fixed

1. **I35, backlog metric.** `RetentionBacklog` counted invites, device links,
   consumed reservations, disabled push subscriptions and claimed key packages
   from `now`, while `PruneOperationalRows` keeps them 30 days. After a full
   sweep it read 11 rows instead of 5 in the new test, and the oldest age
   (measured from the row timestamp) exceeded one sweep interval, tripping the
   alert in `docs/operations.md` on a healthy instance. Each metric query now
   mirrors one prune predicate and ages rows from when they became prunable
   (`server/internal/storage/retention_metrics.go`; shared
   `OperationalRowRetention` constant used by `content_store.go`).
2. **I29, proxy logs.** With the shipped Caddyfile, Caddy's access log kept
   `X-Veritra-Setup-Token` and `X-Veritra-Claim-Token` values, and its error
   log (written whenever the upstream fails, e.g. during a restart) recorded
   the full URI and every header, including `X-Recovery-Token`. Both loggers
   now delete the URI and every credential header (`deploy/caddy/Caddyfile`);
   `Authorization` is redacted by Caddy. Re-checked against the real image.
3. **QA01 fixture.** Four of five negative cases in
   `check-release-evidence_test.py` passed vacuously (leftover invalid
   manifest). Fixed; each case must fail with its own message.
4. **QA01 wrappers.** `test.sh`/`test.ps1` skipped the fixtures silently
   without Python; they now fail.

Test-only knob: `App.retentionBudget` lets tests lengthen the 10-second sweep
clock so race runs check the 64-batch bound; production is unchanged. Under
`-race` on this shared host one 500-message prune batch took about 5 s, so
the clock, not the batch bound, limits a sweep on slow hardware.

## Card → criterion → test

Go paths are relative to `server/`, Dart test files to `mobile/test/`.
**New** marks tests added in this sweep.

| Card | Criterion | Test | Result |
|---|---|---|---|
| I29 | Capability absent from the app log, path and route | `internal/app/metrics_test.go` TestRequestLoggerUsesMatchedPatternAndNeverRawPath | pass |
| I29 | No body, key, token or ciphertext in the app log (debug level, success and rejection paths) | **New** `internal/app/log_privacy_test.go` TestApplicationLogNeverContainsBodiesTokensOrCiphertext | pass |
| I29 | Absent from the configured proxy log, URL and error | **New** `cmd/messenger-server/caddy_log_test.go` TestCaddyLogsDropURIsAndCredentialHeaders; live Caddy probe | pass (after fix 2) |
| I29 | Old, expired, replayed, rotated capabilities fail | TestMetadataSearchBackupExportAndAccountDelete (legacy path); `internal/storage/sqlite_test.go` TestRecoveryCapabilityExpiresAndConsumesAfterResumableTransfer | pass |
| I29 | Resume only within the approved exchange | TestRecoveryResumesFromTheClientsOffset; TestRecoveryRangeRequiresSingleContiguousRange | pass |
| I29 | New route rate-limited | **New** `internal/app/recovery_rate_limit_test.go` TestRecoveryGuessesHitTheCredentialRateLimit (11th guess → 429); TestRecoveryRouteUsesCredentialRateLimit | pass |
| I30 | Plain and MLS pages | `demo_e2e_test.dart` (real OpenMLS, live server); `sync_recovery_test.dart` MLS cases | pass |
| I30 | Duplicates: replayed or repeated events never applied twice | **New** `session_switch_test.dart` "I30: replayed and repeated sync events are never applied twice" | pass |
| I30 | Interruption at every commit boundary | `encrypted_local_store_test.dart` "MLS transition rolls back at every injected boundary", "crypto state and cursor roll back together" | pass |
| I30 | Cursor never outruns persistence; lease fence | "sync event persists its ciphertext before the cursor and fences leases" | pass |
| I30 | Cursor expiry never jumps | "an expired cursor asks for relink or backup, never a jump"; TestSyncRecoveryResponses | pass |
| I30 | Foreground/background overlap coalesces | "account sync owner coalesces overlapping requests", "paused push wake does not sync and resumes from the durable marker" | pass |
| I30 | Account switching | **New** `session_switch_test.dart` "a page held across logout and account switch never writes into either account" (fails when the ownership fences are removed) | pass |
| I31 | 99/100/101 boundary keeps the oldest item, refuses before encryption | **New** `outbox_delivery_test.dart` "99 queued: the 100th send is accepted, the 101st refused unencrypted"; store and AppState 101st tests | pass |
| I31 | Retries survive restart | "queued draft survives a database restart"; "failed encrypted envelope persists and retry reuses its key" | pass |
| I31 | Concurrent flushes coalesce | **New** "overlapping flush requests coalesce into one sender" (peak 1, no duplicate send) | pass |
| I31 | 404/409/413/422/507 terminal, kept for copy/discard, not resent | **New** "<status> is terminal: kept for copy or discard, never resent" (5 cases) | pass |
| I31 | 401 signs out, keeps the accepted row | **New** "401 signs out but keeps the accepted envelope for reauthentication" | pass |
| I31 | Accurate quota copy | **New** 507 case (`apiErrorStorageFull`); "quota copy names the cause and the fix" | pass |
| I31 | Second enqueue path (MLS payloads) | capacity check precedes both branches (inspection); MLS path untested with the native library | no test |
| I32 | No false logged-out flash | **New** `session_switch_test.dart` "restoring a session never shows a ready, signed-out state" | pass |
| I32 | No old-account write after logout/switch | **New** held-page test above | pass |
| I32 | No live socket after teardown | `sync_service_test.dart` dispose tests (3) | pass |
| I32 | No cursor change after a failed restore | "restore failure enters recovery without resetting the cursor" | pass |
| I35 | One sweep drains 1,200 per class | **New** `internal/app/retention_drain_test.go` TestRetentionSweepDrains1200RowsPerClass (messages+attachments, calls, sessions, blob deletions) | pass |
| I35 | Cancellation stops promptly; work and time ceilings | **New** TestRetentionDrainStopsAtCancellationAndWorkCeiling, TestRetentionSweeperStopsPromptlyOnCancellation | pass |
| I35 | Attachment rows and blobs consistent | **New** TestRetentionAttachmentRowsAndBlobsStayConsistent (real blob files, live/expired/orphan/in-flight) | pass |
| I35 | Sustained ingest below the 1,200-row / one-interval target | **New** TestRetentionSustainedIngestStaysBelowBacklogTarget | pass |
| I35 | Backlog metric reads only prunable rows | **New** TestRetentionBacklogCountsOnlyRowsTheSweepCanPrune | pass (after fix 1) |
| I36 | Fanout failure cannot leave a committed message | **New** `internal/storage/message_fanout_test.go` TestFanoutFailureRollsBackTheCommittedMessage (wake-job insert fault; retry is a fresh commit); TestCreateUsesRecipientsReturnedByCommit | pass |
| I36 | 100-target burst within worker/socket bounds | **New** `internal/app/push_burst_test.go` TestPushWakeHundredTargetBurstStaysWithinBounds (64 per pass, peak 8) | pass |
| I36 | Restart and partial provider failure keep wake work | TestPushWakeCancellationLeavesJobForLeaseExpiry, TestPushWakeTransientFailureSchedulesRetry, TestPushWakeSendTimeoutSchedulesRetry | pass |
| I37 | Weak, malformed, placeholder production tokens fail | TestValidateSetupTokenUsesDecodedEntropyFloor, TestLoadRejectsWeakProductionSetupToken, TestValidateServeProductionPosture, TestProductionSetupTokenIsRequiredOnlyUntilOwnerExists | pass |
| I37 | Generated tokens work | TestGenerateSetupTokenProducesValidToken | pass |
| I37 | Fixed-size hash comparison | **New** `internal/httpapi/setup_token_compare_test.go` TestSetupTokenAcceptsOnlyTheExactToken (prefix, extension, 64 KiB…); timing not measured | pass (behavioural) |
| I37 | Full tables neither fail open nor lock out | `login_backoff_test.go` (2); TestRateLimiterEvictsInsteadOfRefusingNewClients; TestLoginBackoffIsBoundedAndAccountPrivacySafe | pass |
| I37 | Reauth CPU/guessing budget | **New** TestRecoveryGuessesHitTheCredentialRateLimit (reauth shares the spent budget → 429) | pass |
| I37 | T37C plumbing | TestLegacyBcryptHashNeedsMigration, BenchmarkPasswordVerificationCosts, TestLoadPasswordCostRange, TestSessionIdleTouchKeepsAbsoluteLifetimeBounded | pass (rotation deferred) |
| I38 | Token without recent auth rejected | TestAccountExportRequiresRecentAuthentication | pass |
| I38 | No reusable secret; schema v2 | TestMessageMarkersSyncSearchExportAndMembershipGuards; live `api_contract_test.dart` | pass |
| I38 | Audit event recorded; failed audit withholds export | **New** `internal/httpapi/export_audit_test.go` TestAccountExportIsAuditedAndFailsClosedWithoutTheAudit | pass |
| I38 | Client download does not log or expose the payload | **New** `account_export_test.dart` (2 tests) | pass |
| I40 T40A | Expiry guard with injected dates; release panic/overflow guards | `--self-test`; `cargo test --release` (verify rust-release) | pass |
| I40 T40B | Toolchain drift fails CI | `check-go-toolchain.sh` + injected drift | pass |
| I40 T40B | Container compiler check and labels | `docker build` | blocked (sandbox TLS proxy) |
| I40 T40C | Rename, incomplete matrix, unreviewed or mismatched commit cannot publish | `check-release-evidence_test.py`, `check-ci-evidence_test.py`, `write-release-evidence_test.py` | pass (after fix 3) |
| I40 T40D | Full gate without environment skips; dependency policy | `verify.sh` (all ten steps); `check-mobile-dependencies.sh` | pass |
| QA01 | All fixture classes; fixture failure and missing interpreter fail the wrappers | Fixture suites; `test.sh` probes | pass (`test.ps1` not executed) |
| QA04 | Every listed attachment case on the real native library | `attachment_crypto_test.dart`, 11 tests | pass |

## Residual blockers

- T40B container artifact: needs a network path whose TLS CA the build
  container trusts (CI has one).
- `test.ps1`: needs a Windows/PowerShell run.
- I31 MLS-payload enqueue path: needs a native-library AppState test.
- T37C rotation and cost promotion remain deferred by design.
- Release readiness stays blocked until G24/G25 approval evidence exists.
