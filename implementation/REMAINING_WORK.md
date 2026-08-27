# Implementation and verification queue

This is the only derived execution file for unfinished Veritra work. It
combines the former implementation index, workflow, task contracts, and
reviewed testing follow-ups.

[`docs/board.md`](../docs/board.md) alone owns status and eligibility.
[`docs/audit-consensus.md`](../docs/audit-consensus.md) owns scope, ordering,
and acceptance decisions. This file may make those decisions executable, but
it cannot override them.

Production messaging remains **NO-GO**. Never remove
`PM_CRYPTO_UNAVAILABLE` or replace `UnavailableCryptoService` before G25 is
complete. Completed contracts and superseded testing reports remain available
in Git history through `bfb3922`; do not recover them unless a current card
names an exact revision and path.

## Working protocol

1. Read `AGENTS.md`, `docs/board.md`, and the selected section below.
2. Verify every dependency against the board and check the current worktree for
   overlapping ownership.
3. Claim one eligible canonical card on the board before product edits. QA
   children never create eligibility by themselves.
4. Read only the selected card's consensus section, named source paths, and
   relevant tests. Confirm the gap against current code.
5. Use the required advisor checkpoint before making a security, MLS ordering,
   migration, recovery, credential, platform-policy, artifact-trust, or
   release-gate decision.
6. Implement the smallest complete change, run narrow checks first, then all
   integration checks named by the card.
7. Review the diff against `AGENTS.md`, update the board and consensus when
   their truth changes, and bind evidence to the actual commit.

Stop before editing when work needs an unapproved product/protocol choice, a
new dependency, a destructive schema migration, credentials, an external
deployment, release publication, or a weaker privacy/crypto boundary.

### Model and coordination rules

- **Strong:** protocol, security-boundary, migration, recovery, and release
  work.
- **Balanced+advisor:** bounded implementation with a Strong review at the
  checkpoint named by the card.
- **Balanced:** isolated UI, tests, or measured optimization with an explicit
  contract.
- One coordinator owns board and consensus updates. Parallel work must have
  disjoint write sets; advice does not transfer implementation ownership.

### Required handoff

```text
Task: TXX or QAXX
Result: complete | stale | blocked
Confirmed cause: <one sentence with code path>
Changed files: <paths>
Checks: <command and result>
Acceptance: <each criterion pass/fail>
Security/privacy review: <what was checked>
Residual blockers: <none or exact blocker>
Advisor: <not required, or question + adopted/rejected advice>
```

`Complete` means every acceptance criterion and required check passed.
Inspection never substitutes for a required runtime, signed-device, or
external check.

## Current routing snapshot

Recheck the board before every claim. The model column replaces the repeated
"needs higher model assistance" annotations from the former indexes.

| Card | Routing | Model | Depends on |
|---|---|---|---|
| T33 | Blocked | Strong | I30 verification |
| T34 | Blocked | Strong | I31 pattern verification |
| T37C | Partial; policy/toolchain deferred | Strong | Approval and benchmark evidence |
| T39 | Blocked | Strong | I32 verification |
| T41 | Blocked; conditional under D03 | Balanced+advisor | I36 verification |
| T42B | Design claimed; native edits blocked pending approval | Strong | Explicit platform-design approval |
| T43C | Implementation present; automated/device evidence remains | Balanced+advisor | Toolchain and G24 environment |
| T44A-C | Prepared after release blockers | Balanced | Release blockers |
| T45A-C | Blocked under D02 | Strong | I29, I39, then T45A ordering |
| T46 | Prepared after release blockers | Balanced+advisor | Release blockers; coordinate I40/T45B |
| T47 | Prepared; conditional for private alpha | Balanced+advisor | I35 and I36 verification |
| T48A-B | Prepared | Balanced+advisor / Strong | I32, then T48A |
| T49A-D | Measure after correctness work | Balanced / Strong for T49D | Correctness cards and T47 where named |
| T50 | Deferred | Strong after trigger | D06, mobile release, product trigger |
| G24 | External | Coordinator/platform specialists | Code blockers, hardware, signing, providers, TURN |
| G25 | External | Independent reviewer | G24, G27, all release blockers |
| G27 | Upstream/review blocked | Strong | Stable coordinated release or approved exception review |

