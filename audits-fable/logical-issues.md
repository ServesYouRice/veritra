# Logical Issues — Veritra Audit (audits-fable)

Application logic, async behavior, state management, data handling, and implementation quality. Cross-cutting security findings live in [security-issues.md](security-issues.md); pure efficiency findings in [performance-issues.md](performance-issues.md).

> **Historical snapshot:** findings and severities describe `c939f26`, not the
> current tree. Use [`../audits-codex/README.md`](../audits-codex/README.md) for
> current release status.

**Severity scale:** Critical / High / Medium / Low / Nice-to-have.
**Blocker** = must be fixed before a real production launch.

---

## Summary table

| ID | Title | Severity | Blocker |
|---|---|---|---|
| LOG-0 | Product is non-functional end-to-end: no client crypto | Critical | Yes |
| LOG-1 | Mobile creates channels with `kind: 'text'`, DB only allows `private`/`announcement` | High | Yes |
| LOG-2 | Server never answers WebSocket pings → Dart client kills the connection repeatedly | High | Yes |
| LOG-3 | Attachments and backups are write-only (no list/download endpoints) | High | Yes |
| LOG-4 | New conversation members receive no sync/realtime event | Medium | Yes |
| LOG-5 | Mobile has no global 401/session-expiry handling | Medium | Yes |
| LOG-6 | Message idempotency check is not atomic → concurrent duplicates 500 | Medium | No |
| LOG-7 | Sync catch-up guard drops wake-up signals that arrive mid-catch-up | Medium | No |
| LOG-8 | Logout is impossible while offline | Medium | No |
| LOG-9 | Username is never validated server-side (empty/huge/control chars accepted) | Medium | Yes |
| LOG-10 | Duplicate username on register/setup returns 500 instead of 409 | Medium | No |
| LOG-11 | Channel/invalid enum values surface as 500 `storage_error`, not 400 | Medium | No |
| LOG-12 | Retention changes do not apply to already-sent messages | Medium | No |
| LOG-13 | DM semantics unenforced: N-member "DMs", duplicate DMs, no peer identity | Medium | No |
| LOG-14 | `selectConversation` fires unawaited, uncaught async work | Medium | No |
| LOG-15 | Message history beyond first page is unreachable from the app | Medium | No |
| LOG-16 | Search results are unactionable: server never returns type `conversation` | Medium | No |
| LOG-17 | Expired sessions rows are never purged | Low | No |
| LOG-18 | `parseTime` silently returns zero time on parse failure | Low | No |
| LOG-19 | Reactions can never be removed; reactions on deleted messages allowed | Low | No |
| LOG-20 | Plaintext-key blocklist is a fragile heuristic that also causes false rejects | Low | No |
| LOG-21 | Read receipt rows cascade-delete when the referenced message is pruned | Low | No |
| LOG-22 | Orphaned `.tmp` blobs are never cleaned after a crash | Low | No |
| LOG-23 | `AppState.connect()` is dead code | Low | No |
| LOG-24 | Global `busy`/`error` state couples unrelated flows | Medium | No |

---

## LOG-0 — Product is non-functional end-to-end: no client crypto

- **Severity:** Critical
- **Location:** `mobile/lib/main.dart:15` (wires `UnavailableCryptoService`), `mobile/lib/crypto/crypto_service.dart`, `server/internal/cryptoapi/cryptoapi.go`, `crypto/rust/src/lib.rs`
- **Description:** The shipped mobile app injects `UnavailableCryptoService`, whose `createDeviceKeyPackage()` and `encrypt()` both throw `StateError`. Every onboarding and messaging flow depends on them: `createOwner`, `registerWithInvite`, `claimDeviceLink`, and `sendMessage` in `app_state.dart` all call into the crypto service. The server additionally rejects the reserved placeholder key package. Net effect: **no user can create an account, link a device, or send a message with the real app against the real server.** The only exercisable path is password login on a device that was previously linked — which can never happen through the app.
- **Why it matters:** This is the product. Everything else in this audit is secondary until a real MLS/OpenMLS (or libsignal) implementation is bound to `cryptoapi.ClientCrypto` and the Dart `CryptoService`.
- **Recommended fix:** Execute the Tier-3 plan in `WORK_IN_PROGRESS.md`: integrate OpenMLS via the Rust boundary (FFI to Dart via `flutter_rust_bridge` or similar), implement key-package generation, group state management, encrypt/decrypt, key distribution APIs, and local private-key storage. Keep `TestOnlyCryptoService` strictly in tests (already enforced).
- **Blocker:** Yes — the definitive one.
- **Related risks:** All UI message-rendering work (bubbles show a static "Encrypted message" label) is blocked behind this; so are attachments, backups, and search-over-content.

