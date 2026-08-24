# Audit consensus and implementation register

This is the authoritative disposition of the 2026-08-08 Codex and Opus
production audits. It was reconciled against `main` at
`194bd0cc660c1d9267ef973e6ab96f6db12589bb` on 2026-08-13.

The raw audits and detailed adjudication notes are preserved in Git history at
`bfb3922` and intentionally absent from the working tree. They are evidence,
not an implementation backlog. [`board.md`](board.md) owns status; this file
owns the reasoning, scope, order and acceptance checks for audit-derived cards.
Root [`implementation/`](../implementation/) derives claimable execution tasks
from those cards. It may split work but cannot change a decision here.

## Outcome

**NO-GO remains correct.** Production messaging stays fail-closed.

The audits contain 96 numbered Codex findings, 80 numbered Opus findings and
six Opus product bundles. They reduce to 22 local work packages, the existing
I24/I25/I27 release gates, and a deferred product backlog. Repeated findings
are merged by root cause rather than counted as separate defects.

The earlier statement that there are only nine blockers and everything else is
post-launch is withdrawn. Nine is the count of the clearest newly discovered
code blockers. It excludes existing crypto/review gates, signed-device
evidence, conditional push/call requirements, backup obligations from D02,
accessibility, first-run usability and supported deployment evidence.

No product fix is part of this consolidation. The next implementation prompt
must claim one Ready card from the board.

## Decision rules

- **Adopt:** the finding and proposed direction are correct.
- **Merge:** multiple findings describe one root issue; implement once.
- **Correct:** the root issue is real, but scope, severity or remedy changed.
- **Already covered:** current code/evidence already satisfies the claim; only
  a narrower residual item remains.
- **Defer:** valid work, but not required for the first mobile release.
- **Reject:** not a defect, factually false, outside this repository, or
  contrary to an approved decision.
- A release blocker must have a code fix and a regression test. A process or
  evidence finding belongs in I24/I25 unless it exposes an independently
  actionable defect.
- A broad source finding may be split only when each named card owns an explicit,
  non-overlapping sub-scope. Otherwise one card owns it.
- Performance work begins with a benchmark and a target. Do not replace
  SQLite, local blobs or the modular monolith without evidence.
- Nothing here weakens `PM_CRYPTO_UNAVAILABLE`, `UnavailableCryptoService`,
  ciphertext-only storage, generic push data or privacy-safe logging.

## Corrections agreed during reconciliation

| Source | Final decision |
|---|---|
| Codex LOG-05 / PERF-05 | Adopt, but fix only the four paged paths that do not drain. `sync_events` and `audit_events` already loop. |
| Codex SEC-01 | Adopt the leak, but use High rather than Critical because the capability exposes encrypted backup ciphertext protected by a separate user-held key, not plaintext or that key. Its logging, replay and lifetime remain release-blocking. |
| Codex UI-02 | Correct to the narrow failure window before durable enqueue. Restore the composer text; do not build draft persistence as the blocker fix. |
| Codex UI-01 | Reject as a new defect. It restates the intentional crypto gate; retain it as I25's activation rationale, not deferred product work, and keep unavailable controls explanatory. |
| Opus L6 | Correct from High/permanent to Medium/bounded. One materialized message set must still drive all prune statements. |
| Opus S2 | High is retained. Veritra itself logs the capability and the leak was reproduced, so it remains a release blocker. |
| Opus S3 | Keep Medium, but correct the attack model: entries expire; bypass requires sustained table pressure. |
| Opus R3 | The headline is false on current `main`: CI already runs `govulncheck` and `scripts/audit-rust.sh`. Retain only the missing machine-enforced exception-expiry check and broader mobile supply-chain coverage. |
| Opus R6 | Keep as missing visual/device evidence. Automated Flutter tests do not prove the screens look correct. |
| Opus R16 | Reject. A directory outside the repository is not a repository release finding. |
| Opus U1 | Adopt for both palettes. `outlineVariant` fails in dark and light; tests must also protect the narrow passing margin of `outline`. |

## Implementation order

| Wave | Cards | Why |
|---|---|---|
| 0 | I29, then I40 | Contain the live capability leak, then enforce release controls and the 2026-08-29 exception deadline before deeper implementation. |
| 1 | I30-I39 | Restore state, cursor, outbox, retention and authentication invariants. |
| 2 | I41-I43, I45 | Make the promised platform paths, accessibility and recovery credible. |
| 3 | I44, I46-I48 | Close non-blocking product, deployment and transport gaps. |
| 4 | I49 | Measure and split capacity work into evidence-backed cards. |
| External | I24, I25, I27 | Signing, real devices, independent review and upstream crypto remain external gates. |
| Deferred | I50 | Product work after the mobile release or behind an explicit trigger. |

Cards in the same wave may run in parallel only when their files do not
overlap. One coordinator owns [`board.md`](board.md).

## Ready work packages

### I29 - Recovery capability secrecy and lifecycle

**Decision:** Merge Codex SEC-01/SEC-08 with Opus S2. **High, release
blocker. No dependency.**

- Log `r.Pattern` with an `unmatched` fallback and remove path enumeration as
  the logging safety boundary.
- Replace `GET /api/v1/recovery/{token}` with a header-borne capability on a
  fixed route; place it under the credential limiter.