### Reviewed QA follow-ups

The testing-gap review was bound to `3ee785d`. The original reports contained
stale inventory and invalid commands, so only QA01-QA10 below survive. These
are children of canonical cards and cannot bypass their dependencies.

| QA | Canonical owner | Routing |
|---|---|---|
| QA01 | I40/T40C/T40D | Working-tree implementation present on `gemini-implementation`; verify before recording |
| QA02 | I40/G24 | Blocked until evidence-schema approval; QA01 first |
| QA03 | I42/T42A | Working-tree implementation present on `gemini-implementation`; verify before recording |
| QA04 | I17/G24 | Working-tree implementation present on `gemini-implementation`; verify native-library execution |
| QA05 | T45C | Blocked by I29, I39, and T45A |
| QA06 | T41 | Blocked until I41 is eligible |
| QA07 | T41 | Blocked until I41 and QA06 are eligible |
| QA08 | T41 | Working-tree implementation present on `gemini-implementation`; parent remains blocked |
| QA09 | T45A | Blocked by I29 and I39 |
| QA10 | I40/T47 | Working-tree implementation present on `gemini-implementation`; verify approved floors/tooling status |

Do not run QA01, QA02, and QA10 concurrently because their CI/script write
sets overlap. Do not run QA04 and QA05 concurrently.

## Release-blocking and dependent implementation

### T33 — Poison-event and stale-device recovery

**Source/model:** I33; LOG-08/PERF-03; L2/L9. Strong, with mandatory review of
tombstone policy and MLS fail-closed behavior. Blocked by I30 verification.

**Scope:** In mobile sync state/API models and the matching server sync/message
paths, introduce typed per-event failures and durable recovery states; permit a
tombstone only for proven-expired application data; batch and deduplicate
repair; map expired cursors to `device_recovery_required` and approved relink,
state-transfer, or backup choices.

**Guardrails:** Missing or malformed MLS control, network/auth failure, and MLS
state failure never advance the cursor. Recovery never becomes a cursor jump.

**Accept/check:** Prove no poison loop or skipped MLS work, bounded reconnect
repair, and explicit stale-device recovery.

```sh
cd mobile && flutter test test/app_state_test.dart test/api_contract_test.dart
cd server && go test ./internal/httpapi ./internal/storage
```

### T34 — Reliable MLS control outbox

**Source/model:** I34; LOG-06/TEST-03; L3. Strong, with mandatory review of
per-group ordering and terminal semantics. Blocked until the I31 worker pattern
is verified.

**Scope:** Reuse the durable worker states without conflating application and
MLS policy; persist attempts and next retry; serialize by group; isolate a
failed group while unrelated groups progress; add connectivity/timer wake and
revocation restart handling.

**Guardrails:** Never delete a terminal control item to unblock later work in
the same group. Existing revocation drains before another transition.

**Accept/check:** Transient, permanent, restart, and revocation tests preserve
ordering without duplicate transitions or unhandled futures.

```sh
cd mobile && flutter test test/app_state_test.dart test/encrypted_local_store_test.dart
cd server && go test ./internal/httpapi ./internal/storage
```

### T37C — Password-cost migration and session rotation

**Source/model:** I37; S4/S11. Strong, with approval before changing KDF or
session policy. The safe migration/idle plumbing exists; cost promotion and
rotation remain deferred.

**Scope:** Benchmark password verification, set an approved target, implement
versioned rehash-on-success or equivalent migration, and define idle/absolute
session lifetime plus rotation/revocation behavior.

**Guardrails:** No KDF switch without migration, rollback, and measured cost.
Rotation cannot leave two indefinitely valid credentials or break revocation.

**Accept/check:** Legacy credentials migrate without plaintext handling; old
rotated/revoked sessions fail; concurrent rotation and expiry are covered.

```sh
cd server && go test ./internal/auth ./internal/httpapi ./internal/storage
```

### T39 — Fail-closed encrypted database-key recovery

**Source/model:** I39; SEC-05; L7. Strong, with mandatory review of the
recovery/reset state machine and final diff. Blocked by I32 verification and
blocks T45A/T45C.