## LOG-1 — Mobile creates channels with `kind: 'text'`; DB CHECK only allows `private`/`announcement`

- **Severity:** High
- **Location:** `mobile/lib/core/api_client.dart:155` (`String kind = 'text'`), `server/migrations/0001_init.sql:61` (`CHECK (kind IN ('private', 'announcement'))`), `server/internal/storage/sqlite.go:783-804` (`CreateChannel` passes kind through unvalidated)
- **Description:** The Flutter client's `createChannel` defaults to `kind: 'text'` and no caller overrides it. The server handler (`communitySubroute`) does not validate `kind`; storage inserts it directly and the SQLite CHECK constraint rejects it. The user sees a generic "Server storage error."
- **Why it matters:** Channel creation from the app fails **100% of the time**. The whole Communities feature is a dead end in the shipped client, and the failure mode (500 + opaque message) gives the user no way to understand it.
- **Recommended fix:** (1) Change the mobile default to `'private'` (or expose a private/announcement choice in the UI). (2) Validate `kind` in `communitySubroute` and return `400 invalid_channel_kind` so client bugs can't manufacture 500s. (3) Add an integration test that creates a channel through the HTTP API using the client's actual default payload.
- **Blocker:** Yes (feature-level).
- **Related risks:** LOG-11 (enum validation gaps) — same pattern.

## LOG-2 — Server never answers WebSocket pings → Dart client tears the connection down on a loop

- **Severity:** High
- **Location:** `server/internal/realtime/websocket.go:147-201` (`drainClientFrames` discards ping frames without replying), `mobile/lib/sync/sync_service.dart:61` (`socket.pingInterval = const Duration(seconds: 30)`)
- **Description:** RFC 6455 §5.5.2 requires an endpoint to respond to a Ping with a Pong. The server's read loop treats every inbound frame — including client pings (opcode 0x9) — as liveness proof and discards it. Meanwhile the Dart client sets `pingInterval: 30s`; `dart:io`'s `WebSocket` closes the connection when a ping is not answered within the interval. Result: the sync socket is killed and re-established roughly every 30–60 seconds, forever, on every connected device. The reconnect loop plus the catch-up API mask the damage (events are recovered from `/sync/events`), so this looks like it works in testing while actually churning.
- **Why it matters:** In production this means (a) realtime delivery gaps every cycle, (b) constant reconnect load against the server and rate limiter, (c) unnecessary battery/radio use on mobile, and (d) log noise that obscures real failures.
- **Recommended fix:** In `drainClientFrames`, buffer the (masked) payload for control frames and write a Pong frame (opcode 0xA, echoing the ping payload) back to the connection when opcode 0x9 is received. This requires routing writes through the same writer used by the send loop (e.g., a small outbound channel) since two goroutines must not interleave frame writes.
- **Blocker:** Yes for realtime reliability.
- **Related risks:** Also unmasks LOG-7 (dropped catch-up signals) more often, since every reconnect triggers a catch-up.

## LOG-3 — Attachments and backups are write-only

