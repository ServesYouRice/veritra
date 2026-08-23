# Review of the testing-gap audit

Reviewed against commit `3ee785db9083eb67f3b16c3f83050ac3b365eb19` on
2026-08-23.

## Verdict

The existing audit is **not reliable enough to execute as a backlog**. It has
useful themes, but it was not kept revision-bound, several claims are false or
stale, many verification commands name files that do not exist, and it misses
some of the highest-risk untested code on the current tree.

The implementation board and consensus remain authoritative. The files in
this directory should be treated only as source evidence until each finding is
reconfirmed and converted into an eligible implementation task.

This was a static source-and-test review. Runtime checks could not be run:
Go, Cargo, Flutter, and a usable Python installation are absent, while the
Docker executable is installed but its engine is not running.

## Problems with the audit itself

### A1 - Authority conflict (high)

Before this review, `testing/README.md` called this directory authoritative.
That conflicts with `docs/board.md` decisions D07/D08 and `AGENTS.md`, which
make the board and consensus authoritative. The README has been corrected.

### A2 - No reviewed revision or freshness check (high)

The reports do not name a commit. They were added in `4fd6456`, after which
`19295a9` changed the release gate, server, crypto FFI, mobile storage, push,
calls, and many tests. Examples of immediately stale inventory are:

- `testing/server_testing_gaps.md:5` says Go 1.25.12; `.go-version` and
  `server/go.mod` now use 1.25.13.
- It stops migrations at 0023; the tree has migrations through 0028.
- It says there are 24 Go test files; the current tree has 27.
- It refers to `mobile/lib/push/background_push.dart`, which was deliberately
  removed.
- It says there are no accessibility tests, while
  `mobile/test/ui_accessibility_test.dart` exists and is recorded on the board.

### A3 - The traceability matrix is not executable (high)

`task_test_traceability_matrix.md` restates implementation findings as if they
were current test defects and ignores current board status. Sample bad checks:

- `test/sync_test.dart`, `test/outbox_test.dart`, `test/theme_test.dart`, and
  `test/accessibility_test.dart` do not exist.
- T42A runs `go test ./internal/webrtc/`, a package with no tests, while the
  TURN credential handler actually lives in `internal/httpapi`.
- T47 names `server/internal/app/metrics.go`, which does not exist, and uses a
  single-file `go test ./internal/app/metrics_test.go` command instead of a
  package test.
- T40B contains the placeholder `docker run ... test.sh`.

The separate orchestration plan also duplicates `implementation/WORKFLOW.md`.
It must not be used to claim tasks or override their dependency/advisor
contracts.

### A4 - Severity and scope are not reconciled (medium)

All four subsystem files label their lists "Critical" even when the board
classifies the work as external evidence, dependency-blocked, conditional, or
post-correctness measurement. The reports also propose Toxiproxy and Appium
without the required dependency/license approval, unsupported database
downgrades, and unapproved positive crypto UI paths.

## Materially wrong or incomplete claims