- Use a short-lived recovery exchange or rotate after a complete successful
  download, with an explicit expiry. Do not consume a capability before a
  resumable/ranged recovery transfer can finish.
- Document incident handling: rotate exposed capabilities and purge affected
  application and proxy logs.

**Accept when:** a sentinel capability appears in no application or configured
proxy log field, URL or error; old, expired and replayed capabilities fail;
interrupted recovery can resume only within its approved exchange; the new
route is rate-limited; no request body, key, token or ciphertext body is logged.

### I30 - One MLS-aware sync owner

**Decision:** Merge Codex LOG-01/ARCH-01/TEST-01/PERF-08. **Critical, release
blocker. No dependency.**

- Interim fix: background push records a wake marker and never advances the
  durable cursor or performs a blind full-resync jump.
- Final fix: one account-scoped engine owns ordered event processing. Event
  dedupe, MLS state, affected ciphertext and cursor commit atomically.
- Background and foreground execution must coalesce rather than race.

**Accept when:** normal plain-message and MLS pages, duplicates, interruption at
every commit boundary, cursor expiry, foreground/background overlap and account
switching prove that background work discards no application envelope and cursor
advancement cannot outrun either message persistence or MLS state.

**Implementation note (2026-08-14):** T30A removes the headless sync engine,
keeps push wakes as native persisted generation markers, gates foreground
consumption on the resumed lifecycle, and acknowledges only the generation
observed after a successful foreground drain. The required Flutter checks are
pending because Flutter is unavailable in the current workspace.

**Implementation note (T30B, 2026-08-14):** The mobile sync owner now
coalesces waiters and drains on session teardown; ordered events commit one
dedupe marker, affected ciphertext and cursor transaction at a time. Message
sync events carry immutable envelope revisions, own-sender events commit their
cursor without reprocessing local crypto, and encrypted local metadata fences
transactions to an origin/account/device/generation lease. Cursor-expiry
responses retain the cursor and expose `deviceRecoveryRequired`; they never
authorize a blind jump. Required Flutter and Go checks are pending because
those runtimes are unavailable in the workspace.

### I31 - Lossless message outbox

**Decision:** Merge Codex LOG-02/LOG-11/UI-02 and TEST-03's message-outbox scope with Opus
L1/L10/L12/U15/U22. **Critical, release blocker. No dependency.**

- Refuse capacity before encryption or MLS state advancement; never evict an
  unsent item.
- Return typed `outbox_full`; retain composer text until durable acceptance.
- Serialize flushes, schedule the earliest retry, wake on connectivity, treat
  507 as terminal and expose recovery/copy/discard for terminal items.

**Accept when:** 99/100/101 boundaries on both enqueue paths preserve the
oldest item; retries survive restart; concurrent flush requests coalesce; 401,
404, 409, 413, 422 and 507 follow their specified terminal/auth behavior; quota
failure has accurate, actionable user copy.

**Implementation note (2026-08-14):** T31 makes the encrypted outbox lossless
at its 100-envelope bound, checks capacity before MLS advancement and again in
the atomic database transition, persists local recovery drafts, and coalesces
delivery through one retry worker. 507/quota failures are terminal and expose
copy/discard recovery; 401 preserves the accepted local row for reauthentication.
The required Flutter checks are pending because Flutter is unavailable in the
current workspace.

### I32 - Account-scoped session lifecycle

**Decision:** Merge Codex LOG-03/LOG-04/UI-03/TEST-02/ARCH-06 with Opus P11.
**High, release blocker. No dependency.**

- Add explicit `initializing`, `ready` and `recoveryRequired` states.
- Serialize session transitions with a generation/cancellation token checked
  after every await and immediately before state or storage commits.
- Await sync/socket shutdown; remove the restore catch-all cursor reset.
- Bind local state ownership to canonical server origin and account/device.

**Accept when:** deterministic paused-future tests show no false logged-out
flash, no old-account write after logout/switch, no live socket after teardown
and no cursor mutation after a failed restore.

**Implementation note (T32, 2026-08-14):** AppState now exposes explicit
`initializing`, `ready` and `recoveryRequired` lifecycle states, serializes
restore/auth/session transitions, awaits sync subscription teardown, and keeps
failed restore cursors/local state intact. Account identity changes clear MLS
markers, control outbox, peer verifications and encrypted projections;
generation checks fence sync, outbox and push work. Required Flutter checks
are pending because Flutter is unavailable in the workspace.

### I33 - Poison-event and stale-device recovery

**Decision:** Merge Codex LOG-08/PERF-03 with Opus L2/L9. **High, release
blocker. Depends on I30.**

- Classify per-event failures. A missing, malformed or unavailable MLS control
  event fails closed into `recoveryRequired` without cursor advancement. Only a
  proven-expired application envelope with a documented tombstone policy may
  advance safely. Never advance on auth, network or MLS-state failure.
- Replace one-request-per-event repair with a bounded, deduplicated batch.
- Surface typed `device_recovery_required` on an expired MLS cursor. Recovery
  is relink, approved state transfer or encrypted backup—not a cursor jump.

**Accept when:** malformed/missing MLS control events enter recovery without
advancing; a proven-expired application event follows the tombstone policy;
network failure, 401, duplicate page and expired cursor tests all reach the
specified state without looping or skipping MLS work; a reconnect burst uses a
bounded, deduplicated repair request instead of one request per event.