- **Severity:** High
- **Location:** `server/internal/httpapi/api.go:894-975` (`uploadAttachment`, `uploadBackup`); no corresponding GET routes in `Register` (`api.go:31-64`)
- **Description:** Clients can upload encrypted attachment blobs and encrypted backups, and rows are recorded in `attachment_envelopes` / `backup_blobs`, but there is **no endpoint to list or download either**. A recipient can never fetch an attachment; a restoring device can never fetch its backup. `uploads.LocalStore.Open` exists but is never called from any route.
- **Why it matters:** These endpoints currently only consume disk (see SEC-4 on quotas). Shipping upload-only APIs invites clients to store data that can never be retrieved — the worst possible failure mode for a backup feature in particular.
- **Recommended fix:** Add `GET /api/v1/attachments/{id}` (membership-checked via `conversation_id`, owner-checked when conversation is null) and `GET/LIST /api/v1/backups` (owner-only), streaming from `Blobs.Open`. Until then, consider returning `501` from the upload endpoints or documenting them as inert.
- **Blocker:** Yes if attachments/backups are considered part of launch scope; otherwise gate them off.
- **Related risks:** SEC-4 (quota exhaustion), LOG-22 (orphan blobs), account deletion not cleaning blobs (SEC-6).

## LOG-4 — New conversation members receive no sync/realtime event

- **Severity:** Medium
- **Location:** `server/internal/httpapi/api.go:554-592` (`members` subroute records an audit event but publishes nothing), `server/internal/storage/sqlite.go:890-900`
- **Description:** Adding a member (and creating a conversation with initial `member_account_ids`) generates no `sync_events` row and no Hub publish. The added user's client learns about the new conversation only when some *other* event touches it or when the user manually refreshes. Existing members also never learn the roster changed. The mobile sync loop keys refreshes off events (`app_state.dart:_catchUpSyncEvents`), so this silence translates directly into stale UI.
- **Why it matters:** "You've been added to a group but your app doesn't show it until someone sends a message" is a core-flow correctness bug, not polish. It also breaks the mental model that `/sync/events` is a complete durable log.
- **Recommended fix:** Emit a `conversation.member.added` sync event (account-scoped to the new member and conversation-scoped for existing members) from the members endpoint and from `CreateConversation` for each initial member; publish to the Hub for connected members.
- **Blocker:** Yes for group messaging correctness.
- **Related risks:** The membership JOIN in `ListSyncEvents` means the new member *would* see historical conversation events once membership exists — so a single new event is enough to heal the client; only the trigger is missing.

## LOG-5 — Mobile has no global 401/session-expiry handling

- **Severity:** Medium
- **Location:** `mobile/lib/core/api_client.dart:375-407` (`_jsonRequest` throws `ApiException` uniformly), `mobile/lib/core/app_state.dart` (no 401 branch anywhere), `mobile/lib/sync/sync_service.dart:30-47` (reconnect loop retries forever)
- **Description:** Sessions expire after a fixed 30 days and can be revoked remotely (`logout-all`, device revoke). The app never distinguishes 401 from other errors: REST calls surface "Sign-in failed." into whatever screen is open, and the WebSocket loop keeps reconnecting with the dead token every ≤30 s indefinitely. There is no transition back to the connect screen and no re-auth prompt.
- **Why it matters:** Every real user hits this within 30 days. The failure mode is a zombie session: stale data, error snackbars, background reconnect spam against the server.
- **Recommended fix:** Centralize response handling in `ApiClient`; on 401, clear the in-memory session (preserving device identity as `logout()` does), stop the sync service, and land the user on the connect screen in the sign-in mode with a "session expired" notice. Make `WebSocketSyncService` stop after an HTTP 401 upgrade failure instead of retrying.
- **Blocker:** Yes for a public launch (guaranteed 30-day time bomb per user).
- **Related risks:** SEC-5 (no token refresh/rotation) — a sliding-session or refresh design would change where this is handled.

## LOG-6 — Message idempotency check is not atomic

- **Severity:** Medium
- **Location:** `server/internal/storage/sqlite.go:1020-1069` (`SaveMessageEnvelope`: prune → select → membership check → insert, each on separate connections)
- **Description:** The prune, existing-row lookup, and insert are separate statements outside a transaction. Two concurrent sends with the same `(sender_device_id, idempotency_key)` can both pass the lookup; the second insert then violates the UNIQUE constraint and the API returns `500 storage_error` instead of the intended `200 + existing envelope`. Retry storms (exactly the situation idempotency keys exist for — flaky mobile networks resending) are the trigger.
- **Why it matters:** The idempotency contract fails precisely under the conditions it is designed for. Clients see spurious 500s on retry and may re-send with a *new* key, producing duplicates.
- **Recommended fix:** Wrap the flow in a write transaction, or simpler: attempt the INSERT first and on `SQLITE_CONSTRAINT_UNIQUE` re-select and return the existing row as a duplicate. The single-writer connection makes the transaction approach cheap.
- **Blocker:** No, but fix before real client traffic.