**Scope:** Reproduce secure-storage failure classes, preserve the database and
key metadata, map failures to typed `recoveryRequired`, and allow only approved
relink/backup recovery or an explicitly confirmed destructive reset.

**Guardrails:** Never generate a replacement key over existing encrypted data,
delete silently, or expose key material in diagnostics.

**Accept/check:** Wrong, missing, corrupt, and interrupted recovery cases all
preserve the original database.

```sh
cd mobile && flutter test test/encrypted_local_store_test.dart test/app_state_test.dart
```

### T41 — Push registration and platform readiness

**Source/model:** I41; LOG-09/UI-06/NTH-01/NTH-05; S12/H6.
Balanced+advisor. Conditional under D03 and blocked by I36 verification.

**Scope:** In the mobile push service, platform configuration, settings UI,
native manifests, and server push package, model provider-specific
configuration and typed state; handle registration/rotation/revocation for
FCM, APNs, and UnifiedPush/WebPush; add Android 13+ permission, correct iOS
copy, generic test wake, and privacy-safe diagnostics.

**Guardrails:** FCM does not require VAPID. Push and diagnostics never expose
sender/content, endpoint, auth secret, token, message ID, or ciphertext. Rich
notifications remain deferred.

**Accept/check:** Provider-only and mixed configurations work; denials and
provider errors are actionable without leaks; the G24 wake matrix is ready.

```sh
cd mobile && flutter test test/platform_config_test.dart test/ui_actionable_test.dart test/api_contract_test.dart
cd server && go test ./internal/push ./internal/httpapi
```

#### QA06 — Server push-provider contracts

When T41 is eligible, use generated in-memory keys and injected transports to
test FCM/APNs/WebPush request bodies and headers, bounded malformed responses,
token/JWT refresh, provider routing, forbidden WebPush targets/redirects,
cancellation, and permanent versus retryable errors. No external request or
new provider dependency is allowed. Production seams/error changes require
advisor review of SSRF, generic-payload, retry, and secret handling.

```sh
cd server && go test -race ./internal/push
cd server && go test ./internal/app ./internal/httpapi
```

#### QA07 — Durable push-delivery outcomes

After QA06, seed temporary SQLite jobs and directly test the app worker for
success, gone/invalid target, transient failure, timeout, cancellation,
missing subscription, and injected completion/retry/retire failures. Assert
durable state, counters, bounded concurrency, and absence of identifier/secret
sentinels from logs and metric labels. Retry timing, leases, store interfaces,
and schema require advisor approval.

```sh
cd server && go test -race ./internal/app ./internal/storage ./internal/push
```

#### QA08 — Flutter push bridge verification

A working-tree test exists at `mobile/test/push_service_test.dart`. Verify the
exact MethodChannel/EventChannel operations, typed endpoint/unregister/generic
wake events, pending-generation acknowledgement, malformed input, duplicate or
non-positive generations, event-after-dispose behavior, and handler cleanup.
Do not add background isolates, local content notifications, or native edits.

```sh
cd mobile && flutter test test/push_service_test.dart test/app_state_test.dart test/platform_config_test.dart
cd mobile && flutter analyze
```

### T42B — Native incoming and active-call lifecycle

**Source/model:** I42; R13/R14. Strong. Design-stage work is claimed, but native
edits require explicit approval before architecture, permissions, or
entitlements are chosen.

**Scope:** Document incoming, active, terminated, and denied states; implement
the approved iOS/Android lifecycle; fetch encrypted signaling locally after a
generic wake; test denied permission, background/terminated, lock screen, and
network changes.

**Guardrails:** Push contains no identity or call content. PushKit, if chosen,
must satisfy current CallKit policy. Declare only the Android service types and
permissions actually used.

**Accept/check:** Platform lifecycle is approved and policy-compliant; config
tests pass; the real-device/TURN matrix is executable; no payload leaks.

```sh
cd mobile && flutter test test/platform_config_test.dart test/ui_actionable_test.dart
```

#### QA03 — Mobile/server call contract verification

Working-tree changes add server-required `version`, `invited_account_id`, and
positive `expected_version` handling. Verify model parsing and exact JSON,
latest-session ownership in `NativeCallService`, and a live two-account flow:
create, invitee/version assertion, answer, idempotent retry, rejected stale or
unauthorized transition, end, and final round-trip. Native platform files and
crypto gates stay untouched.