| Audit claim | Current evidence | Disposition |
|---|---|---|
| CR-02 says MLS/SQLite rollback boundaries are not injected. | `mobile/test/encrypted_local_store_test.dart:178` and `:204` test atomic rollback and restart across every `MlsCommitStage`; `mobile/test/app_state_test.dart:136` tests cursor/state atomicity. | Stale. A real process-kill/device test remains external, but the proposed Rust storage mock is the wrong layer because Drift owns the transaction. |
| CR-03 asks to add a panic barrier and `catch_unwind`. | `crypto/rust/src/ffi.rs:48` already wraps FFI operations; release-mode panic and overflow tests are at `:930` and `:938`. | Partly stale. Sanitizer/fuzz evidence is still missing. |
| CR-04 says malformed/foreign crypto testing is minimal without mentioning existing coverage. | `crypto/rust/src/mls.rs:482`, `mobile/test/app_payload_test.dart:33`, and `:60` cover foreign messages, context replay, unknown versions, and damaged framing. | Overstated. Parser fuzzing and a larger adversarial corpus remain valid gaps. |
| SV-02 says WebSocket tests cover only responsive clients. | `server/internal/realtime/websocket_test.go:74`, `:207`, `:239`, and `:260` cover malformed sequences, concurrent disconnect/publish, bounded slow clients, and fuzzing. | False. Half-open/real-proxy soak evidence is still absent under I48/I49. |
| SV-03 says proxy spoofing and HTTP login backoff are untested. | `server/internal/app/rate_limit_test.go:14`, `server/internal/httpapi/client_identity_test.go:14`, and `server/internal/httpapi/api_test.go:414` cover those boundaries. | Stale. Distributed load/soak is a later capacity test, not an uncovered basic invariant. |
| SV-04 describes only clean upload tests. | `server/internal/uploads/local_test.go:36`, `:61`, and `:71`; `server/internal/httpapi/content_handlers_test.go:29`; and `server/internal/storage/blob_deletion_store_test.go:12` cover failed/interrupted writes, corruption, ranges, and deletion retries. | Mostly false. Disk-full and full lifecycle drills remain valid external/operations cases. |
| SV-05 locates TURN generation in `internal/webrtc` and describes in-memory rooms. | TURN HMAC generation is in `server/internal/httpapi/call_sync_handlers.go:19`; calls are persisted and pruned in `server/internal/storage/content_store.go:666`. | Wrong architecture. The TURN HTTP contract and prune behavior still need focused tests. |
| SV-07 asks to roll migrations back from 0023 to 0001. | There are no down migrations by design. `server/internal/storage/sqlite_test.go:800` already verifies repeat application and checksum tamper rejection; migrations now end at 0028. | Invalid remediation. Test upgrades from historical fixtures and failed-migration atomicity instead. |
| MB-01 says outbox tests are only in memory. | `mobile/test/encrypted_local_store_test.dart:131`, `:146`, and `:164`, plus `mobile/test/app_state_test.dart:279` and `:342`, cover concurrent durable writes, the 101st-item boundary, restart, and retry identity. | Stale. OS process-death evidence is still needed on devices. |
| MB-02 says wrong-key behavior is untested. | `mobile/test/encrypted_local_store_test.dart:111` tests the wrong key and `:124` tests corrupt legacy state. | Partly false. Missing-key recovery and device-lock behavior still belong to I39/G24. |
| MB-03 targets a background Dart isolate and requires a local notification. | That entrypoint was removed; native code records a generic wake generation and foreground Dart acknowledges it. Message display would conflict with generic push unless separately approved. | Invalid design target. Test the platform-channel generation/acknowledgement contract instead. |
| MB-04 requires crypto actions to appear with `TestCryptoService`. | The board says reply/edit/delete/reaction/attachment/safety UI stays unavailable until reviewed MLS activation. The attachment button is intentionally disabled at `mobile/lib/features/chat/chat_screen.dart:793`. | Unsafe acceptance criterion. Only the fail-closed state is eligible now. |
| MB-05 says no accessibility or Semantics tests exist. | `mobile/test/ui_accessibility_test.dart` covers semantics and 320dp/200% text; `mobile/test/chat_visuals_test.dart:99` covers control contrast. | False. Goldens and real TalkBack/VoiceOver evidence are still missing. |
| E2E-04 says `backup_service.dart` has unit tests. | No mobile test references `BackupService` or `AttachmentCryptoService`. | False premise; this is a larger gap than reported. |
| E2E-06 says the release gate is marker-only and lacks a positive validator. | `scripts/check-release-evidence.py` implements positive, commit-bound approval checks and `scripts/check-release-evidence_test.py` has adversarial fixtures. | Stale, but the test script is not wired into CI; see M4. |

## High-value findings the audit missed

### M1 - Mobile/server call contract is already inconsistent

Severity: **High, conditional under D03/T42B**.

The server requires a positive `expected_version` on every call transition at
`server/internal/httpapi/call_sync_handlers.go:78-92`. The mobile client:

- does not parse or store the server's `version` or `invited_account_id` in
  `CallSession` (`mobile/lib/core/models.dart:487`);
- does not accept or send `expected_version` in
  `ApiClient.transitionCall` (`mobile/lib/core/api_client.dart:566`); and
- invokes that incompatible method from `mobile/lib/calls/call_service.dart`.

No HTTP or live Dart/Go contract test exercises call creation and transition,
so the existing suite can pass while every mobile transition returns
`invalid_call_version`. Before T42B activation, add a full call contract test
covering create, answer, retry, stale CAS, end, and model round-trip. Do not add
native permissions or activate calls before the pending design approval.

### M2 - Mobile attachment and backup crypto pipelines have no tests

Severity: **High, release-gated**.

There are no direct tests for:

- `AttachmentCryptoService.encryptFile/decryptFile`
  (`mobile/lib/crypto/attachment_crypto.dart:46` and `:124`); or