### I34 - Reliable MLS control outbox

**Decision:** Merge Codex LOG-06 and TEST-03's MLS-control scope with Opus L3.
**High, release blocker. Reuse I31's worker pattern.**

- Add serialized delivery, durable attempts, next-attempt time, bounded
  backoff, terminal classification and connectivity wakeups.
- A terminal item must fail that conversation/device closed; it is not deleted
  merely to let later messages violate MLS ordering. Unrelated conversations
  may continue. Existing revocation work is drained before creating another
  transition.

**Accept when:** transient, permanent 4xx, restart and revocation-interruption
tests show ordered progress, no unhandled future and no duplicate state
transition; the affected group enters a recoverable failed state while an
unrelated group can continue.

### I35 - Retention and attachment-prune convergence

**Decision:** Merge Codex LOG-05/PERF-05 with Opus L5/L6; correct both scopes.
**High, release blocker. No dependency.**

- Drain `PruneExpiredContent`, `PruneCallSessions`,
  `PruneOperationalRows` and `reconcileBlobDeletions` in bounded yielding
  loops. Do not rewrite event/audit pruning that already drains.
- Materialize one message-ID set and drive message, attachment-link and blob
  deletion from it.
- Add backlog count/age metrics and a work/time ceiling.

**Accept when:** one scheduled sweep drains 1,200 eligible records per class,
cancellation stops promptly, attachment rows and blobs remain consistent and a
sustained-ingest test stays below the documented backlog target.

**Implementation note (T35, 2026-08-14):** The four bounded cleanup paths now
yield across a 64-batch/10-second sweep budget. Expired message IDs,
attachment IDs and storage keys are materialized per transaction so surviving
attachment references are preserved before blob deletion is queued. Aggregate
retention backlog/oldest-age metrics and expiry-aligned indexes are exposed;
the supported backlog target is documented in `docs/operations.md`. Required
Go checks are pending because Go is unavailable in the workspace.

### I36 - Committed-message fanout and bounded push work

**Decision:** Merge Codex LOG-07/PERF-02/ARCH-03/NTH-14 with Opus L4/P10.
**High, release blocker when push is enabled. No dependency for the minimal
fix.**

- First return recipients from the transaction that commits the message and
  sync event, removing the post-commit lookup failure window.
- Then persist privacy-minimized generic wake jobs and deliver through bounded
  per-provider workers with deadlines, retry, dedupe, expiry and metrics.

**Accept when:** an injected recipient-lookup failure cannot create a committed
message with lost fanout; 100-target bursts stay within worker/socket bounds;
restart and partial provider failure preserve eligible wake work.

**Implementation note (T36A, 2026-08-14):** The message commit path now returns
the conversation membership recipient snapshot from the same transaction that
inserts the envelope and sync event. The messaging service no longer performs a
post-commit recipient query; idempotent duplicates still return no recipients.
T36B durable wake jobs and bounded provider delivery are recorded below.
Required Go checks are pending because Go is unavailable in the workspace.

**Implementation note (T36B, 2026-08-14):** A SQLite `push_wake_jobs` outbox
now records only event/routing identifiers and subscription references in the
same message transaction. Per-provider workers claim at most 64 jobs with
opaque leases, send at most eight concurrently with 10-second deadlines, and
retry transient failures with expiry and jitter. Delivery rechecks membership,
mute/block state, device revocation and current subscription credentials before
sending; gone or invalid targets are retired only when the claimed credentials
still match. Worker lifecycle is tied to `serveCtx`, and aggregate provider
delivery/backlog metrics are exposed. Delivery is intentionally at-least-once
around a crash between provider acceptance and acknowledgement; payloads stay
generic. Required Go checks are pending because Go is unavailable in the
workspace.

### I37 - Setup and authentication hardening

**Decision:** Merge Codex SEC-04/SEC-07 with Opus S1/S3/S4/S9/S10/S11.
**High for setup-token entropy; remaining items are Medium/Low. No dependency.**

- Generate at least 32 random bytes, validate the supported encoded form and
  decoded minimum, and reject known test/placeholder values. Length alone is
  not presented as an entropy guarantee.
- Put reauthentication under credential backoff and a tighter route budget.
- Fix login-backoff full-table insertion, sweep/evict safely and meter
  occupancy without identifiers.
- Treat bcrypt cost migration, constant-time setup comparison and session
  rotation as hardening subitems; do not switch password KDFs without a
  migration design and benchmark.

**Accept when:** weak, malformed and placeholder production tokens fail
startup; generated tokens work and compare through fixed-size hashes;
full-table tests cannot fail open or lock all new users out; reauth cannot
exceed its documented CPU/guessing budget.

**Implementation note (T37A, 2026-08-14):** Production setup tokens now use
unpadded base64url with a decoded minimum of 32 bytes, reject reserved and
obviously low-diversity placeholders, and are validated during config loading,
serve validation and app startup. `setupAuthorized` compares fixed-size
SHA-256 digests. The CLI generates a CSPRNG-backed token, and deployment
guidance/CI use the supported encoding. T37C session hardening is tracked
below. Required Go checks are pending because Go is unavailable in the
workspace.