```sh
cd server && go test ./internal/httpapi ./internal/storage
cd mobile && flutter test test/api_contract_test.dart
./scripts/test-api-contracts.sh
cd mobile && flutter analyze
```

### T43C — Responsive, semantic, and visual evidence

**Source/model:** I43; UI-04/UI-05/UI-07/TEST-04; U16/U20/R6/H5.
Balanced+advisor. Implementation is present; toolchain, goldens, and G24 device
evidence remain.

**Scope:** Recheck semantic labels, 320 px, landscape/tablet, 200% text scale,
traversal, and reduced motion; fix only reproduced failures; add missing
representative light/dark goldens; bind automated evidence to the commit and
prepare the manual checklist.

**Guardrails:** Automated tests never claim TalkBack, VoiceOver, or manual
rendering evidence.

```sh
cd mobile && flutter test
cd mobile && flutter analyze
cd server && go test ./websetup
```

### T45A — Backup/restore and migration atomicity

**Source/model:** I45; DEP-04/DEP-05/DEP-10/TEST-08; R5. Strong, with review
before activation/rollback design and after fault tests. Blocked by I29 and
T39; blocks T45B/T45C.

**Scope:** Replace colliding staging paths with validated invocation-owned
staging; add preflight/provenance markers, fsync/journaled activation, explicit
DB/blob/SQLite-companion rollback boundaries, and fault injection for disk
full, permission failure, corruption, and process death.

**Guardrails:** Never recursively clean an unresolved path. Incompatible
schema rollback means verified restore, never an invented down migration.

```sh
cd server && go test ./cmd/messenger-server ./internal/storage
```

#### QA09 — Historical upgrades and failed-migration rollback

When T45A is eligible, build databases using actual migrations through 0020,
0023, and 0027; seed representative synthetic ciphertext rows; reopen and
upgrade to current; verify MLS/recovery, durable-push, session-lifetime, and
call-authorization defaults/constraints; reapply; and inject a failing
migration to prove its schema mutation and record roll back atomically. Test
files only; no migration SQL or down migration changes without advisor review.

```sh
cd server && go test -race ./internal/storage
cd server && go test ./cmd/messenger-server
```

### T45B — Scheduled off-host backups and restore drills

**Source/model:** I45; DEP-09/NTH-04; R8/H1. Strong, with review of secrets,
retention, and recovery objectives. Blocked by T45A; coordinate deployment
files with T46 and metrics with T47.

**Scope:** Define schedule, retention, off-host copy, and recovery objective;
add a supported timer/job using file secrets; emit privacy-safe backup-age and
failure metrics; automate disposable clean-host DB/blob restores.

**Guardrails:** Destination credentials stay out of logs and environment dumps
where avoidable. A backup is not successful until restore is verified.

```sh
cd server && go test ./cmd/messenger-server ./internal/app ./internal/storage
```

### T45C — Reviewed mobile backup/recovery workflow

**Source/model:** I45; NTH-04; U18/H1. Strong, with mandatory review of key
ownership, recovery capability, and reset UX. Blocked by I29, T39, and T45A.

**Scope:** Specify backup creation/capability transfer/restore states; implement
status, age, create/rotate, restore, interruption/resume, and typed errors; test
wrong key, corrupt backup, missing blob, and restart.

**Guardrails:** User-held decryption material never reaches the server or logs.
Capability handling follows I29; key failure follows T39; destructive reset is
explicit and is never presented as recovery.

```sh
cd mobile && flutter test test/app_state_test.dart test/encrypted_local_store_test.dart test/ui_actionable_test.dart
```

#### QA05 — Mobile backup crypto pipeline

When dependencies complete, use `MemoryLocalStore`, a loopback HTTP server,
temporary app support, and the real pinned Rust library to test create/upload/
recover, missing state, boundary sizes, upload interruption, malformed code,
wrong key/token, bad magic/bounds/chunks, truncation/extension/authentication,
restore rollback, and owned-file cleanup. No recovery design or UI change is
authorized by this child; production edits need advisor approval.

