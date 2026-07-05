# Additional Findings — Veritra Audit (audits-fable)

A second pass over the areas the original seven files covered thinly: the message/call/device-link subroutes, the plaintext-prohibition boundary, the sync-event durability contract, push/URL handling, and client-side retry/idempotency. Each item below was verified against the tree at the same commit the other files reference; every finding is new (not a restatement) unless explicitly cross-linked.

**Severity scale:** Critical / High / Medium / Low / Nice-to-have.
**Blocker** = must be fixed before a real production launch.

IDs continue the existing sequences: `SEC-15+`, `LOG-25+`, `UI-21+`, `OPS-15+`, `NTH-34+`.

---

## Summary table

| ID | Title | Severity | Blocker |
|---|---|---|---|
| SEC-15 | Call metadata bypasses the plaintext-prohibition boundary; stored unencrypted, broadcast to members | High | Yes |
| SEC-16 | No password-change or password-reset flow exists at all | Medium | Yes |
| SEC-17 | Mobile defaults to cleartext HTTP with only an advisory warning | Medium | No |
| LOG-25 | Sync cursor past the 30-day prune horizon yields a silent, permanent gap | Medium | Yes |
| LOG-26 | `call_sessions` is insert-only: no lifecycle states, no pruning | Medium | No |
| LOG-27 | Sync-event write is not atomic with the message write (durability, not just throughput) | Medium | No |
| LOG-28 | Client idempotency keys are not reused across retries → server idempotency protects nothing | Low | No |
| UI-21 | Connect screen pre-fills `http://localhost:8080`; no https enforcement for remote hosts | Low | No |
| NTH-34 | No block/mute-user capability | Nice-to-have | No |
| NTH-35 | No per-conversation notification muting (design in before push ships) | Nice-to-have | No |

Corrections to earlier files are collected at the end.

---

## SEC-15 — Call metadata bypasses the plaintext-prohibition boundary

- **Severity:** High
- **Location:** `server/internal/httpapi/api.go:1009-1026` (`createCall`), `server/internal/storage/sqlite.go:1515-1536` (`CreateCallSession` stores `metadata_json` verbatim), `server/migrations/0001_init.sql:164` (`call_sessions`)
- **Description:** Every other member-reachable content write path — `createMessageEnvelope`, message `edit`/`delete`, and `reactions` — routes its body through `containsPlaintextMessageKey` and requires a ciphertext marker (`decodeEncryptedMutation` / the plaintext guard). `createCall` does not: it uses plain `decodeJSON` and passes the client's `metadata` straight into `call_sessions.metadata_json` **unencrypted and unvalidated**, then publishes the whole record to every conversation member via `Hub.Publish` and writes it into `sync_events`. Membership *is* checked (in `CreateCallSession`), so this is not the SEC-2 class of missing-authz — it is a hole in the "server stores ciphertext only" invariant that the rest of the audit (and the codebase's own tests) treats as a hard boundary.
- **Why it matters:** (a) It is the only conversation-scoped route that persists arbitrary plaintext client JSON on the server, directly contradicting the plaintext-persistence prohibition the security posture is built on. (b) It pre-positions a concrete privacy leak: the field exists to carry call signaling, and real WebRTC SDP/ICE candidates contain participants' IP addresses and network topology. Shipping the media path later will pour exactly that metadata into an unencrypted, server-readable, member-broadcast column unless this is fixed first. (c) There is no size cap or schema on the field beyond the 1 MiB body limit.
- **Recommended fix:** Decide the call-signaling privacy contract now. Either (a) require the signaling payload to be an encrypted envelope like messages (run it through the same plaintext guard + ciphertext marker), or (b) if some routing metadata must stay server-visible, define an explicit allowlisted schema and document precisely what the server can see — do not accept free-form JSON. Add a test mirroring the message plaintext-rejection tests for the call endpoint.
- **Blocker:** Yes — must be resolved before the calls feature is reachable, and the boundary decision should be made before the field is load-bearing.
- **Related:** SEC-2 (unguarded route class), LOG-26 (call lifecycle), the plaintext-persistence tests noted under "Positive observations" in security-issues.md.

## SEC-16 — No password-change or password-reset flow exists