## LOG-7 — Sync catch-up guard drops wake-up signals that arrive mid-catch-up

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart:547-556` (`_catchUpSyncEvents`: `if (_catchingUpSync) return;`)
- **Description:** Every WebSocket event triggers `_catchUpSyncEvents()`. If a second event arrives while a catch-up is in flight, the guard returns immediately and the signal is lost. Events written to the server between the in-flight query and the next trigger are not fetched until *another* event happens to arrive. In a quiet conversation, the last message of a burst can sit invisible indefinitely.
- **Why it matters:** Missed-message bugs in a messenger are trust-destroying and very hard for users to report ("it showed up an hour later").
- **Recommended fix:** Replace the boolean guard with a "rerun requested" flag: if a signal arrives during catch-up, loop again after the current pass completes (standard coalescing pattern). This keeps the single-flight property without dropping signals.
- **Blocker:** No, but fix alongside LOG-2 (whose reconnect churn currently papers over it).

## LOG-8 — Logout is impossible while offline

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart:486-495` (`logout`: server call precedes local clear inside `_run`, which aborts on throw)
- **Description:** `logout()` awaits `client.logout(token)`; if the network call throws (airplane mode, server down), `_run` catches the error and `_clearLocalSession` never executes. The user cannot sign out of the app without connectivity.
- **Why it matters:** Signing out is a security action (handing a phone to someone, leaving a shared device). It must always succeed locally.
- **Recommended fix:** Clear the local session unconditionally (finally-style); treat the server-side token revocation as best-effort, optionally queueing it for the next connect.
- **Blocker:** No.

## LOG-9 — Username is never validated server-side

- **Severity:** Medium
- **Location:** `server/internal/httpapi/api.go:102-155` (`createOwner`), `:206-255` (`register`); `server/internal/domain/types.go:223-225` (`NormalizeUsername` only trims + lowercases)
- **Description:** Neither setup nor registration validates the username. Empty string, 500 KB strings (bounded only by the 1 MiB body cap), whitespace, control characters, emoji, RTL-override characters, and homoglyphs are all accepted and stored (`accounts.username` is merely `NOT NULL UNIQUE` — and empty string satisfies NOT NULL).
- **Why it matters:** (a) An empty-username owner is possible. (b) Metadata search matches exact usernames — invisible/bidi characters enable impersonation in any future user-facing directory. (c) Unbounded label lengths will break UI layouts and index performance.
- **Recommended fix:** Enforce a conservative charset (`[a-z0-9._-]`, 3–32 chars, must start alphanumeric) at both endpoints, returning `400 invalid_username`. Mirror the rule client-side for instant feedback.
- **Blocker:** Yes (cheap fix, expensive to retrofit after real accounts exist).

## LOG-10 — Duplicate username returns 500 instead of 409

- **Severity:** Medium
- **Location:** `server/internal/storage/sqlite.go:337-377` (`RegisterWithInvite` surfaces the UNIQUE violation as a generic error), `server/internal/httpapi/api.go:236-243` (maps to `500 register_failed`)
- **Description:** Registering with a taken username violates `accounts.username UNIQUE`; the error is not classified, so the API returns 500 and the mobile client shows "Request failed (500)". The user has no idea the username is the problem.
- **Why it matters:** This is the single most common failure of any registration form; it currently looks like a server outage and pollutes 5xx metrics/alerts.
- **Recommended fix:** Detect the SQLite unique-constraint error for `accounts.username` in storage, return a typed `ErrUsernameTaken`, map to `409 username_taken`, and add a client message for it.
- **Blocker:** No (but trivially cheap and high-visibility).

## LOG-11 — Constraint violations generally surface as 500 `storage_error`