```sh
cargo build --manifest-path crypto/rust/Cargo.toml --locked --release
cd mobile && VERITRA_CRYPTO_LIBRARY=../crypto/rust/target/release/libprivate_messenger_crypto.so flutter test test/backup_service_test.dart test/encrypted_local_store_test.dart
cd mobile && flutter analyze
```

Use the platform-equivalent native-library filename and run the repository test
wrapper. Missing native tooling remains a blocker.

## Prepared follow-up packages

These remain valid, but release blockers take priority unless a dependency
requires otherwise.

### T44A — Bounded API decoding and stale/error containment

**Source/model:** I44 API/state scope; LOG-13/SEC-10/UI-09/UI-10/NTH-08/NTH-11;
L8/L11/L14/L15. Balanced; ask an advisor only for API schema or security
boundary changes.

Inventory server error codes; define typed client mappings; bound error and
download bodies, casts, timestamps, and pagination; preserve safe stale state
with retry; add versioned contract fixtures. Raw implementation errors and
response/ciphertext bodies never reach UI or logs.

```sh
cd mobile && flutter test test/api_contract_test.dart test/app_state_test.dart test/ui_actionable_test.dart
./scripts/test-api-contracts.sh
```

### T44B — Conversation, list, and form quality

**Source/model:** I44 interaction scope; UI-11; U5/U6/U7/U8/U11/U19/U23.
Balanced.

Add locale-aware relative list time, correct breakpoints, jump-to-live without
history loss, focusable explanations for gated controls, inline validation,
keyboard/composer-length behavior, and only already-supported row actions.
Crypto-gated actions remain unavailable; no plaintext drafts/search are added.

```sh
cd mobile && flutter test test/ui_features_test.dart test/ui_actionable_test.dart test/chat_visuals_test.dart
cd mobile && flutter analyze
```

### T44C — Localization, identity, settings, and link coherence

**Source/model:** I44 product scope; UI-12/NTH-09; U12/U13/U14/U17/U21;
R10/R11. Balanced; advisor required for dependency/license or link-trust
changes.

Reconcile product identity; add localization and locale-aware dates; expose
About/Licenses and persistent System/Light/Dark appearance; confirm destructive
actions; safely support device-link URIs on both platforms or stop emitting
them. New dependencies require notice review; links validate origin/capability.

```sh
cd mobile && flutter test test/platform_config_test.dart test/ui_remaining_test.dart test/ui_fixes_test.dart
cd mobile && flutter analyze
```

### T46 — Supported deployment hardening

**Source/model:** I46; DEP-03/DEP-07/DEP-08/DEP-11; R4/R9.
Balanced+advisor for artifact trust, secret delivery, and sandbox compatibility.

Consume the tested versioned image digest in supported Compose, canonicalize
and lock actual overridden DB/blob resources, add file-secret support,
reconcile shutdown/drain/upload deadlines, and add compatible container and
systemd least-privilege restrictions. Mutable-source builds, broad filesystem
capability, and secret-bearing config/log output are forbidden.

```sh
cd server && go test ./cmd/messenger-server ./internal/app
./scripts/test.sh
```

Acceptance requires hardened startup, upload, backup, restore, push, and TURN
smoke without breaking SQLite/local-blob writes.

### T47 — Privacy-safe observability and capacity contract

**Source/model:** I47; DEP-12/TEST-07/PERF-10/ARCH-08/NTH-03; H4.
Balanced+advisor for metric privacy, workload model, and targets. Depends on
I35/I36 verification and blocks T49D.

Define representative datasets, small-instance host tiers, and p95/p99/backlog
targets; add queue/writer/disk/backup-age/provider-result metrics; build
reproducible seed/load/soak and restart/provider-stall scenarios; add alerts and
runbooks. Metrics never label users, accounts, conversations, tokens,
endpoints, message IDs, or ciphertext identifiers.

```sh
cd server && go test ./internal/app ./internal/storage ./internal/push ./internal/realtime
```

### T48A — Transport lifecycle, routes, and log privacy

**Source/model:** I48; LOG-12/SEC-06/SEC-09; L16/L17. Balanced+advisor for
teardown races and trusted-proxy threat model. Depends on I32 and blocks T48B.

