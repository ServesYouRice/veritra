# Critique of `audits-codex/`

> Supporting adjudication notes from 2026-08-11. Do not extract work from this
> file. The later multi-review consensus corrected additional issues—including
> recovery-leak severity, MLS poison-event handling and terminal MLS outbox
> behavior. The authoritative decision and implementation queue is
> [`audit-consensus.md`](audit-consensus.md).

Every claim below was re-checked against the working tree. "✅ Verified" means I
read the cited code this pass and the described behaviour is present. Where the
opus audit was itself wrong, that is recorded too.

Codex filed 96 findings across 8 chapters (76 outside the nice-to-have chapter).
This critique covers the ones where
the two audits disagree, where codex is factually wrong, and where either audit
has a gap. Findings the two audits agree on with no material difference are
listed once at the end.

---

## 1. Codex is right and the opus audit missed it — adopt these

### 1.1 LOG-01 / ARCH-01 / TEST-01 — background catch-up advances the cursor without MLS

**✅ Verified. This is the single strongest finding in either audit.**

[`background_push.dart:29-53`](../mobile/lib/push/background_push.dart#L29-L53)
pulls up to 5 × 200 = 1,000 sync events, tracks the highest event ID, and
commits it through `store.saveSnapshot(conversations, …, cursor)`. It never
constructs `MlsConversationCryptoService`. `saveSnapshot` writes the same cursor
that `_catchUpSyncEvents` reads back via `localStore.loadSyncCursor()`
([`local_store.dart:561`](../mobile/lib/storage/local_store.dart#L561)), so on
the next foreground launch those 1,000 events are already behind the cursor and
are never processed.

Codex's severity, blast radius, and fix are all correct. Once MLS is wired, an
ordinary background wake can silently skip commits, welcomes and revocations,
and the device's epoch diverges from its peers with no error anywhere.

**One thing codex understated.** The `full_resync_required` branch
([`:55-69`](../mobile/lib/push/background_push.dart#L55-L69)) jumps the cursor
straight to `latest_event_id` and sets `succeeded = true`. Codex calls this out
for MLS sessions. It is wrong for non-MLS sessions too: it discards every
unprocessed event including plain `message.envelope.created`, and reports
success to the platform so the OS records the wake as productive.

**The opus audit has no equivalent finding at all.** It did not open
`background_push.dart`. That is a scope failure, not a judgement difference —
the file is 79 lines and is the second `@pragma('vm:entry-point')` in
`main.dart`.

**Adopt as written.** Interim fix: have the headless task record a wake marker
and never call `saveSnapshot`.

---

### 1.2 SEC-02 — account export ships live push credentials

**✅ Verified, and codex undersold the specific part.**

[`account_store.go:49`](../server/internal/storage/account_store.go#L49):

```sql
"push_subscriptions": `SELECT json_object(…, 'endpoint', endpoint,
  'public_key', public_key, 'auth_secret', auth_secret, …)`
```

`auth_secret` is the WebPush authentication secret. Exported verbatim. The route
is [`api.go:100`](../server/internal/httpapi/api.go#L100) —
`a.withAuth(a.exportAccount)` — while `deleteAccount` on the very next line uses
`withRecentAuth`. So a stolen bearer token yields the full dossier *and* a
reusable credential for pushing to that account's devices, with no password and
no device secret.

The opus audit missed this completely. Adopt.

---

### 1.3 SEC-04 — `/auth/reauth` runs bcrypt outside the credential limiter

**✅ Verified.**
[`api.go:62`](../server/internal/httpapi/api.go#L62) registers reauth under
`withAuth`. [`app.go:594-603`](../server/internal/app/app.go#L594-L603)'s
`isAuthEndpoint` lists only `/setup/owner`, `/auth/login`, `/register`,
`/device-links/claim` and `*/claim-status`. Reauth is in none of them, so it
gets the 240/min general bucket while performing a bcrypt verify — 24× the
login budget on the endpoint that guards every `withRecentAuth` action.

Codex's framing as both a guessing oracle and an authenticated CPU-exhaustion
path is correct. The opus audit missed it. Adopt.

---

### 1.4 LOG-09 / UI-06 — FCM-only deployments can never register for push

**✅ Verified end to end.**

- [`content_handlers.go:310-315`](../server/internal/httpapi/content_handlers.go#L310-L315)
  returns `enabled: len(PushProviders) > 0` and `vapid_public_key` independently.
  FCM-only → `enabled: true`, `vapid_public_key: ""`.
- [`app_state.dart:1321`](../mobile/lib/core/app_state.dart#L1321) reads
  `config['vapid_public_key'] as String? ?? ''` and passes it through.
- `MainActivity.kt:26` rejects the call before trying FCM:
  `if (nextInstance.isNullOrBlank() || nextVapid.isNullOrBlank())
   result.error("invalid_arguments", …)`.
- `_startPush`'s `catch (_)` swallows it, and `pushConfigured` was already set
  `true` on the line above — so Settings reports push as configured while
  registration never happened.

Codex also caught the matching UI lie: `settings_screen.dart:592` says *"Push is
not available on iOS yet"* while `AppDelegate.swift:39` calls
`registerForRemoteNotifications()` and `:85` handles the wake. Both confirmed.

The opus audit reached the neighbourhood — S12 flags the missing
`POST_NOTIFICATIONS` permission, R13 flags iOS background modes — but never
traced the registration call path. Codex's is the better finding. Adopt both.

---

### 1.5 LOG-10 / ARCH-07 — any conversation member can drive any call

**✅ Verified.**
[`content_store.go:472-478`](../server/internal/storage/content_store.go#L472-L478)
authorizes a transition on `COUNT(*) FROM memberships WHERE conversation_id = ?
AND account_id = ?` and nothing else. No caller/callee role, no participant set,
no version precondition. `createCall` (`:393-399`) likewise checks membership
only — there is no two-member constraint, so a call can be created in a
50-person channel.

The transition table at `:479-481` also permits `call.State == nextState`, which
lets any member overwrite `metadata_json` on a live call any number of times
while staying "allowed".

Correctly gated as "blocker before calls ship". The opus audit did not review
the call authorization path. Adopt.

---

### 1.6 LOG-03 / LOG-04 — bootstrap race and post-logout writes

**✅ Verified as a real shape. Severity is arguable; the fix direction is right.**

[`main.dart:29-30`](../mobile/lib/main.dart#L29-L30) is
`runApp(...)` followed by `unawaited(state.tryRestoreSession())`. There is no
`initializing` state and `ConnectScreen` is live and interactive while
`tryRestoreSession` ([`app_state.dart:212-260`](../mobile/lib/core/app_state.dart#L212-L260))
assigns `session`, calls `_replaceApi`, activates crypto, and starts sync.

I would rate the interleaving **Medium**, not a blocker: it needs the user to
complete a full sign-in inside the secure-storage read window. But codex reaches
the right destination by a slightly overstated route, because there is a worse
bug in the same function that codex did not mention:

**The outer `catch (_)` at `:249-259` calls
`await localStore.saveSyncCursor(0)`.** Any throw during restore — a corrupt
cached snapshot, a Drift open failure, a bad `activateSession` — silently resets
the durable cursor to zero. Post-MLS that means replaying every retained event
against advanced group state, which lands directly in the poison-event wedge
(opus L2). A restore hiccup becomes a bricked device.

**Adopt the session-generation fix. Add the `saveSyncCursor(0)` reset to it.**

---

## 2. Codex is factually wrong — do not implement as written

### 2.1 LOG-05 / PERF-05 name two tables that are already correct

Codex: *"This affects expired messages/attachments, sync events, audit events,
sessions, invites, device links, key packages, calls, and queued blob
deletions."*

**Sync events and audit events are wrong.** Both route through
[`pruneEventRows`](../server/internal/storage/message_store.go#L582-L605), which
already loops until a page returns fewer than 500 rows, with a 5 ms yield and a
`ctx.Done()` check between batches. They converge. They are, in fact, the
correct model the other sweeps should be rewritten to follow — which is exactly
what the opus L5 fix proposes and codex's does not notice.

The genuine single-page offenders, all verified:

| Function | Location | Cap |
| --- | --- | --- |
| `PruneExpiredContent` | `message_store.go:483` | 500 messages / run |
| `PruneCallSessions` | `content_store.go:511` | 500 / run |
| `PruneOperationalRows` | `content_store.go:519` | 500 × 6 sub-queries / run |
| `reconcileBlobDeletions` | `app.go:PendingBlobDeletions(ctx, 500)` | 500 / run |

Against a 6-hour ticker ([`app.go:222`](../server/internal/app/app.go#L222)),
that is 2,000/day per class. The finding is right; the target list is not.
Implementing codex's list verbatim means editing two functions that need no
change and missing `PruneCallSessions` and `PruneOperationalRows`, which codex
does not name at all.

### 2.2 SEC-01 leans on a speculative claim it did not need

The finding is correct and I rate it Critical too — `routeClass`
([`app.go:472-497`](../server/internal/app/app.go#L472-L497)) has no
`/api/v1/recovery/` case, so `default: return path` writes the full 32-byte
capability into `http_request`'s `route` field. Codex reproduced it against a
live container, which is better evidence than the opus audit's static read.
**Credit where due: codex's severity is right and the opus audit's High was too
low.**

But this sentence should not survive into the fix ticket:

> *"The encryption key may be distributed with the recovery material, so leaking
> this capability can defeat the intended separation."*

Nothing in the code supports it. `backup_blobs` stores
`key_derivation_metadata_json`, not a key, and the blob is encrypted with a
user-held key. The capability yields the ciphertext, which is bad enough. A
Critical finding does not need a hedge, and a hedge that a reviewer disproves is
how a real finding gets dismissed.

**Two additions neither audit's fix includes:** `/api/v1/recovery/{token}` is
absent from `isAuthEndpoint`, so it also gets only the 240/min general bucket;
and the correct log fix is `r.Pattern` (already used by
`a.metrics.record(r.Pattern, …)` two lines above) with an `unmatched` fallback,
which makes every future dynamic route safe by default rather than by
enumeration.

---

## 3. Codex is directionally right but its fix is heavier than needed

### 3.1 LOG-07 — post-commit fan-out (opus L4)

Both audits found it. Codex prescribes a transactional job outbox plus a bounded
worker pool with dedupe and retries. That is the right *architecture* and the
wrong *first move*.

`SaveMessageEnvelopeWithSyncEvent` already holds the membership rows inside its
transaction for the `ErrNotMember` check
([`message_store.go:69-75`](../server/internal/storage/message_store.go#L69-L75)).
Returning the recipient list from inside that transaction deletes the second
query, the failure window, and the duplicate-suppression interaction — in a few
lines, with no new table and no new worker. Build the job outbox when push
delivery needs it (codex PERF-02, opus P10), not to fix this.

### 3.2 UI-02 — composer clears before durable acceptance

**✅ The behaviour is real** ([`chat_screen.dart:223`](../mobile/lib/features/chat/chat_screen.dart#L223)),
but codex read it as an oversight. It is a documented trade-off — there is a
four-line comment above the `clear()` explaining that the pending bubble carries
the sending/failed state and the retry action, and `sendMessageTo` does insert
into the durable outbox.

The residual gap is narrow and real: failures *before* the outbox insert
(crypto init, encryption, the Drift write) lose the text with only a snackbar.
That is a Medium fix — restore the controller text when `sent == false` and no
outbox entry exists — not a High blocker requiring a draft-persistence subsystem.

---

## 4. What codex missed that the opus audit found

Seven findings, all re-verified this pass.

| Finding | Where | Why it matters |
| --- | --- | --- |
| **S1** Setup token has no entropy floor | `config.go:51`, `app.go:61-64` | `PRIVATE_MESSENGER_SETUP_TOKEN=x` starts a production server. `README.md:65` and `docs/operations.md:10` both promise "high-entropy". Guards owner creation on a fresh instance. **Blocker.** Codex has no setup-token finding of any kind. |
| **L2** Poison sync event wedges catch-up | `app_state.dart:1543-1571` | A 404 on a retention-pruned message throws, the cursor never advances, and every retry path re-hits the same event. Permanent offline banner on a healthy network. Codex's LOG-08 covers only the *cursor-expiry* case and misses the general wedge. **Blocker.** |
| **S3** Login-backoff table fails open | `login_backoff.go:80` | See below — codex reviewed this file and drew the opposite conclusion. |
| **U1** `outlineVariant` fails WCAG 1.4.11 | `tokens.dart:29`, `theme.dart:46` | See below — codex's biggest UI miss. |
| **R1** Container Go is a minor version ahead of CI | `Dockerfile:1` vs `go.mod:3` | See below. |
| **L10** 507 quota errors retried forever | `app_state.dart:1735` | 507 is absent from the terminal set, so a hard quota rejection retries every ~4 minutes indefinitely and occupies an outbox slot that (per L1) can evict a different message. |
| **P1/P2/P3** Blob re-hash per download, `SyncBounds` full scan per poll, `SUM()` inside the write transaction | server | Codex's PERF-06/07 touch two of these but with no line refs and an explicit "benchmark first" hedge. |

### 4.1 S3 — codex reviewed `login_backoff.go` and missed the bug in it

Codex's SEC-07 correctly observes that backoff is keyed on username alone and
frames it as an availability risk. Reading the same file, the more serious
defect is at [`login_backoff.go:80`](../server/internal/httpapi/login_backoff.go#L80):

```go
if len(backoff.byID) < maxLoginBackoffEntries || backoff.byID[key].failures > 0 {
    backoff.byID[key] = entry
}
```

The guard reads `backoff.byID[key]` — the *stored* map value, which is the zero
entry for a key not yet present — rather than the local `entry` that was just
incremented. So when the table is full, **a new identity is never inserted** and
its `RetryAfter()` returns 0 forever. Per-username backoff fails open under
table pressure, silently, with no metric.

**Correcting the opus audit's own overstatement:** S3 as written says the
entries are "unexpirable". They are not — `Failed()` sweeps expired rows at
`:62-68` whenever it runs while full, and `RetryAfter()` deletes lazily on read.
So the bypass requires *sustained* pressure (~36 req/s distributed to keep
32,768 keys inside their 15-minute TTL), not a one-shot 32,768-request flood.
Still Medium, still a fail-open control, but the attack is louder than S3 claims.

### 4.2 U1 — codex's UI chapter missed the one defect it could have computed

Codex UI-04 says responsive and accessibility conformance "is not evidenced" and
attributes the gap to having no browser in the audit environment. Fair for
layout and screen-reader traversal. Not fair here: the failure is arithmetic on
two constants.

`BoneColors.darkBorder = 0x17ffffff` (9% white) composited over
`darkSurface = 0xff211a2d` gives ≈ `#35303f`. Against the surface that is
**≈1.3:1**, where WCAG 1.4.11 requires **3:1** for UI component boundaries. That
token is `colorScheme.outlineVariant`
([`theme.dart:46`](../mobile/lib/ui/theme.dart#L46)) and it draws every text
field border (`:168`, `:172`), every outlined button (`:196`, `:214`), every
chip (`:220`) and every divider (`:267`).

Every form boundary in the app is effectively invisible to a low-vision user,
and the fix is one constant. A source-only audit should have caught this; codex
filed a process gap instead of the defect.

### 4.3 R1 vs DEP-06 — the same fact, and codex's severity is too low

Verified: `server/go.mod:3` is `go 1.25.12`, all four CI/release jobs pin
`1.25.12`, and `server/Dockerfile:1` is `golang:1.26.4`. Codex rates this
**Medium, not a blocker**.

That is too generous. This is a *minor* version gap, not a patch bump: the
shipped container is built with a compiler and standard library that no CI job
ever compiles, vets, races or tests. The artifact users run is the only build
nothing verifies. Hold the opus **High / blocker** rating.

---

## 5. Where the opus audit was wrong — self-corrections

### 5.1 L6 was overstated: the orphan window is bounded, not permanent

The scope mismatch is real and codex missed it entirely.
[`message_store.go:490-522`](../server/internal/storage/message_store.go#L490-L522)
limits the storage-key collection and the message delete to **500 messages**,
but limits the attachment-row delete to **500 join rows**. At two attachments
per message that covers 250 messages, so rows for messages 251–500 survive while
their blobs are enqueued for deletion.

But L6 claims the orphans persist and drift the quota indefinitely. Re-checking
the schema, they do not:

- `message_attachments.attachment_id` is
  `REFERENCES attachment_envelopes(id) ON DELETE CASCADE` and `message_id`
  cascades from `message_envelopes`
  ([`0007_message_attachments.sql:2-3`](../server/migrations/0007_message_attachments.sql#L2-L3)),
  and `foreign_keys(1)` is set on every connection
  ([`sqlite.go:125`](../server/internal/storage/sqlite.go#L125)).
- So the message delete cascades the join rows away, and the orphan reaper
  **later in the same transaction** (`:539-556`) selects
  `NOT EXISTS (… message_attachments …) AND created_at < now-24h` — which now
  matches those very rows.

For attachments older than 24 hours the orphans are reclaimed in the same run.
Only attachments younger than 24 hours (short disappearing-message timers)
survive to a later sweep.

**Revised: Medium, not High.** The real damage is a bounded window of dangling
attachment records whose blobs are already gone (`blob_not_found` on download),
quota drift during that window, and double-enqueued deletion keys — harmless
only because `enqueueBlobDeletion` is `ON CONFLICT DO NOTHING`
([`blob_deletion_store.go:12`](../server/internal/storage/blob_deletion_store.go#L12)).
Still worth fixing: one materialised message set drives all three statements.

### 5.2 S2's severity was too low

The opus audit rated the recovery-token leak **High**. Codex rated it
**Critical** and proved it against a running container. Codex is right. Adopting
codex's severity.

---

## 6. Structural critique

**Codex's strongest chapters are logic, security and architecture.** LOG-01 and
ARCH-01 are the same defect seen from two altitudes and both write-ups are
excellent. The architecture chapter's target shape is sober and correctly
resists prescribing a rewrite.

**Its weakest are UI and testing.** UI-01 ("the core messaging experience is
intentionally unavailable") is a Critical filed against a deliberate, documented
gate — restating the board's own position as a finding inflates the count
without adding information. UI-04, and most of the testing chapter, describe
absent evidence rather than defects. Nine of eleven TEST findings are "there is
no test for X"; true, and derivable from any of the LOG findings without a
separate chapter. TEST-01 is the exception and is genuinely useful.

**Both audits share one blind spot:** neither reviewed the Rust crypto
implementation, and both say so. Codex SEC-03 correctly refuses to convert a
dependency-reachability argument into cryptographic assurance. That judgement is
right and should be preserved verbatim in any release brief.

**On the count.** 96 findings across 8 chapters (76 outside the nice-to-have
chapter), with the same root defect appearing as LOG-01, ARCH-01, TEST-01 and
PERF-08. The cross-referencing is disclosed and honest, but it means the
headline number is roughly 1.5× the number of distinct defects. Fix-order
planning should work from distinct roots.

---

## 7. Agreed without material difference

Both audits found these independently, with matching locations and compatible
fixes. No critique needed — they are simply true.

| Codex | Opus | Finding |
| --- | --- | --- |
| LOG-02 | L1 | Outbox evicts the *oldest* unsent envelope at 100 entries |
| LOG-06 | L3 | MLS outbox has no error handling, backoff, or terminal state |
| LOG-11 | L12-adjacent | `nextAttemptAt` is persisted but no timer wakes the outbox |
| LOG-12 | — | WebSocket disposal can lose a connection opened during shutdown |
| LOG-13 | — | `refreshDevices` rethrows without notifying |
| SEC-05 | L7 | `resetOnError: true` silently destroys the database key |
| SEC-03 | — | Crypto review and RustSec exceptions remain open; keep both gates |
| SEC-09 | — | Trusted-proxy CIDRs are not checked for over-broad ranges |
| PERF-02 | P10 | Push fan-out is unbounded goroutines with serial delivery |
| PERF-03 | L9 | One repair round trip per message during catch-up |
| PERF-04 | P4 | `Hub.Register` is O(n) under the global lock |
| PERF-09 | U9/P5 | Root `AnimatedBuilder` rebuilds the whole tree per notification |
| DEP-01 | R2 | The release gate is a source-marker grep |
| DEP-09 | R8 | Backups are manual with no schedule, verification, or drill |
| ARCH-02 | — | `AppState` is a 1,916-line god object |

Codex-only in this table (LOG-12, LOG-13, SEC-09, ARCH-02) are all real and all
correctly rated non-blocking. Codex DEP-04/05 (backup staging paths and restore
activation) were not re-verified in this pass and are carried forward unassessed
— they read plausible and the opus audit has no equivalent.