- **Severity:** Medium
- **Location:** `server/internal/httpapi/api.go:1351-1364` (`handleStorageError` default branch); affected inputs include channel `kind` (LOG-1), `member_account_ids` referencing nonexistent accounts (FK violation in `CreateConversation`/`AddConversationMember`), `reply_to_id`/`thread_root_id` referencing nonexistent messages
- **Description:** The API validates some inputs but relies on DB constraints for others. Any constraint trip becomes a 500. Beyond bad UX, the nonexistent-account case doubles as an account-ID validity oracle (see SEC-3).
- **Why it matters:** 4xx-class client mistakes must not manufacture 5xx noise; production alerting on 5xx rate becomes useless otherwise.
- **Recommended fix:** Validate referenced IDs inside the relevant transactions and return typed errors (`404 account_not_found`, `400 invalid_reply_to`, `400 invalid_channel_kind`), keeping `handleStorageError`'s default 500 for genuinely unexpected failures.
- **Blocker:** No.

## LOG-12 — Retention changes do not apply to already-sent messages

- **Severity:** Medium
- **Location:** `server/internal/storage/sqlite.go:923-957` (`UpdateConversationRetention` updates metadata only), `:1050-1060` (expiry stamped per-message at send time)
- **Description:** `expires_at` is computed only when a message is saved. Turning retention on (or shortening it) leaves every existing message with its original (possibly nil) expiry forever; the UI ("the server deletes encrypted envelopes after this time window", `conversation_details_screen.dart:109-115`) implies the policy governs the conversation.
- **Why it matters:** Users enable disappearing messages precisely to limit exposure of what was already said. Signal/WhatsApp semantics (applies to new messages only) are defensible — but then the UI copy and docs must say so explicitly; silently keeping old messages under a "30 days" label is a privacy-expectation violation on a privacy product.
- **Recommended fix:** Decide the semantics. Either (a) apply retroactively: in `UpdateConversationRetention`, update `expires_at = min(existing, created_at + retention)` for existing rows in the same transaction; or (b) keep new-messages-only and change the mobile copy to "applies to new messages".
- **Blocker:** No, but decide before launch.

## LOG-13 — DM semantics are unenforced

- **Severity:** Medium
- **Location:** `server/internal/storage/sqlite.go:816-888` (`CreateConversation` treats `dm` like any kind), `mobile/lib/features/chat/chat_list_screen.dart:135-147` (falls back to the literal title "Direct message")
- **Description:** A `dm` conversation can be created with 0..N extra members, and nothing prevents creating five separate DMs with the same person. There is no member-list endpoint, so the client cannot even render who a DM is with — every DM shows as "Direct message".
- **Why it matters:** DMs are the primary surface of a WhatsApp/Signal-shaped product. Without exactly-two-members enforcement, dedup, and peer identity, the chat list is unusable at even ten conversations.
- **Recommended fix:** Server: enforce exactly one counterpart on `kind=dm`, and make DM creation idempotent per (account pair) — return the existing DM. Add `GET /conversations/{id}/members` (or embed member summaries in `ListConversations`). Client: render the counterpart's username as the DM title.
- **Blocker:** No for the foundation, yes for product launch.

## LOG-14 — `selectConversation` fires unawaited, uncaught async work

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart:525-529`
- **Description:** `unawaited(refreshSelectedMessages().then((_) => markNewestMessageRead(id)))` — `refreshSelectedMessages` performs a network call with no try/catch, and the future's error is never handled. On failure the error is thrown to the zone (crash-report noise; in debug an unhandled-exception overlay), the message pane silently shows the previous conversation's cache or an empty state, and no retry affordance exists.
- **Why it matters:** Opening a conversation on a flaky connection is the most common interaction in the app; it must fail visibly and recoverably.
- **Recommended fix:** Route it through `_run` (or a local try/catch that sets a per-conversation error state) and surface a retry in `ChatScreen`.
- **Blocker:** No.

## LOG-15 — Message history beyond the first page is unreachable

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart:166-181` (`refreshSelectedMessages` always fetches page 1, limit 50), `mobile/lib/core/api_client.dart:204-224` (supports `before`/`after` but no caller uses them), `mobile/lib/features/chat/chat_screen.dart` (no scroll-triggered load)
- **Description:** The server implements cursor pagination (`next_before`) and the API client exposes it, but the UI never loads older pages. Conversation #51+ messages are invisible; scrolling up just stops.
- **Why it matters:** Message history is a baseline expectation. Also, since local persistence of messages doesn't exist, "history" is the server page — capping it at 50 makes long conversations lossy in practice.
- **Recommended fix:** Implement scroll-position-triggered `before=<oldest id>` loading in `_MessageList`, appending to the per-conversation cache; track `next_before` per conversation in `AppState`.
- **Blocker:** No (blocked behind LOG-0 for real content anyway).