Make socket connect/dispose awaitable, send close frames, deliberately
normalize supported subroutes, log matched patterns with a constant fallback,
and reject unsafe proxy ranges/hops. Delayed-connect teardown must leave no
authenticated socket; logs contain no dynamic IDs, tokens, endpoints, bodies,
or ciphertext.

```sh
cd server && go test ./internal/realtime ./internal/httpapi ./internal/app
cd mobile && flutter test test/app_state_test.dart
```

### T48B — WebSocket parser and LAN TLS assurance

**Source/model:** I48; S7/S8. Strong, with approval before parser replacement
or trust-model choice. Depends on T48A.

Define parser bounds; add malformed/fragment/control-frame fuzzing; run Autobahn
or equivalent protocol evidence; retain or replace the parser based on that
evidence; implement a supported mobile CA/certificate path for LAN installs.
No blanket TLS bypass or unapproved TOFU is allowed. Any dependency change
requires license, notices, and security review.

```sh
cd server && go test ./internal/realtime ./internal/httpapi
cd server && go test -fuzz=Fuzz -fuzztime=30s ./internal/realtime
```

## Measurement before optimization

No architecture or storage replacement is authorized by an audit label alone.
Record dataset, hardware/toolchain, target, query/profile evidence, and current
invariants; create a separate child only for a measured miss.

### T49A — Server read-model and write-lock benchmarks

Measure conversation reads, sync bounds, realtime registration, device-seen
writes, and typing-state growth with representative datasets. Preserve SQLite,
authorization, durability, and retention absent measured failure.

```sh
cd server && go test -run '^$' -bench . -benchmem ./internal/storage ./internal/realtime
```

### T49B — Blob, quota, and layout benchmarks

Measure full/range verification, upload admission, quota SQL, disk use, and
directory reconciliation, including oversized and concurrent uploads. Never
weaken integrity or race-safe pre-admission quota enforcement. Advisor approval
is required before changing verification, quota accounting, or blob layout.

```sh
cd server && go test -run '^$' -bench . -benchmem ./internal/storage ./internal/uploads
```

### T49C — Mobile state and render benchmarks

After T30B/I32 verification, profile startup, sync burst, scrolling, repair,
tab switching, root rebuilds, theme recreation, per-bubble lookups, and state
loss on representative low-end devices. Account ownership, atomicity, tab/
history state, and crypto-gated honesty outrank render optimization.

```sh
cd mobile && flutter test
cd mobile && flutter analyze
```

### T49D — Evidence-backed admission limits

After T47, model resource and abuse cost, propose bounded operator-configurable
account limits, and obtain Strong review before implementation. Enforce limits
transactionally without revealing other accounts' state; defaults must derive
from measured supported host tiers.

```sh
cd server && go test ./internal/httpapi ./internal/storage
```

## Verification follow-ups for implemented work

### QA01 — Release-policy fixtures

Working-tree changes add offline standard-library fixtures for CI evidence and
manifest construction and wire the existing retraction/evidence suites into
canonical runners. Verify malformed, wrong-commit, incomplete/skipped,
multiple-run, approval-shape, propagation, image/digest, and valid cases; prove
a fixture failure makes wrappers and CI fail. Do not change required jobs or
evidence semantics without advisor approval.

```sh
python3 scripts/check-release-evidence_test.py
python3 scripts/check-dart-retractions_test.py
python3 scripts/check-ci-evidence_test.py
python3 scripts/write-release-evidence_test.py
./scripts/test.sh
./scripts/verify.sh
```

Run the PowerShell wrapper on Windows. Missing interpreters or skipped fixtures
must fail visibly.

### QA02 — Separate simulator and signed-iOS evidence

Blocked until the coordinator approves the exact evidence schema. Keep debug
simulator CI mandatory but unable to satisfy signed-iOS evidence. The approved
schema must bind platform, artifact type, candidate commit, digest, and
provenance; missing, stale, unsigned, skipped, or malformed evidence fails
closed. Never create or store signing material or mark G24 complete.

Required fixtures cover simulator-only, unsigned, wrong commit/platform/type,
malformed digest, skipped simulator, and one valid synthetic signed artifact.