- **Severity:** Medium
- **Location:** whole system — the route table in `server/internal/httpapi/api.go:31-64` has no change-password or reset endpoint; auth surface is login / logout / logout-all / register / setup only
- **Description:** There is no way for a user to change their password, and no recovery path if it is forgotten. Because instances are invite-only with no email/phone on file, "forgot password" cannot be solved out-of-band, and device-linking does not re-establish a password (a newly linked device gets a session, not the ability to set credentials). A user whose password is compromised cannot rotate it; a user who forgets it loses the account permanently.
- **Why it matters:** Password change is the single most basic account-security action and is missing entirely. The gap is invisible today because LOG-0 blocks all onboarding, but it becomes a guaranteed support/lockout problem the moment real accounts exist — and it is far cheaper to add now than to retrofit a recovery story after users have data. SEC-7 (this audit already) discusses re-authentication for destructive actions but assumes a password-change primitive that does not exist.
- **Recommended fix:** Add `POST /api/v1/account/password` requiring the current password (ties into the SEC-7 sudo-mode work) and re-hashing with the existing bcrypt path; invalidate other sessions on change (reuse `logout-all`). Separately decide a recovery contract — recovery-key-based (pairs with NTH-5 encrypted backup) is the privacy-consistent option since there is no email to reset against. Document explicitly that without it, a lost password = lost account.
- **Blocker:** Yes for a public launch (belongs on the release-gate checklist); the recovery contract can be a fast-follow but the change-password endpoint should land before real accounts.
- **Related:** SEC-7 (re-auth), SEC-5 (session lifetime), NTH-5 (recovery key).

## SEC-17 — Mobile defaults to cleartext HTTP with only an advisory warning

- **Severity:** Medium
- **Location:** `mobile/lib/features/auth/connect_screen.dart:17` (`text: 'http://localhost:8080'`), `:262` (helper text "in cleartext. Use https:// in production."), `mobile/lib/core/api_client.dart:383` (`Uri.parse(baseUrl).resolve(path)` — no scheme check)
- **Description:** The instance-URL field is pre-filled with an `http://` URL and the app will connect to any `http://` host the user enters. The only guard is advisory helper text. Passwords, bearer tokens, and every request/response travel in cleartext if a user points the app at a plain-HTTP remote server — which is easy to do by copying a server address that happens to omit the scheme, or during self-hosting setup.
- **Why it matters:** For a privacy-first messenger, silently permitting cleartext transport to a non-loopback host defeats the transport-security assumption that the whole E2EE story sits on top of (tokens in the clear are as good as account takeover). A prefilled `http://` default also normalizes the insecure choice.
- **Recommended fix:** Allow `http://` only for loopback/`.local` hosts; for any other host require `https://` (or gate `http://` behind an explicit, clearly-worded confirmation, not passive helper text). Consider defaulting the field to `https://`. Mirror this as a validator in the UI-2 form work.
- **Blocker:** No (but should precede any non-localhost use).
- **Related:** UI-2 (form validation), UI-21 (the default value), SEC-8 (URL validation discipline).

## LOG-25 — Sync cursor past the prune horizon is a silent, permanent gap

- **Severity:** Medium
- **Location:** `server/internal/app/app.go:110-136` (`PruneSyncEvents` at a 30-day-default cutoff), `server/internal/httpapi/api.go:1028-1037` (`syncEvents` returns whatever remains after `after`), `mobile/lib/storage/local_store.dart` (persists the sync cursor across restarts), `server/internal/storage/sqlite.go` (`ListSyncEvents`)
- **Description:** The client persists its `after` cursor and resumes from it on every start. Sync events older than the retention window (default 30 days, `PRIVATE_MESSENGER_SYNC_EVENT_RETENTION_DAYS`) are deleted by the sweeper. A device offline longer than that window resumes with a cursor pointing *before* the pruned horizon; `/sync/events?after=<old>` simply returns the surviving newer rows, and the client concludes it is fully caught up. Events destroyed in the gap between the cursor and the oldest surviving row are never delivered and never detected — there is no "cursor too old, do a full resync" signal in the protocol.
- **Why it matters:** This is a silent missed-message class distinct from LOG-7 (which drops *live* signals). LOG-4's healing argument and the general framing of `/sync/events` as "a complete durable log" both assume the log is complete back to the client's cursor; once pruning is in play that assumption breaks for any sufficiently-stale device. Missed-message bugs are the most trust-destroying failure in a messenger and the hardest for users to report.
- **Recommended fix:** Track the oldest retained event id (or a monotonic "prune watermark") and have `/sync/events` return an explicit `resync_required` / `cursor_expired` response when `after` predates it; the client then performs a full state refetch (conversations + first pages) and resets its cursor. Alternatively, tie the retention window to a documented maximum offline period and surface it. Add a test: prune below a cursor, then assert the API signals resync rather than silently returning a subset.
- **Blocker:** Yes for real users (data-loss-shaped); sits alongside LOG-4 in the "before real users" tier.
- **Related:** LOG-4 (membership events heal via the log), LOG-7 (live-signal coalescing), LOG-17 (session-row pruning).