## LOG-16 — Search results are unactionable

- **Severity:** Medium
- **Location:** `mobile/lib/features/search/search_screen.dart:129-139` (`onTap` only for `result.type == 'conversation'`), `server/internal/storage/sqlite.go:1345-1412` (`SearchMetadata` only ever returns types `account`, `community`, `channel`)
- **Description:** The client's only tappable result type is one the server never emits. Finding an account cannot start a DM; finding a channel cannot open it. Search is a dead end for 100% of results.
- **Why it matters:** Search is one of only three top-level actions in the chat list; a feature that visibly does nothing erodes trust in the whole app.
- **Recommended fix:** For `account` results, offer "Start DM" (wire to `startConversation(kind: 'dm', memberAccountIds: [id])`). For `channel` results, resolve/open the matching `community_channel` conversation (needs a lookup — either include `conversation_id` in the search payload server-side or match against the local conversations list). Remove the phantom `conversation` branch or make the server emit conversation-title matches.
- **Blocker:** No.

## LOG-17 — Expired session rows are never purged

- **Severity:** Low
- **Location:** `server/internal/storage/sqlite.go:408-453` (sessions only deleted on logout/revoke), `server/internal/app/app.go:110-146` (sweeper covers messages/sync/audit only)
- **Description:** `PrincipalByTokenHash` filters on `expires_at > now`, but expired rows accumulate forever (one per login, 30-day lifetime).
- **Recommended fix:** Add `DELETE FROM sessions WHERE expires_at <= ?` to the retention sweeper.
- **Blocker:** No.

## LOG-18 — `parseTime` silently returns the zero time

- **Severity:** Low
- **Location:** `server/internal/storage/sqlite.go:1876-1882`
- **Description:** Any timestamp that fails RFC3339 parsing becomes `time.Time{}` (year 1) without logging. A future format drift (e.g., a manual DB edit or migration bug) would silently corrupt ordering and expiry logic rather than fail loudly.
- **Recommended fix:** Log a warning (once per call site) or propagate an error from scan helpers; formats are fully controlled today, so this is cheap insurance.
- **Blocker:** No.

## LOG-19 — Reactions cannot be removed; reactions on deleted messages allowed

- **Severity:** Low
- **Location:** `server/internal/httpapi/api.go:783-815`, `server/internal/storage/sqlite.go:1439-1457`
- **Description:** `CreateReaction` upserts but no DELETE route exists, so a reaction is permanent (only replaceable). `MessageByID` returns tombstoned (deleted) messages, so reacting to a deleted message succeeds. The mobile app exposes `sendReaction` in the API client but no UI uses it (dead code today).
- **Recommended fix:** Add `DELETE /messages/{id}/reactions`; reject reactions where `deleted_at IS NOT NULL`. Defer until reactions get UI.
- **Blocker:** No.

## LOG-20 — Plaintext-key blocklist is a fragile heuristic