```sh
python3 scripts/check-release-evidence_test.py
python3 scripts/check-ci-evidence_test.py
python3 scripts/write-release-evidence_test.py
./scripts/release-readiness.sh
./scripts/verify.sh
```

Readiness is expected to remain blocked without real G24/G25 evidence.

### QA04 — Attachment crypto pipeline

A working-tree Rust-backed test exists at
`mobile/test/attachment_crypto_test.dart`. Verify round-trips at one byte and
around the one-MiB boundary; manifest/framing bounds; tampered ciphertext;
wrong key/conversation/action/chunk count/plaintext size; truncation/extension;
unsupported version; empty/oversized input; cancellation; and owned-file
cleanup without replacing a pre-existing destination. The context remains
`conversation_id + NUL + action_id`; no UI, algorithm, ABI, or dependency
change is authorized.

```sh
cargo build --manifest-path crypto/rust/Cargo.toml --locked --release
cd mobile && VERITRA_CRYPTO_LIBRARY=../crypto/rust/target/release/libprivate_messenger_crypto.so flutter test test/attachment_crypto_test.dart
cd mobile && flutter analyze
```

Use the platform-equivalent native-library filename and run the repository test
wrapper. A skipped native run is not acceptance.

### QA10 — Coverage baseline and regression ratchet

Working-tree changes add a dependency-free coverage parser/fixture suite and CI
integration. Verify the baseline names commit, toolchain, command, scope, and
excluded/generated files; floors are advisor-approved and fail on regression,
missing/malformed data, or missing targets; baseline changes remain explicit.
Coverage never substitutes for invariant, recovery, device, or release tests.
Rust remains unmeasured unless a pinned, licensed, approved tool is added.

```sh
cd server && go test -race -coverprofile=coverage.out ./...
cd server && go tool cover -func=coverage.out
cd mobile && flutter test --coverage
python3 scripts/check-coverage_test.py
./scripts/verify.sh
```

## External release gates

### G24 — Signed-device evidence

Freeze one candidate commit; build signed Android/iOS candidates with pinned
native crypto; generate notices, SBOM, checksums, provenance, and signatures;
then run the board's two-device functional, push, TURN, network-change,
restore, keyboard, TalkBack, VoiceOver, large-text, and reduced-motion matrix.
Record sanitized platform versions, artifact digests, and results. Never
commit signing/provider material or device identifiers. Evidence from another
commit does not count.

Run the full release workflow and `./scripts/release-readiness.sh`. Any skipped
release-required row keeps G24 pending.

### G25 — Independent review and crypto activation

Give an independent reviewer the immutable candidate, threat model, vectors,
build instructions, ABI ownership rules, and failure tests. Fix and
independently retest all critical/high findings, explicitly accept lower
residual risks, rerun G24 on the final reviewed commit, and only then change
both fail-closed crypto gates. An LLM review cannot satisfy this gate.

Run the complete release matrix, native ABI/vector suites, and
`./scripts/release-readiness.sh` against the final candidate.

### G27 — OpenMLS/HPKE advisory closure

Recheck coordinated stable upstream versions before the 2026-08-29 exception
deadline. If stable fixes exist, update the compatible graph, notices, and
SBOM, then rerun vectors, audits, ABI, and Android/iOS native builds. Do not use
a release candidate, Git dependency, private fork, broader ignore, or weaker
reachability guard without explicit approval and independent review. If no
stable fix exists, document current reachability, obtain explicit re-approval,
set a new executable expiry, and keep release blocked.

```sh
./scripts/audit-rust.sh
./scripts/verify-mobile-crypto.sh
```

## Deferred product intake

### T50 — Product and ecosystem roadmap

Nothing here is claimable before D06's mobile-release trigger and explicit
product approval. Retained themes are encrypted drafts/search, contacts,
archive/pin and trust ceremonies; trust/admin/moderation tools; multi-account,
passkeys, privacy/TLS indicators, and post-quantum readiness; privacy-safe
CLI/API work, reproducible builds, and F-Droid; desktop after mobile; and
embedding only after its E2EE decision.

Federation, PostgreSQL, S3, and NATS remain out of scope. When a trigger is
approved, re-audit current code and standards and add an exact scoped child
section here with privacy boundaries, files, dependency review, checks, and
rollback. Do not implement from old roadmap prose.