**Implementation note (T37B, 2026-08-14):** Reauthentication now shares the
strict credential route budget and applies independent salted backoff scopes
for session, account/device and source/account/device. Login failures combine
account and source/device scopes. Both bounded tables sweep expiry state and
use bounded eviction sampling under pressure, while preserving
existing blocked entries when possible; failure state does not become an
unbounded sliding lock. Aggregate occupancy and pressure-eviction metrics are
exposed without usernames, addresses, device IDs or tokens. Required Go checks
remain pending because Go is unavailable in the workspace.

**Implementation note (T37C, 2026-08-14):** The server now has an explicit
bcrypt target-cost configuration, benchmark coverage for legacy cost 10 versus
the proposed higher target, conditional rehash-on-success for login and
reauthentication, and per-session `last_used_at`/absolute-lifetime plumbing.
The default remains cost 10 because the required Go/hardware benchmark is not
available here. Active-session token rotation is deferred: invalidating the old
hash before a response can be delivered would strand current clients, so a
reviewed idempotent refresh protocol and coordinated client changes are
required before enabling it. Required Go checks remain pending.

### I38 - Safe account export

**Decision:** Merge Codex SEC-02/NTH-19 with Opus H3. **High, release blocker.
No dependency.**

- Require recent authentication and record an audit event.
- Never export live push `auth_secret` or another reusable credential.
- Define the export schema and explain that message bodies remain ciphertext.

**Accept when:** a bearer token without recent auth is rejected, exports contain
no reusable secret, schema/authorization tests pass and the client download
does not log or expose the payload.

**Implementation note (T38, 2026-08-14):** The export route now requires
recent authentication and requires its dedicated audit write to succeed. Export
manifest `v2` omits push `auth_secret` and other reusable session/recovery
capabilities, excludes raw server audit history, and preserves message
ciphertext and protocol metadata. The mobile client downloads bounded pages
into a local versioned JSON file after reauthentication; it does not log the
export body. Required Go and Flutter checks remain pending because those
toolchains are unavailable in the workspace.

### I39 - Fail-closed encrypted database key recovery

**Decision:** Merge Codex SEC-05 with Opus L7. **High, release blocker. Depends
on I32's recovery state.**

- Set secure-storage recovery to fail closed; preserve an encrypted database
  whose key cannot be read.
- Offer approved relink/backup recovery or an explicit destructive reset. Never
  silently generate a replacement key over existing data.

**Accept when:** wrong/missing/corrupt key tests preserve the database, enter
`recoveryRequired`, and require explicit confirmation before any reset.

### I40 - Release evidence and toolchain integrity

**Decision:** Merge Codex DEP-01/DEP-06/TEST-06/TEST-09/TEST-10/TEST-11/
ARCH-04/NTH-10/NTH-12/NTH-13 with Opus L18/R1/R2/R3/R7. Correct Opus R3 as
noted above. **High, release blocker. No dependency; claim immediately after
I29.**

- Use one Go toolchain source across `go.mod`, CI, release and container; test
  the actual container artifact.
- Replace negative source greps with positive, commit-bound evidence and a
  production-wiring behavior test. Release must depend on completed protected
  checks.
- Keep existing Go/Rust scans; before 2026-08-29, machine-enforce Rust exception
  expiry with deterministic expired-date coverage, then add appropriate
  Dart/Gradle/retracted-package coverage.
- Define fast versus complete verification commands and make release-required
  skips fail.

**Accept when:** a rename cannot bypass the gate; an incomplete matrix or
unreviewed commit cannot publish; toolchain drift fails CI; the 2026-08-29
exception deadline fails automatically and an injected expired date proves the
guard; the tested commit equals the packaged commit.

**Implementation note (2026-08-14):** T40A adds the parseable, UTC-pinned
exception policy and deterministic expiry guard, runs the guard in CI and
release readiness, pins the Rust release FFI profile, and adds release-mode
panic/overflow tests. The required Cargo checks remain pending because Cargo
is unavailable in the current workspace; production crypto remains fail-closed.

**Implementation note (2026-08-14):** T40B adds `.go-version` as the canonical
Go 1.25.12 pin, makes `go.mod`, setup-go, local test/lint fallbacks and the
container consume or verify it, and fails a dedicated drift check on mismatch.
The container build verifies the compiler version and labels the final image;
Compose CI checks that label and executes the packaged binary. Release records
the immutable multi-platform image digest as a release artifact. Go/Docker
checks remain pending because those runtimes are unavailable in this workspace;
production crypto remains fail-closed.

**Implementation note (2026-08-14):** T40C replaces marker-only release
readiness with a versioned positive evidence policy and offline validator.
Approval evidence is bound to the candidate commit and requires production
crypto behavior proof, independent review, a complete successful CI job set,
and a multi-platform container digest whose commit/toolchain labels match. The
release workflow queries the exact commit's CI run, verifies the tag target,
stages an immutable image tag, validates its evidence, then promotes release
tags and records the digest. The legacy unavailable markers remain
defense-in-depth. Adversarial validator tests cover renamed markers, skipped
jobs, unreviewed/stale approvals and artifact commit mismatch. The gate remains
blocked in this workspace because production crypto and independent-review
approval files do not exist; Go/Docker execution is also unavailable.