- `BackupService.createAndUpload/recover`
  (`mobile/lib/crypto/backup_service.dart:22` and `:93`).

The Rust chunk test does not cover Dart framing, manifests, temp-file cleanup,
cancellation, truncation/extension, wrong key/context, destination atomicity,
upload interruption, recovery-code parsing, or restore failure. Add boundary
and restart tests before exposing attachments; schedule backup tests under
dependency-blocked I45 rather than bypassing its I29/I39 dependencies.

### M3 - Push delivery implementations lack focused failure tests

Severity: **High, conditional under D03/I41**.

Storage job claiming/retry has coverage in `sqlite_test.go`, but there are no
focused tests for `App.drainPushWakeBatch/deliverPushWake`, FCM/APNs provider
request construction and response classification, WebPush target/SSRF
validation, or token refresh/cache behavior. `server/internal/push/push_test.go`
only asserts the generic payload.

The active Flutter `PlatformMobilePushService` also has no MethodChannel/
EventChannel tests for malformed events, provider selection, wake generations,
or acknowledgement races. `app_state_test.dart` covers only a fake wake path.

### M4 - Existing adversarial release-policy tests are never executed

Severity: **High, release gate**.

`scripts/check-release-evidence_test.py` and
`scripts/check-dart-retractions_test.py` are not invoked by
`.github/workflows/ci.yml`, `scripts/test.*`, or `scripts/verify.sh`. Thus the
tests cited as evidence can silently rot. `check-ci-evidence.py` and
`write-release-evidence.py` also have no dedicated fixture tests.

Wire these offline tests into the fast suite and CI, and add success/failure
fixtures for CI evidence selection and manifest generation.

### M5 - Migration testing needs historical fixtures, not downgrades

Severity: **Medium**.

Clean-database migration and checksum idempotency are covered, but there is no
fixture-driven upgrade from representative pre-0021/pre-0024/pre-0028 data or
an injected failing migration proving that schema and migration-record changes
roll back together. This matters for MLS messages, recovery capabilities,
push jobs, session lifetimes, and call authorization.

### M6 - Coverage is collected but not used as a regression gate

Severity: **Medium**.

CI uploads Go and Flutter coverage, but it has no total, package, or changed-code
threshold, and Rust has no coverage artifact. A threshold is not a substitute
for invariant tests, but the current setup allows large untested services to
land without any automated signal. Establish a measured baseline first, then
fail only on justified regression from that baseline.

### M7 - The protected iOS job no longer proves a release-device build

Severity: **High release-evidence gap, currently contained by G24/G25**.

`.github/workflows/ci.yml:137` now runs
`flutter build ios --simulator --debug`. Commit `3ee785d` correctly records why
an unsigned release-device build cannot satisfy the push entitlement without
Apple credentials, but `check-release-evidence.py` still treats any
`mobile-ios: success` result as the protected iOS job. The evidence schema does
not distinguish a debug simulator compile from a signed release-device build.

This does not currently open the production gate because G24/G25 approval is
still absent. Before release, make the evidence type explicit: keep simulator
CI as a fast compile check, and bind the external signed device artifact and
test matrix to the candidate commit under G24. A debug simulator success must
not be presented as release-build evidence.

## Valid themes to retain

The following ideas remain useful after rewriting them against the current
tree and board status:

- golden screenshots plus signed-device TalkBack/VoiceOver evidence (G24/I43);
- a live multi-device, multi-stack MLS lifecycle and device-link flow before
  activation (G24/G25), while acknowledging existing Rust two-device tests;
- sanitizer/fuzz coverage for FFI and MLS parsing, scoped to supported
  toolchains rather than promising Miri/TSAN without feasibility proof;
- targeted log-privacy enforcement, preferably semantic/sentinel tests plus a
  reviewed static rule rather than a fragile forbidden-word AST scan; and
- network chaos, soak, and benchmark work only under I47-I49 after correctness
  blockers and explicit capacity targets.

## Recommended order

1. Keep these reports non-authoritative and revision-bound.
2. Wire the existing release-policy test scripts into CI.
3. Separate simulator-compile evidence from signed iOS release evidence.
4. Add the call HTTP/live-client contract test before any T42B activation.
5. Add attachment pipeline tests; take backup tests only when I45 is eligible.
6. Add push worker/provider/platform-bridge tests under I41.
7. Complete the already-recorded golden, real-device, and independent-review
   evidence without weakening `PM_CRYPTO_UNAVAILABLE`.