## LOG-26 — `call_sessions` is insert-only: no lifecycle, no pruning

- **Severity:** Medium
- **Location:** `server/internal/storage/sqlite.go:1515-1536` (`CreateCallSession` hardcodes `state = 'ringing'`), no update path anywhere; `server/internal/app/app.go:110-146` (sweeper prunes messages/sync/audit only), route table has no call-lifecycle endpoints
- **Description:** A call session is created in state `'ringing'` and never transitions — there is no answer/decline/end/timeout endpoint and nothing ever updates or deletes the row. The retention sweeper does not touch `call_sessions`. Every member can create sessions up to the general rate limit, so the table grows without bound and every row is stuck "ringing" forever.
- **Why it matters:** (a) Unbounded growth on the single-writer SQLite instance (compounds the PERF and SEC-4 disk-pressure story). (b) The feature is non-functional as a call primitive: with no state machine there is no way to represent a call being answered, declined, missed, or ended — so even when media lands, the signaling layer can't drive UI. The stack table describes this as "signaling records only" but does not flag that the records have no lifecycle or cleanup.
- **Recommended fix:** Define the call state machine (`ringing → active → ended`, plus `declined`/`missed`/`timeout`) with an update endpoint, membership-checked; auto-expire stale `ringing` sessions (e.g., 60 s) and add `call_sessions` to the retention sweep. Do this alongside SEC-15 (the metadata contract) since they touch the same table.
- **Blocker:** No (feature is pre-launch), but design before building the media path.
- **Related:** SEC-15 (call metadata), PERF-8 (prune batching), roadmap calls item in nice-to-haves.md.

## LOG-27 — Sync-event write is not atomic with the message write (durability)

- **Severity:** Medium
- **Location:** `server/internal/httpapi/api.go:688-743` (`createMessageEnvelope`), `:848-854` (`saveSyncEvent` — failure is warn-only), `:841-846` (`publishMessageEvent`)
- **Description:** A message send performs `SaveMessageEnvelope` and then, separately, `SaveSyncEvent`. If the sync-event insert fails, the code only logs a warning (`a.warn("sync_event_save_failed", …)`) — the envelope is already committed and the client gets a success response, but no durable `sync_events` row exists. Offline devices (which learn about messages only through `/sync/events`) will never see that message; connected devices only got it via the best-effort Hub push, which is explicitly not durable.
- **Why it matters:** PERF-2 already recommends folding these into one transaction, but frames it purely as a throughput win. The more important reason is correctness: the sync log is the durable delivery contract, and today a partial failure silently breaks it for exactly the devices that depend on it most. This is a latent single-message-loss bug, not just an efficiency nit.
- **Recommended fix:** Wrap the envelope insert and the sync-event insert in one write transaction (the single writer makes this cheap, per PERF-2) so a message is durable if and only if its sync event is. If the transaction fails, return an error to the client rather than acking. This subsumes the PERF-2 change.
- **Blocker:** No, but fix before real client traffic (pairs with PERF-2).
- **Related:** PERF-2 (same merge, throughput framing), LOG-25 (durable-log completeness), LOG-4 (event-driven delivery).

## LOG-28 — Client idempotency keys are not reused across retries