**Implementation note (2026-08-14):** T40D adds `verify.sh` as the explicit
full local gate with a machine-readable summary and no environment-dependent
skips; the existing test/lint scripts remain fast fallback paths. CI now keeps
Go and Flutter coverage artifacts, retains the Go/Rust scans, and runs a
lockfile-aware mobile policy that fails on Dart retractions, missing lock data,
dynamic Gradle versions or insecure repositories. The complete local gate is
blocked here because Go, Cargo, cargo-audit, Flutter and Dart are unavailable;
the mobile dependency check consequently fails closed rather than skipping.
No new dependency was added.

### I41 - Push registration and platform readiness

**Decision:** Merge Codex LOG-09/UI-06/NTH-01/NTH-05 with Opus S12/H6.
**High, conditional blocker under D03. Depends on I36 for delivery durability.**

- Make registration provider-aware; FCM must not require VAPID.
- Surface typed permission/token/registration state. Remove false iOS copy.
- Add a privacy-safe test wake and diagnostics view without exposing endpoints,
  tokens, message IDs or ciphertext.
- Add Android 13+ notification permission and preserve generic push content;
  follow the current
  [Android notification-permission guidance](https://developer.android.com/develop/ui/compose/notifications/notification-permission).
- Defer rich notification content until there is a reviewed local-decryption
  design.

**Accept when:** FCM-only, UnifiedPush/WebPush-only, APNs-only and mixed setups
register, rotate, revoke and wake on real devices; denied permissions and
provider errors are visible without leaking sender or content.

### I42 - Authorized calls and native call lifecycle

**Decision:** Merge Codex LOG-10/ARCH-07 with Opus R13/R14. **High,
conditional blocker under D03. No dependency for server authorization.**

- Model initiator, invited participants, supported conversation kind,
  actor-specific transitions and a version precondition.
- Choose and document the native incoming-call path before implementation. If
  iOS PushKit is used, current Apple guidance requires CallKit; keep sender
  names/content out of the server push and fetch/decrypt locally after wake.
  On Android, prefer Telecom/ConnectionService where appropriate and declare
  the exact `phoneCall`, microphone and camera service types/permissions the
  final design uses. See
  [Apple PushKit/CallKit](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit)
  and
  [Android foreground-service types](https://developer.android.com/develop/background-work/services/fgs/service-types).

**Accept when:** non-participants and unrelated group members cannot create,
rewrite or end calls; stale transitions fail; signed-device tests pass denied
permissions, restrictive NAT/TURN, background/terminated and network-change
cases.

**Implementation note (2026-08-14):** T42A restricts server call sessions to
active, exactly two-account DMs and persists the derived invited participant.
Creation and transitions use action fingerprints for idempotent retries;
transitions require an expected version and update through a versioned CAS.
The storage layer enforces the initiator/invitee transition matrix, rejects
unsupported legacy group/channel calls, and keeps signaling metadata opaque.
Focused Go checks remain pending because this workspace has no Go runtime.

The T42B platform checkpoint is claimed for design-stage work and documented in
[`call-platform-design-proposal.md`](call-platform-design-proposal.md) and is
not approved yet; native permissions, entitlements, and provider changes must
wait for that approval.

### I43 - First-run and accessibility baseline

**Decision:** Merge Codex UI-04/UI-05/UI-07/UI-08/TEST-04/NTH-02 with Opus
U1/U2/U3/U4/U16/U20/R6/R15/H5. **High, pre-release. Coordinate with I24.**

- Fix non-text control contrast to at least 3:1 in light and dark. Test
  composited `outlineVariant` and opaque `outline` against every surface role
  where they identify controls.
- Treat border and fill changes as one contrast decision. In dark mode, do not
  combine the current `darkOutline` with `darkRaised` as a control fill: that
  pair is below 3:1. Either keep a canvas-adjacent fill or choose a stronger
  border token, then verify the final composite rather than adopting U1's two
  suggested changes independently.
- Start with an empty HTTPS origin; choose auth mode from server/device state;
  show probe/TLS/not-Veritra failures.
- Expose semantic labels, readable minimum type, responsive navigation and a
  narrow web setup page.
- Add golden/viewport/text-scale coverage, then run keyboard, TalkBack and
  VoiceOver checks on real devices.

**Accept when:** fresh install, linked device, offline, DNS/TLS failure and
fresh-server setup are actionable; 320 px and 200% text do not clip; control
contrast and semantic traversal pass; visual evidence is bound to a commit.

**Implementation note (T43A, 2026-08-14):** the dark opaque outline now uses
the muted token, while dark and light alpha borders use stronger, measured
composites. A pure-Dart WCAG helper and `chat_visuals_test.dart` check opaque
`outline` and composited `outlineVariant` against every Material surface role
used by the themes. Flutter test/analyze checks and the required visual/device
evidence remain pending because this workspace has no Flutter runtime; T43B and
T43C are tracked by separate implementation notes below.

**Implementation note (T43B, 2026-08-14):** the mobile connect flow starts
with an empty origin, rejects cleartext URLs without a development bypass, and
probes the HTTPS setup endpoint into typed reachable, fresh-instance, DNS,
TLS, timeout, wrong-server and unavailable states. Local device identity and
the probed origin select owner, invite registration or password sign-in; the
sign-in failure offers a direct link-device action. QR parsing rejects
unrelated URLs, accepts only HTTPS origin hints, and requires confirmation
before filling the origin; submission still requires a successful probe. iOS
declares local-network usage. Required Flutter checks remain pending; T43C
visual/accessibility evidence is still outstanding.

**Implementation note (T43C, 2026-08-14):** authentication fields now expose
persistent semantic labels and autofill metadata, the shared micro type is
11px, compact navigation removes visual labels below its safe width or at
larger text scales while retaining announced labels, and the setup page uses
border-box sizing with responsive padding. `ui_accessibility_test.dart` covers
semantic labels, 320dp/200% text construction and compact navigation. Flutter
tests/analyze and the websetup Go test are pending because the runtimes are
unavailable; golden screenshots, browser rendering and signed-device/manual
accessibility evidence remain external G24 work.

## Dependency-blocked release package

I45 is required by D02 and remains a release blocker, but it is not claimable
until I29 and I39 complete.

### I45 - Backup, restore and migration safety

**Decision:** Merge Codex DEP-04/DEP-05/DEP-09/DEP-10/TEST-08/NTH-04 with
Opus R5/R8/U18/H1. **High under D02, release blocker. Depends on I29 and I39.**

Use invocation-owned unique staging, preflight and provenance markers,
fsync/journaled activation, explicit rollback boundaries, scheduled encrypted
off-host backups, monitored age and disposable restore drills. Expose reviewed
backup/recovery UI instead of a dead “Coming soon” item.

**Accept when:** concurrent invocation, pre-existing paths, disk full, corrupt
archive, missing blob, permission failure and process death leave the original
instance recoverable; a clean-host restore and mobile recovery flow pass.

## Prepared follow-up packages

These are valid work, but the next implementation run should finish the Ready
release blockers before claiming them unless a dependency requires otherwise.

### I44 - Mobile and API quality

**Decision:** Merge Codex LOG-13/SEC-10/UI-09/UI-10/UI-11/UI-12/NTH-08/
NTH-09/NTH-11 with Opus L8/L11/L14/L15/U5/U6/U7/U8/U11/U12/U13/U14/
U17/U19/U21/U23/R10/R11. **Mixed Medium/Low, not independently blocking.**

Implement a shared error taxonomy and bounded decoders; contained stale/error
states; form validation; relative time; phone/tablet breakpoints; jump-to-live;
license/about; supported app links; localization scaffolding; appearance and
destructive confirmations. Split this umbrella into screen-sized cards before
claiming it.

**Acceptance baseline:** every server error code has a client mapping; paging
has a cap; malformed/binary responses are bounded; forms survive keyboard and
large text; URI handling works on both platforms or the URI is not emitted.

### I46 - Supported deployment hardening

**Decision:** Merge Codex DEP-03/DEP-07/DEP-08/DEP-11 with Opus R4/R9.
**Medium, required before calling the deployment path supported.**

Consume a versioned attested image digest in production Compose; lock the real
canonical DB/blob resources; support file-based secrets; reconcile shutdown,
drain and upload deadlines; add compatible container/systemd restrictions.

**Accept when:** the supported Compose/systemd paths use the tested artifact,
reject overlapping ownership, expose no secret in logs/config dumps and pass
startup, upload, backup, restore, push and TURN smoke under the hardened profile.

### I47 - Operational visibility and capacity evidence

**Decision:** Merge Codex DEP-12/TEST-07/PERF-10/ARCH-08/NTH-03 with Opus H4.
**High before a GA or scale claim; conditional for private alpha. Depends on
I35 and I36 for final evidence.**

Define a small-instance capacity contract and privacy-safe queue/backlog,
SQLite writer, disk, backup-age and provider-result metrics. Add reproducible
seed/load/soak scenarios and operator runbooks. Never label metrics with user,
conversation, token, endpoint or ciphertext identifiers.

**Accept when:** tested host tiers publish p95/p99, error, backlog, resource,
backup and restore limits; alerts fire before limits are exceeded; sustained
ingest and restart/provider stalls recover within the contract.

### I48 - Transport, realtime and logging hardening

**Decision:** Merge Codex LOG-12/SEC-06/SEC-09 with Opus L16/L17/S7/S8.
**Medium, feature/deployment conditional. Depends on I32.**

Make socket connect/dispose awaitable and send a close frame; use matched route
patterns for logs; reject unsafe trusted-proxy ranges; define a supported TLS
trust path for LAN installs. Keep the hand-written WebSocket parser only if its
adversarial/fuzz tests plus Autobahn evidence cover the supported surface; a
replacement dependency requires review and notices.

**Accept when:** delayed-connect teardown leaks no authenticated socket,
malformed frames stay bounded, logs contain no dynamic identifier/capability,
proxy spoof tests fail closed and a real mobile client can establish the
documented TLS path.

### I49 - Measured performance and architecture work

**Decision:** Merge Codex PERF-01/PERF-04/PERF-06/PERF-07/PERF-09/
ARCH-02/ARCH-05/NTH-15/NTH-16 with Opus L13/P1/P2/P3/P4/P5/P6/P7/P8/P9/
S5/S6/U9/U10. **Mixed High/Medium, conditional on measured limits.**

Benchmark first, then split this umbrella by independent write surface:
conversation read model, blob verification/range I/O, sync bounds, quota
accounting/admission, realtime registration, device-seen writes, blob-directory
layout, state rebuilds/indexed lookups and per-account creation limits. Keep
SQLite and local blobs.

**Accept when:** each child card names a dataset, target, before/after profile,
correctness invariant, migration/reconciliation path and rollback. No stack
replacement is accepted merely to improve an unmeasured path.

### I50 - Deferred product and ecosystem backlog

**Decision:** Defer Codex NTH-06/NTH-07/NTH-17/NTH-18/NTH-20 and Opus H2/R16
plus the unnumbered product-polish, developer-experience and ecosystem ideas.
R16 is rejected; UI-01 is retained under I25 rather than filed here.

Retained themes are drafts, trust center, admin/operator tools, moderation,
local encrypted search, contacts, archive/pin, previews/read/typing, privacy/TLS
indicators, multi-account, passkeys, post-quantum readiness, API ecosystem,
reproducible builds and F-Droid. H2 may begin with privacy-safe CLI operations
after release blockers. Federation, PostgreSQL, S3 and NATS remain out of
scope. Desktop and embedding remain sequenced by D06.

## Existing release gates retained

| Card | Audit findings absorbed | Decision |
|---|---|---|
| I24 | Codex DEP-02/TEST-04/TEST-05; Opus R6/R12/R13/R14 | Signed artifacts, visual/accessibility checks, providers, calls and real-device evidence remain external. |
| I25 | Codex SEC-03 (review scope)/UI-01 | Independent review and the final crypto-activation gate stay mandatory. |
| I27 | Codex SEC-03 (advisory scope); Opus R3 (exception/advisory scope) | Resolve coordinated OpenMLS/HPKE advisories; do not adopt a release candidate or private fork without approval and review. |

## Source traceability

Every numbered source finding and every named Opus product bundle maps below.
Parenthetical scopes make ownership explicit when a broad source finding spans
two independent defects or both code and external evidence.

| Card | Codex source IDs | Opus source IDs |
|---|---|---|
| I29 | SEC-01, SEC-08 | S2 |
| I30 | LOG-01, ARCH-01, TEST-01, PERF-08 | — |
| I31 | LOG-02, LOG-11, UI-02, TEST-03 (message outbox) | L1, L10, L12, U15, U22 |
| I32 | LOG-03, LOG-04, UI-03, TEST-02, ARCH-06 | P11 |
| I33 | LOG-08, PERF-03 | L2, L9 |
| I34 | LOG-06, TEST-03 (MLS control) | L3 |
| I35 | LOG-05, PERF-05 | L5, L6 |
| I36 | LOG-07, PERF-02, ARCH-03, NTH-14 | L4, P10 |
| I37 | SEC-04, SEC-07 | S1, S3, S4, S9, S10, S11 |
| I38 | SEC-02, NTH-19 | H3 |
| I39 | SEC-05 | L7 |
| I40 | DEP-01, DEP-06, TEST-06, TEST-09, TEST-10, TEST-11, ARCH-04, NTH-10, NTH-12, NTH-13 | L18, R1, R2, R3 (CI/expiry), R7 |
| I41 | LOG-09, UI-06, NTH-01, NTH-05 | S12, H6 |
| I42 | LOG-10, ARCH-07 | R13, R14 |
| I43 | UI-04, UI-05, UI-07, UI-08, TEST-04, NTH-02 | U1, U2, U3, U4, U16, U20, R6, R15, H5 |
| I44 | LOG-13, SEC-10, UI-09, UI-10, UI-11, UI-12, NTH-08, NTH-09, NTH-11 | L8, L11, L14, L15, U5, U6, U7, U8, U11, U12, U13, U14, U17, U19, U21, U23, R10, R11 |
| I45 | DEP-04, DEP-05, DEP-09, DEP-10, TEST-08, NTH-04 | R5, R8, U18, H1 |
| I46 | DEP-03, DEP-07, DEP-08, DEP-11 | R4, R9 |
| I47 | DEP-12, TEST-07, PERF-10, ARCH-08, NTH-03 | H4 |
| I48 | LOG-12, SEC-06, SEC-09 | L16, L17, S7, S8 |
| I49 | PERF-01, PERF-04, PERF-06, PERF-07, PERF-09, ARCH-02, ARCH-05, NTH-15, NTH-16 | L13, P1, P2, P3, P4, P5, P6, P7, P8, P9, S5, S6, U9, U10 |
| I50 | NTH-06, NTH-07, NTH-17, NTH-18, NTH-20 | H2, R16 and unnumbered roadmap/polish bundles |
| I24 | DEP-02, TEST-04, TEST-05 | R6, R12, R13, R14 |
| I25 | SEC-03 (review), UI-01 | — |
| I27 | SEC-03 (advisories) | R3 (exception/advisory) |

The Opus headline bundles map as follows: H1 → I45, H2 → I50, H3 → I38,
H4 → I47, H5 → I43 and H6 → I41. Codex NTH items not deferred to I50 are
attached to the implementation card that supplies their prerequisite.

## Consensus boundary

Consensus means both audits' evidence was considered and disagreements were
adjudicated against current code. It does not mean every recommendation is
accepted or that two reports create two votes. A reproducible code path wins
over severity labels; approved product/privacy decisions win over roadmap
ideas; measured behavior wins over speculative architecture.

When implementation changes a card's truth, update [`board.md`](board.md) and
this register in the same change. Do not restore historical source snapshots
as live executor context or make them look current.

---

## Claude review and final resolution (2026-08-13)

Claude reviewed this register after the initial reconciliation against the same
`main` commit. The confirmed objections are applied above; the coordinator
decisions below close the remaining disagreements.

| Review point | Final resolution |
|---|---|
| Duplicate ownership | U15 belongs to I31; PERF-03 to I33; NTH-05 to I41. TEST-03 is explicitly split between its message-outbox scope in I31 and MLS-control scope in I34. |
| I45 status | I45 is a dependency-blocked D02 release package, not Ready and not a non-blocking follow-up. The board now matches. |
| Contrast | Both palettes fail and I43 now tests `outlineVariant` plus `outline`. The claim that neither audit named light mode is rejected: Opus U1 cites both tokens and says the token changes twice. |
| Background sync | Accepted. I30 now proves that normal background pages cannot discard plain application envelopes as the cursor advances. |
| Rust deadline | I40 moves directly after I29 in wave 0. Its expiry guard must land before 2026-08-29 and have deterministic expired-date coverage. |
| Gate/dependency drift | I25 owns independent review/final activation; I27 owns advisory resolution; I40 owns release-profile and supply-chain code. I47/I48 dependencies are explicit. |
| UI-01 filing | Removed from I50. It belongs to I25, because I25 is the final gate that authorizes replacing `UnavailableCryptoService`; I27 alone cannot make messaging available. |
| SEC-01 severity | High is retained because the leaked capability yields encrypted backup ciphertext protected by a separate user-held key—not because wording was removed from a report. |

The source trace remains complete: 96 Codex findings, 80 numbered Opus findings
and six Opus bundles all have owners. The raw critique at `bfb3922` records the
adjudication provenance; the table above is the live trace.

---

## Second-round reply to the final resolution (2026-08-13)

Re-verified against the same commit after the resolutions above were applied.
One objection is withdrawn; one new defect in the adopted remedy is filed.

### Withdrawn: the light-palette claim

The rejection is accepted. Opus U1 does name the light palette — its Location
line cites [`tokens.dart:42`](../mobile/lib/ui/tokens.dart#L42) and
[`theme.dart:82`](../mobile/lib/ui/theme.dart#L82), its fix is captioned "one
token, changed twice", and its step 5 reads "Re-check the light palette the same
way — `lightBorder` at 11% of `lightText` over `lightSurface #ffffff` has the
same problem." The third-review assertion that neither audit named light mode
was wrong and is withdrawn.

### New: U1's stated ratios are lenient and its two fixes are incompatible

Adopting U1 is right. Implementing U1's numbers and fix list verbatim is not.

**The dark table composites against one background and compares against
another.** `darkBorder` is `0x17ffffff`, an alpha of 23/255 = 9.0%:

| Pair | U1 states | Actual |
|---|---|---|
| `outlineVariant` composite | ≈`#3a3444` | `#2b2633` over canvas; `#352f40` over surface |
| composite vs `darkCanvas` | 1.53:1 | **1.26:1** |
| composite vs field fill | 1.40:1 | **1.30:1** |

U1's composite corresponds to roughly 12% alpha, not 9%. The headline "≈1.4:1"
is really ≈1.3:1. The defect is worse than reported, and an implementer working
from U1's table optimizes against a baseline that is already too generous.

**U1's fix #1 and fix #2 cannot both be applied.** Fix #1 moves control borders
to `outline` (`darkOutline #6f6675`), justified as "3.35:1 against the canvas" —
that figure is sound; the measured value is 3.38:1. Fix #2 raises the field fill
from `surfaceContainer` to `surfaceContainerHigh` (`darkRaised #2b233a`). Apply
both and the border no longer borders the canvas — it borders the new fill:

| Pair | Ratio | 1.4.11 |
|---|---|---|
| `darkOutline` vs `darkCanvas` | 3.38:1 | pass |
| `darkOutline` vs `darkSurface` | 3.07:1 | pass, 0.07 margin |
| `darkOutline` vs `darkRaised` (U1's new fill) | **2.73:1** | **fail** |

Following U1's own remedy end to end terminates on a non-conformant field
border. I43's acceptance criterion — testing `outline` "against every surface
role where they identify controls" — is correctly worded and would catch this,
so no criterion change is needed.

**I43 change required:** name the trap in the card body so it is not
rediscovered during implementation. Either pair the raised fill with a border
token above `darkOutline`, or keep the canvas-adjacent fill; do not adopt U1
steps 1 and 2 together on the assumption that both are additive.

### Regression check on the restructure

The rewrite preserved the trace: 96/96 Codex IDs and 86/86 Opus headings map,
with no orphans and no phantom IDs. Every surviving double-map now falls under a
disclosed exception — code card plus external gate (R3, R6, R13, R14, TEST-04)
or an explicitly scoped split (SEC-03 review/advisory, TEST-03 message-outbox
versus MLS-control). U15, PERF-03 and NTH-05 are single-owner. The duplicate
ownership objection is fully closed.

The historical critique at `bfb3922` had corrected its count at the top but
still read "76 findings across 8 chapters" in its structural critique. Its
final revision and this register agree on 96.

### Codex disposition

Accepted. The I43 card now names the incompatible border/fill combination and
requires testing the final composite. No acceptance criterion, card ownership,
severity or implementation order changed. There are no unresolved objections
between the Codex reconciliation and Claude's second-round review.
