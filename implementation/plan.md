# Merged implementation plan

The reconciled work list from `audits-codex` and `audits-opus`, after
verification. Ordered by (production impact × confidence) ÷ effort. Each block
is independently shippable and each item names its verification.

Do not remove the production crypto gates to make `release-readiness.sh` pass.

---

## Block 0 — leak containment (do today, before anything else)

**0.1 Stop logging the recovery capability.** `codex SEC-01` / `opus S2`

- In `routeClass`'s caller ([`app.go:346`](../server/internal/app/app.go#L346)),
  log `r.Pattern` with an `unmatched` fallback instead of
  `routeClass(r.URL.Path)`. `a.metrics.record` two lines above already uses
  `r.Pattern`, so the value is known good.
- Delete `routeClass` once nothing calls it — enumerating safe prefixes is the
  bug, not the missing `recovery` case.
- Move the capability out of the URL: `GET /api/v1/recovery` with
  `X-Veritra-Recovery-Token`, matching the device-link claim token which is
  already header-borne *specifically to stay out of access logs*
  ([`auth_handlers.go:673`](../server/internal/httpapi/auth_handlers.go#L673)).
- Add `/api/v1/recovery` to `isAuthEndpoint` — today it gets only the 240/min
  general bucket.
- Rotate any capability that may have been requested; purge affected server and
  Caddy logs.

*Verify:* a test that drives a sentinel-valued token through every route and
asserts it appears in no log field. This is the test that converts the
`AGENTS.md` rule into an invariant.

---

## Block 1 — the MLS state invariant (the largest single risk)

**1.1 Background catch-up must not touch the cursor.** `codex LOG-01 / ARCH-01`

Interim, ship now: strip the cursor write from
[`background_push.dart`](../mobile/lib/push/background_push.dart). Record a wake
marker, let foreground catch-up do the work. Delete the
`full_resync_required` branch's `saveSnapshot(…, latest_event_id)` jump.

Complete fix, before MLS ships: one account-scoped sync engine owns event
ingestion and cursor advancement. Background execution invokes that engine or
durably appends events *without* acknowledging them. Event dedupe marker, MLS
state, ciphertext and cursor commit in one transaction.

*Verify:* `codex TEST-01`'s matrix — normal pages, interruption between crypto
and cursor commit, duplicate events, cursor expiry, full resync,
foreground/background overlap, account switch.

**1.2 Poison sync events must not wedge catch-up.** `opus L2`

Wrap the per-event body in `try`. On `StateError`, on `ApiException` 404/410,
and on decode failure: skip, **advance the cursor past it**, count it. Keep hard
failures hard — 401 clears the session, `SocketException` marks offline *without*
advancing. `_repairMessage` already gets this right at
[`app_state.dart:1595-1604`](../mobile/lib/core/app_state.dart#L1595-L1604);
apply the same pattern in `_processCryptoSyncEvent`.

*Verify:* a payload missing `mls_message_id`, and a referenced message returning
404. Catch-up completes and the cursor advanced in both.

**1.3 Delete the cursor reset in the restore catch-all.** *(new this pass)*

[`app_state.dart:258`](../mobile/lib/core/app_state.dart#L258) does
`await localStore.saveSyncCursor(0)` inside `tryRestoreSession`'s outer
`catch (_)`. Any restore hiccup replays all retained history; post-MLS that
lands straight in 1.2's wedge. Remove it — a failed restore should not mutate
durable sync state.

---

## Block 2 — client data loss (all small, all client-side)

**2.1 Never evict an unsent message.** `codex LOG-02` / `opus L1` — *Critical*

[`encrypted_database.dart:479-503`](../mobile/lib/storage/encrypted_database.dart#L479-L503)
trims `rows.take(excess)` from a `queuedAt ASC` ordering — the oldest messages.
Enforce capacity *before* encryption and state advancement; return a typed
`outbox_full` and surface it on `Ops.send` with the composer text intact.

*Verify:* enqueue at 99 / 100 / 101 on both the crypto and non-crypto paths;
assert the first entry survives and the newest was refused.

**2.2 `resetOnError: false`.** `codex SEC-05` / `opus L7`

[`local_store.dart:514`](../mobile/lib/storage/local_store.dart#L514). This is
fail-*open* on the one value that unlocks the entire encrypted database, and it
contradicts recorded decision **D01** ("fail closed on cipher or key-check
failure"). Detect an existing DB with an unreadable key, preserve the file,
transition to `recoveryRequired`, and offer relink or explicit reset. Pin
`encryptedSharedPreferences: true` rather than relying on a plugin default.

**2.3 MLS outbox error handling.** `codex LOG-06` / `opus L3`

[`app_state.dart:1757-1771`](../mobile/lib/core/app_state.dart#L1757-L1771) has
no `try`, no classification, no backoff, no terminal state — while `_flushOutbox`
30 lines away has all five. Give it the same discipline, `continue` past
terminal entries, and add `attemptCount`/`nextAttemptAt`/`terminal` columns.
Wrap `main()` in `runZonedGuarded` so no `unawaited` future escapes unlogged.

*Verify:* a permanently-4xx MLS message goes terminal and later messages still
send.

**2.4 Add 507 to the terminal set; add a re-entrancy guard.** `opus L10`, `L12`

One-line each. 507 is a quota, not a transient. `_flushOutbox` needs the
`_catchingUpSync`/`_catchUpRequested` coalescing pattern that
`_catchUpSyncEvents` already proves.

---

## Block 3 — server correctness (each has a test seam)

**3.1 Drain the retention backlog.** `codex LOG-05/PERF-05` / `opus L5`

Loop until a page returns short, with a 5 ms yield and `ctx.Done()`, exactly as
[`pruneEventRows`](../server/internal/storage/message_store.go#L582-L605)
already does. Add a per-sweep work ceiling and shorten the ticker to 1 hour.

**Fix these four, not codex's list** — `sync_events` and `audit_events` already
loop and need no change:

| Function | Location |
| --- | --- |
| `PruneExpiredContent` | `message_store.go:483` |
| `PruneCallSessions` | `content_store.go:511` |
| `PruneOperationalRows` | `content_store.go:519` (6 sub-queries) |
| `reconcileBlobDeletions` | `app.go` |

*Verify:* insert 1,200 expired envelopes, run one sweep, assert zero remain. Add
an `expired_messages_pending` gauge so a backlog is visible.

**3.2 One message set drives the whole prune.** `opus L6` — *Medium (downgraded)*

[`message_store.go:490-522`](../server/internal/storage/message_store.go#L490-L522):
the attachment-row delete limits 500 **join rows** while the other two statements
limit 500 **messages**. Materialise the message IDs once and drive all three from
it. (Bounded rather than permanent — see `critique.md` §5.1 — but it still
strands downloadable attachment records whose blobs are gone.)

**3.3 A committed message always fans out.** `codex LOG-07` / `opus L4`

Return the recipient list from inside `SaveMessageEnvelopeWithSyncEvent`, which
already holds the membership rows for its `ErrNotMember` check
([`message_store.go:69-75`](../server/internal/storage/message_store.go#L69-L75)).
That removes the second query, the post-commit failure window, and the
duplicate-suppression interaction in one change. Defer the transactional job
outbox to Block 6 where push actually needs it.

*Verify:* an injected recipient-lookup failure still yields 201 and a published
event.

---

## Block 4 — security hardening (small, high value)

| # | Item | Source |
| --- | --- | --- |
| 4.1 | **Setup-token entropy floor.** Reject < 32 chars in production; reject the repo's own test values, mirroring `isReservedNonProductionKeyPackage`; ship `generate-setup-token`. Two docs promise this and no code enforces it. **Blocker.** | `opus S1` |
| 4.2 | **Export: `withRecentAuth`, and stop exporting `auth_secret`.** [`account_store.go:49`](../server/internal/storage/account_store.go#L49). Represent the subscription without the reusable credential. Record an export audit event. **Blocker.** | `codex SEC-02` |
| 4.3 | **Put `/auth/reauth` under the credential limiter** and `LoginBackoff`, keyed per session/account/device as well as per source. | `codex SEC-04` |
| 4.4 | **Fix the login-backoff fail-open.** [`login_backoff.go:80`](../server/internal/httpapi/login_backoff.go#L80) must test key *presence*, not the stored `failures`. Add a sweeper; evict oldest rather than declining to insert; meter occupancy. | `opus S3` |
| 4.5 | **Make recovery capabilities one-time.** Consume/rotate atomically on successful download; add an explicit expiry. Compounds with 0.1. | `codex SEC-08` |
| 4.6 | **Reject over-broad trusted-proxy CIDRs** (`0.0.0.0/0`, public ranges) unless explicitly overridden. | `codex SEC-09` |

---

## Block 5 — release integrity (cheap, and it protects everything above)

1. **Unify the Go toolchain.** `go.mod` and all CI jobs are `1.25.12`;
   `Dockerfile:1` is `golang:1.26.4`. The shipped artifact is the only build
   nothing tests. `opus R1` (**High/blocker**, against codex's Medium).
2. **Make `release-readiness.sh` a positive assertion** bound to a commit, not a
   grep for absent markers. `codex DEP-01/ARCH-04` / `opus R2`
3. **Make release depend on completed CI.** A correctly named tag can currently
   publish concurrently with failing checks. `codex TEST-06`
4. **Add `govulncheck` and `audit-rust.sh` as CI jobs**, with automated expiry on
   the RustSec exception (2026-08-29). `opus R3` / `codex TEST-11`
5. **Signed mobile artifacts** in the release workflow. `codex DEP-02`

---

## Block 6 — before anyone sees it

**UI**

1. **Raise `outlineVariant`.** `darkBorder = 0x17ffffff` over `darkSurface` is
   ≈1.3:1 against a WCAG 1.4.11 floor of 3:1, and it draws every field border,
   button outline, chip and divider. One constant. `opus U1`
2. **Fix the first-run connect flow** — `http://localhost:8080` cannot work on a
   phone; "Sign in" is the default mode but always fails on a fresh install; an
   unreachable server produces no feedback. `opus U2/U3/U4` + `codex UI-08`
3. **Add an `initializing` startup state** so cold start never flashes a false
   logged-out screen. Pairs with 1.3. `codex UI-03` / `LOG-03`
4. **Preserve the composer draft on pre-outbox failure** — restore the text when
   `sent == false` and no outbox entry exists. Medium, not the subsystem codex
   describes. `codex UI-02`
5. **Drive push settings from real platform state.** Settings claims iOS push is
   unavailable while `AppDelegate.swift:39` registers for it. `codex UI-06`

**Platform config** (blocks finishing I24 on real hardware)

6. iOS `voip`/`audio` background modes, CallKit/PushKit. `opus R13`
7. Android typed foreground service for calls, `POST_NOTIFICATIONS`.
   `opus R14/S12`
8. Remove the VAPID precondition from the FCM path (`MainActivity.kt:26`) and
   surface registration failures instead of swallowing them in `_startPush`'s
   `catch (_)`. `codex LOG-09`

**Calls** (before enabling them)

9. Model a call aggregate: initiator, invited participants, conversation kind,
   an explicit transition table, and a version precondition. Today any member of
   any conversation can end or rewrite any call.
   `codex LOG-10/ARCH-07`

---

## Block 7 — capacity (before load, not before launch)

`opus P1` blob re-hash per download · `opus P2` `SyncBounds` full history scan
per poll · `opus P3` quota `SUM()` inside the write transaction ·
`codex PERF-02` durable bounded push workers · `codex PERF-03` batch repair
endpoint · `codex PERF-01` conversation-list read model, **after** an
`EXPLAIN QUERY PLAN` says it needs it · `codex PERF-10/ARCH-08` a published,
tested capacity envelope.

---

## Not scheduled

Everything in both `nice-to-haves.md` files, `codex ARCH-02` (the `AppState`
split — do it incrementally along the ownership boundaries Blocks 1–2 establish,
not as a project), and `codex UI-01`, which restates the board's own deliberate
crypto gate rather than reporting a defect.

Carried forward unassessed: `codex DEP-04/DEP-05` (backup staging paths, restore
activation atomicity). Plausible on reading, not verified in this pass, and the
opus audit has no equivalent — check them before the first restore drill.