- **Severity:** Low
- **Location:** `mobile/lib/crypto/crypto_service.dart:33` (`idempotencyKey: DateTime.now().microsecondsSinceEpoch.toString()`), `mobile/lib/core/app_state.dart` (send path has no retry that preserves the key), `mobile/lib/core/models.dart:110-131` (key carried but minted per build)
- **Description:** The idempotency key is generated fresh at message-build time from the current timestamp, and the client has no retry logic that reuses the same key for a resend. The server's idempotency mechanism (and the LOG-6 atomicity fix the audit recommends) only helps when the *same* key arrives twice — but the client never sends the same key twice, because every user-initiated resend builds a new envelope with a new key.
- **Why it matters:** LOG-6 fixes the server race, but without the client half, the whole feature is inert: a flaky-network retry produces a *new* key and therefore a duplicate message rather than a deduplicated one — the exact outcome idempotency keys exist to prevent. The two findings must land together to have any effect.
- **Recommended fix:** Generate the idempotency key once when the user hits send, persist it with the pending/optimistic message (ties into UI-15), and reuse it for every retry of that message until it succeeds. Use a random UUID rather than a timestamp to avoid collisions across rapid sends.
- **Blocker:** No, but pair with LOG-6 — neither is useful alone.
- **Related:** LOG-6 (server-side idempotency race), UI-15 (pending/failed message state + retry).

## UI-21 — Connect screen pre-fills a cleartext localhost URL

- **Severity:** Low (overlaps SEC-17)
- **Location:** `mobile/lib/features/auth/connect_screen.dart:17`
- **Description:** The instance-URL field defaults to `http://localhost:8080`. Convenient for local dev, but it ships as the product default and steers users toward an `http://` mental model (see SEC-17 for the security consequence).
- **Recommended fix:** Default to `https://` (empty host) for release builds, or make the localhost default a dev-only flavor (ties into NTH-24's demo-mode build flavor). Covered operationally by SEC-17's scheme enforcement.
- **Blocker:** No.
- **Related:** SEC-17, UI-2, NTH-24.

## NTH-34 — No block/mute-user capability

- **Severity:** Nice-to-have (product baseline)
- **Description:** There is no way for a user to block or mute another user. The audit covers a *consent* model for being added to conversations (SEC-3) and an *admin/moderation* surface (OPS-9), but user-to-user block/mute — table stakes for any messenger and the natural user-level complement to both — is absent. Without it, the only defense against harassment from an already-invited user is operator intervention.
- **What:** Per-account block list (suppress messages/typing/calls/adds from blocked accounts, server-enforced), plus a lighter per-conversation mute. Pairs with the SEC-3 consent model and the NTH-2 identity work (you need to see who you're blocking).
- **Related:** SEC-3 (consent to be added), OPS-9 (admin moderation), NTH-2 (identity).

## NTH-35 — No per-conversation notification muting

- **Severity:** Nice-to-have
- **Description:** There is no notion of muting notifications for a conversation. This is cheap to design into the push subscription/delivery contract now (NTH-1) and expensive to bolt on after the push payload format is fixed.
- **What:** A per-account, per-conversation mute flag honored at push-send time; expose it in conversation details (near the retention control).
- **Related:** NTH-1 (push), SEC-8 (push endpoint validation), the push privacy contract.

---

## Corrections and refinements to earlier files

- **SEC-2 scope holds, with a caveat.** The claim that `typing` is "the only conversation-scoped route without the membership guard" is correct for *authorization* — `createCall` checks membership in the storage layer. But `createCall` is unguarded in a *different* dimension (plaintext persistence), tracked here as SEC-15. Worth cross-noting so the two aren't conflated.
- **SEC-12 slightly overstates invite abuse.** Invite creation is bounded: `createInvite` (`api.go:262-293`) clamps `max_uses` to `[1, 10000]` and expiry to ≤90 days, and `CreateInvite` (`sqlite.go:483-501`) floors `max_uses` at 1. The residual real issue is that invites created *without* an expiry cannot be revoked (no revoke endpoint) — which is an OPS-9 admin-surface gap, not an unbounded-creation gap. Recommend rewording SEC-12 to drop "unlimited invites" and point the invite-revocation piece at OPS-9.
- **OPS-14 (naming) has an extra instance.** `PRIVATE_MESSENGER_SYNC_EVENT_RETENTION_DAYS` is read via raw `os.Getenv` in `app.go:112`, not through `config.Load()` (`config/config.go`), so it is invisible to anyone reading the config package to learn the tunables. Fold into OPS-14 / OPS-6 (config surface consistency).

## Amendments to the blocker lists

- Add **SEC-16 (password change)** to the production-readiness release-gate checklist (auth completeness).
- Add **SEC-15 (call plaintext boundary)** to the blocker set gating the calls feature, and note the boundary decision is due before the `call_sessions.metadata_json` field is load-bearing.
- Place **LOG-25 (sync cursor past prune horizon)** in the "must fix before real users" tier next to LOG-4 — it is data-loss-shaped, not polish.