- **Severity:** Low
- **Location:** `server/internal/httpapi/api.go:1249-1282` (`isForbiddenPlaintextKey`: `plaintext`, `body`, `text`, `message`, `content`, …)
- **Description:** The guard walks arbitrary JSON and rejects any object containing a blocklisted key at any depth. It is (a) trivially bypassed by naming a field `msg_plain` and (b) a false-positive trap: legitimate future `crypto_metadata` containing a key named `content` (e.g., MLS `content_type`? — that one passes, but `content` itself would not) gets rejected. It's defense-in-depth, not a boundary.
- **Why it matters:** Mostly future-proofing: when real crypto metadata arrives, this list will either block valid payloads or silently stop mattering. Don't let it masquerade as the E2EE guarantee.
- **Recommended fix:** Keep it, but document it as advisory; consider restricting the scan to top-level request keys, and add a schema allowlist for `crypto_metadata` once the real protocol lands.
- **Blocker:** No.

## LOG-21 — Read receipts cascade-delete with expired messages

- **Severity:** Low
- **Location:** `server/migrations/0001_init.sql:127-133` (`read_receipts.message_id … ON DELETE CASCADE`), `PruneExpiredMessages`
- **Description:** When a disappearing message that happens to be someone's read cursor is pruned, the receipt row vanishes, regressing that member's read state to "never read anything" in any future unread computation.
- **Recommended fix:** Either `ON DELETE SET NULL` + keep `read_at`, or store the receipt cursor as `(conversation_id, last_read_created_at)` rather than a message FK.
- **Blocker:** No.

## LOG-22 — Orphaned `.tmp` blobs are never cleaned

- **Severity:** Low
- **Location:** `server/internal/uploads/local.go:25-57`
- **Description:** A crash between tmp-file creation and rename leaves `blob_*.tmp` files forever; nothing sweeps the blob directory.
- **Recommended fix:** On startup (or in the sweeper), delete `*.tmp` files older than e.g. 1 hour in `StoragePath`.
- **Blocker:** No.

## LOG-23 — `AppState.connect()` is dead code

- **Severity:** Low
- **Location:** `mobile/lib/core/app_state.dart:59-64`
- **Description:** `connect()` (which probes `setupStatus`) is never called from any screen; the connect screen goes straight to mode-specific actions. Either wire it up (it would enable setup-aware mode selection — see UI-3) or remove it.
- **Blocker:** No.

## LOG-24 — Global `busy`/`error` state couples unrelated flows

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart:43-44`, `_run` at `:633-645`; consumed by every screen
- **Description:** One `busy` flag and one `error` string serve the whole app. Consequences: sending a message disables the "New community" FAB; a failed invite creation leaves an error that the connect screen would render if the user signs out; two overlapping `_run` calls interleave (`busy` is reset by whichever finishes first — no queuing or per-flow isolation).
- **Why it matters:** As the app grows, this produces spurious disabled buttons, misplaced error banners, and race-prone state transitions. It is the single largest state-management refactor lever in the client.
- **Recommended fix:** Move to per-operation state (e.g., per-feature controllers or an `AsyncValue`-style wrapper per action), or at minimum: per-screen error channels and named busy flags (`sendingMessage`, `creatingInvite`, …).
- **Blocker:** No (refactor, not a defect), but it multiplies UI bugs until addressed.

---

## Production Blockers

Things that **must** be resolved before real users touch this system, in order:

1. **LOG-0 — Production E2EE crypto.** Nothing works without it. (Tracked as Tier-3 in `WORK_IN_PROGRESS.md`; weeks of work.)
2. **SEC-1 — Conversation role demotion hole** (see security-issues.md). Small fix, real privilege problem in code that *does* run today.
3. **LOG-1 — Channel creation broken end-to-end** (client/server enum mismatch).
4. **LOG-2 — WebSocket ping/pong violation** causing perpetual reconnect churn.
5. **LOG-4 — Silent membership changes** (members never learn they were added).
6. **LOG-3 / SEC-4 — Write-only blob endpoints without quotas** — either finish (download + quotas) or disable.
7. **LOG-5 — No session-expiry handling in the app** (guaranteed 30-day failure for every user).
8. **LOG-9 — Username validation** (must land before real accounts exist; retrofitting is painful).
9. **Missing mobile platform folders** — `mobile/` has no `android/`/`ios/` directories; the app cannot be built for devices at all (see production-readiness.md, OPS-1).
10. **Push, QR device linking, message decrypt/render** — the remaining Tier-3 items; without push, a messenger only receives messages while foregrounded.
