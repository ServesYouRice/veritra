# Logical Issues — Application Logic, Data Handling, Implementation Quality

Overall: the server codebase is unusually disciplined for an MVP (transactions used correctly, idempotency handled, fail-closed crypto boundaries, careful timing-attack mitigation). The findings below are the exceptions, ordered by severity.

---

## L-1. `ClaimConversationKeyPackages` queries a table that does not exist

- **Severity:** Critical
- **Location:** `server/internal/storage/key_package_store.go:77` and `:86`; route `POST /api/v1/conversations/{id}/key-packages/claim` (`server/internal/httpapi/key_package_handlers.go:57`)
- **Problem:** The store queries `conversation_members` (`SELECT ... FROM conversation_members WHERE conversation_id = ...` and the `JOIN conversation_members cm` at line 86). No migration creates a table or view named `conversation_members` — the schema's membership table is `memberships` (`server/migrations/0001_init.sql:76`). Every call to this endpoint fails with `no such table: conversation_members`, surfaced to clients as a 500 `storage_error`.
- **Why it matters:** Key-package claiming is the *entry point of the entire MLS group-creation flow* the rest of the roadmap depends on. When mobile MLS orchestration lands, group creation will be dead on arrival against a real database. It also proves a test-coverage hole: nothing in `sqlite_test.go` or the HTTP tests exercises this function (see `testing-gaps.md` T-1).
- **Recommended fix:** Replace both references with `memberships` (`WHERE conversation_id = ? AND account_id = ?` already matches the `memberships` shape), and add a store-level test that publishes packages from device A and claims them from device B in a shared conversation. Consider a CI guard that runs `EXPLAIN` (or simply executes) every store query against a migrated schema.
- **Blocker before production:** Yes.
- **Related risks:** Any other drift between query text and schema; the recommended query-verification test would catch the class.

## L-2. WebSocket per-IP limit counts the reverse proxy's IP — instance-wide cap of 20 realtime connections

- **Severity:** High
- **Location:** `server/internal/httpapi/call_sync_handlers.go:202-217` (`syncWebSocket`), `server/internal/realtime/hub.go:17` (`maxConnectionsPerIP = 20`)
- **Problem:** `syncWebSocket` derives `remoteIP` from `r.RemoteAddr` only. The documented production topology (Compose + Caddy, or systemd + host reverse proxy) puts every client behind one proxy IP. The HTTP rate limiter correctly resolves `X-Forwarded-For` against `TrustedProxies` (`app.go:522-556`), but the hub does not. Result: once 20 sockets are open — i.e. roughly 20 online devices — **every further `/api/v1/sync/ws` connection on the instance is rejected with 429** `realtime_connection_limit`.
- **Why it matters:** Realtime silently degrades for the 21st+ user in exactly the deployment the repo recommends. Clients fall back to reconnect loops (1–30 s backoff), hammering the endpoint and burning battery, and message delivery latency degrades to push/poll.
- **Recommended fix:** Reuse the rate limiter's trusted-proxy client-IP resolution for the hub registration (extract `clientIP()` into a shared helper and pass the resolved IP), or drop the per-IP cap when `TrustedProxies` is configured and the peer is a trusted proxy.
- **Blocker before production:** Yes.
- **Related risks:** Same blind spot means the per-IP realtime protection is ineffective *against* abuse when the abuser is behind the proxy — resolving XFF fixes both directions.

## L-3. Concurrent read-modify-write races on the mobile secure-storage record

- **Severity:** High
- **Location:** `mobile/lib/storage/local_store.dart` (`SecureLocalStore` — every method does `_readRecord()` → mutate → `_writeRecord()`), callers in `mobile/lib/core/app_state.dart`
- **Problem:** The entire local state (session, cursor, snapshot, outbox, crypto state) lives in one JSON record, and every operation is an unsynchronized async read-modify-write. `AppState` runs several of these concurrently: `_catchUpSyncEvents()` (fires on every WS event) calls `saveSnapshot`, while `sendMessageTo` calls `enqueueEnvelope`, while `_removeFromOutbox` calls `removePendingEnvelope`, and `_startSync` kicks off catch-up + `_flushOutbox` simultaneously. Interleavings like *enqueue reads record → catch-up writes snapshot → enqueue writes its stale copy* silently drop the snapshot/cursor, or worse: a queued envelope can be lost after a crash even though the UI showed it "pending", or an acknowledged sync cursor can rewind.
- **Why it matters:** This is the layer whose stated contract is "committed in the same record so a crash cannot acknowledge state that was not persisted" (comment at line 144). The race breaks exactly that guarantee under normal use (message arriving while sending).
- **Recommended fix:** Serialize all record access through a single async mutex/queue inside `SecureLocalStore` (a `Future` chain field is enough in Dart), or move to a proper transactional store (e.g. sqflite + SQLCipher) given the size concerns in P-6.
- **Blocker before production:** Yes (data-loss class).
- **Related risks:** P-6 (record size limits) compounds this; the crypto-state counter check can also throw spuriously under interleaving.

## L-4. A "DM" can be silently converted into a group conversation

- **Severity:** Medium–High
- **Location:** `server/internal/storage/community_store.go` (`ManageConversationMember` — no `kind` check); `POST /api/v1/conversations/{id}/members` (`conversation_handlers.go:177`); UI: `mobile/lib/features/chat/conversation_details_screen.dart` ("Add member" is offered for DMs too, since the DM creator holds the `owner` membership role)
- **Problem:** `CreateConversation` enforces `dm` = exactly 2 members, but `ManageConversationMember` never checks `conversations.kind`, so the DM creator can add a third account afterwards. The other participant gets no consent prompt — just a `membership.updated` sync event — and the conversation still renders as "Direct message" in the client.
- **Why it matters:** In a privacy-first messenger, "DM" is a trust boundary. The non-creator believes messages are visible to one person. (True message confidentiality will eventually be enforced by MLS group membership, but the server metadata model and the UI both misrepresent the conversation today, and server-added members will be able to claim key packages / receive future envelopes.)
- **Recommended fix:** In `ManageConversationMember` (and `AddConversationMember`), reject member additions when the conversation kind is `dm` (`ErrForbidden`). Hide "Add member" for DMs in `conversation_details_screen.dart`.
- **Blocker before production:** Yes (cheap fix, trust-model integrity).
- **Related risks:** The asymmetric membership role (`owner` vs `member`) in DMs also means only one side can set retention — decide whether that is intended.

## L-5. Attachment/backup **downloads** are killed at 30 seconds

- **Severity:** Medium
- **Location:** `server/internal/app/app.go:151-171` (`routeTimeouts`)
- **Problem:** The 15-minute deadline is applied only to the exact paths `/api/v1/attachments` and `/api/v1/backups` (the upload endpoints). Downloads go through `/api/v1/attachments/{id}` and `/api/v1/backups/{id}`, which fall into the default 30-second read+write deadline. A 50 MB attachment (the upload cap) needs ≥13 Mbps sustained to survive 30 s; a 100 MB backup needs ≥27 Mbps. Mobile/roaming clients will see truncated downloads with no way to resume (no Range support — see P-8).
- **Why it matters:** Backup restore is a recovery path; a user restoring on a hotel Wi-Fi simply cannot get their backup down.
- **Recommended fix:** Match prefixes (`strings.HasPrefix(path, "/api/v1/attachments/")`, same for backups) into the long-deadline branch, or scale the deadline by content size. Add HTTP Range support for resumability.
- **Blocker before production:** Yes for backups, borderline for attachments.

## L-6. Global `busy`/`error` single-flight in `AppState` serializes and cross-contaminates unrelated actions

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart:1104-1119` (`_run`), used by ~20 actions
- **Problem:** Every mutating action shares one `busy` flag and one `error` string. Consequences: (a) while any action is in flight the composer send button, invite creation, retention change, etc. are all disabled (`busy` gates them all); (b) an error from a background flow (e.g. `_catchUpSyncEvents` sets `error` directly at line 999) can surface in whatever screen happens to be watching, and `sendMessageTo`'s caller interprets `state.error != null` as "my send failed" (`chat_screen.dart:163-170`) even if the error came from an unrelated concurrent operation; (c) `startConversation`/`createInvite` return `null` on *any* pre-existing error.
- **Why it matters:** Misattributed errors and mystery-disabled buttons are the classic symptoms users report as "the app is flaky"; they are also unreproducible in tests.
- **Recommended fix:** Scope busy/error per operation family (send state is already tracked per envelope via `_outboxStates` — extend that pattern), or return errors from the action methods instead of routing through shared mutable state.
- **Blocker before production:** No, but strongly recommended before real users.

## L-7. Poison outbox envelopes are retried forever

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart:1064-1088` (`_flushOutbox`), `sendMessageTo`
- **Problem:** A queued envelope the server permanently rejects (member removed → 403, conversation deleted → 404, `idempotency_conflict` → 409, envelope > 1 MB → 400) stays in the outbox and is retried on every reconnect, forever. `_flushOutbox` also aborts the whole loop on the first failure, so one poison envelope blocks flushing of every envelope queued after it.
- **Why it matters:** After the crypto lands this becomes user-visible: one stuck message pins the outbox and generates a 4xx per reconnect for the lifetime of the install.
- **Recommended fix:** On 4xx responses (except 401/408/429), mark the envelope permanently failed — keep it visible with a "delete / retry" affordance — and continue flushing subsequent envelopes.
- **Blocker before production:** No (crypto-gated today), yes before GA.

## L-8. Shared attachments can be deleted while still referenced by a live message

- **Severity:** Medium–Low
- **Location:** `server/internal/storage/message_store.go:388-468` (`PruneExpiredContent`); `content_handlers.go:100-113` (owner DELETE)
- **Problem:** Two paths delete attachment rows/blobs without checking for other referencing messages: (a) the sweeper deletes any attachment linked to *an* expired message, even if a second, unexpired message references the same attachment ID (the same owner can legitimately attach one upload to two messages — `SaveMessageEnvelope` allows it); (b) the owner can `DELETE /api/v1/attachments/{id}` at any time while recipients' messages still reference it. (b) may be intended (sender revocation), but (a) is straightforwardly wrong.
- **Recommended fix:** In the sweeper, only delete attachments whose *every* linked message is expired (`NOT EXISTS` an unexpired link). Decide and document (b) as sender-revocation semantics.
- **Blocker before production:** No.

## L-9. Blob files orphaned when post-commit deletion fails are never cleaned up

- **Severity:** Medium–Low
- **Location:** `server/internal/app/app.go:190-200` (sweeper), `call_sync_handlers.go:182-199` (`deleteAccount`), `content_handlers.go`
- **Problem:** The DB row is deleted first, then the blob file; if `Blobs.Delete` fails (transient FS error, container restart mid-loop) the file remains on disk with no DB reference. Nothing reconciles storage-directory contents against `attachment_envelopes`/`backup_blobs` — the temp-file cleaner only handles `*.tmp`. Orphans accumulate silently and count against the operator's disk (not against quotas, which are computed from DB rows).
- **Recommended fix:** Add a periodic reconciliation pass in the sweeper: list blob dir, delete files (older than a grace period) whose key appears in neither table. This also covers crash-between-commit-and-delete.
- **Blocker before production:** No.

## L-10. `PutEncryptedBlob` renames without fsync

- **Severity:** Low
- **Location:** `server/internal/uploads/local.go:82-114`
- **Problem:** The blob temp file is closed and renamed without `file.Sync()` (contrast with `copyFile` in `main.go` which does sync). After a power loss, the DB row (WAL-synced) can exist while the blob content is zero-length/partial. Download then serves a corrupt blob whose SHA won't match its recorded `ciphertext_sha256`, but nothing verifies at serve time.
- **Recommended fix:** `Sync()` before close/rename; optionally verify size-on-disk against the DB at serve time and 404+log on mismatch.
- **Blocker before production:** No.

## L-11. No endpoint to fetch a single message envelope — sync design references one

- **Severity:** Medium
- **Location:** `server/internal/httpapi/api.go` route table; comment in `conversation_handlers.go:580-583` ("just the IDs the client needs to refetch the full envelope")
- **Problem:** Sync events intentionally carry only `{message_id, conversation_id}`, expecting clients to refetch the envelope. But there is no `GET /api/v1/messages/{id}`. The mobile client works around it by refetching the newest page of the *selected* conversation only — edits/deletes of messages older than the newest 100, or events for unselected conversations, are only reconciled if the user scrolls/opens at the right time (and the client never paginates backwards — see UI-5).
- **Recommended fix:** Add `GET /api/v1/messages/{id}` (membership-checked; it already exists internally as `MessageByID` + a membership check) so catch-up can fetch exactly the referenced envelopes.
- **Blocker before production:** No for the shell, yes for correct sync once messages render.

## L-12. No way to leave a conversation, remove a member, or delete a conversation/community

- **Severity:** Medium
- **Location:** API surface (`server/internal/httpapi/api.go`) — membership rows can only be created/updated, never deleted (only whole-account deletion removes them); no conversation/community/channel deletion endpoints; the client's conversation-details screen even notes "The server exposes no member list endpoint yet" for conversations.
- **Problem:** A user added to a group is a member forever: they keep receiving envelopes, push wakes, and unread counts, and they appear in `ConversationRecipientsForSender` (block only silences one direction of *content*, not membership). Moderation ("remove this account from the group") is impossible.
- **Why it matters:** Leave/kick are table-stakes messenger semantics and also MLS-relevant (removal must eventually trigger MLS commits) — the API shape should exist before the crypto orchestration is built on top.
- **Recommended fix:** Add `DELETE /conversations/{id}/members/{accountId}` (self-leave allowed; kick requires `CanManageMembers` + rank check), a conversation member-list endpoint, and emit `membership.removed` sync events. Design the MLS-removal hook now.
- **Blocker before production:** Yes (product completeness + abuse handling).

## L-13. Members have no password recovery at all

- **Severity:** Medium
- **Location:** `reset-owner-password` CLI (`server/cmd/messenger-server/main.go:113`) is owner-only; no admin "reset member password" or re-invite flow
- **Problem:** A member who forgets their password is permanently locked out (registration is invite-only and usernames are unique, so they cannot even re-register under the same name). The only paths are DB surgery or account deletion by… the locked-out user, which requires auth.
- **Recommended fix:** Admin-initiated reset: generate a one-time re-enrollment code that lets the user set a new password on an existing account (must also rotate device secrets / revoke sessions, and — later — trigger MLS credential rotation). Document the recovery story in `docs/recovery.md`.
- **Blocker before production:** Yes for a real user base.

## L-14. `saveSyncEvent` failures still publish realtime events with `ID: 0`

- **Severity:** Low
- **Location:** `server/internal/httpapi/conversation_handlers.go:542-548`; all `a.Hub.Publish(..., ID: eventID)` call sites
- **Problem:** If the durable insert fails, the code logs a warning and proceeds to publish a realtime event with ID 0. Clients that only use events as a catch-up trigger are fine, but the event is unrecoverable via `/sync/events` (never persisted) — a client that processes realtime payloads directly (future optimization) would apply state that catch-up can't reproduce.
- **Recommended fix:** Skip the realtime publish when the durable write fails (the message endpoint already gets this right by writing envelope+event in one transaction — L-goodness worth replicating for read receipts, reactions, retention, device approval).
- **Blocker before production:** No.

## L-15. Owner-setup enrollment reservations allow unbounded row creation pre-setup

- **Severity:** Low
- **Location:** `server/internal/storage/enrollment_store.go` (`ReserveOwnerEnrollment`), rate-limited at 240 req/min general (not the 10/min auth class — `isAuthEndpoint` covers `/api/v1/setup/owner` but **not** `/api/v1/setup/owner/enrollment` or `/api/v1/register/enrollment` or `/api/v1/device-links/claim-enrollment`)
- **Problem:** The enrollment-reservation endpoints are the cheap-write half of the auth flows but aren't classified as auth endpoints, so an attacker gets 240 reservation inserts/min/IP (each with a 10-minute lifetime; pruning runs 6-hourly). Registration reservations additionally require a valid invite code, but device-link reservation only needs a guessable-in-principle link code, and owner reservation (pre-setup) needs loopback/token.
- **Recommended fix:** Add the three `*/enrollment` paths to `isAuthEndpoint`.
- **Blocker before production:** No.

## L-16. `Publish` fan-out happens before slow-path failures are visible; duplicate-send returns stale recipients semantics — verified correct

*(Recorded to show it was checked: the messaging service intentionally suppresses fan-out on idempotent duplicates and returns an error when recipient listing fails after commit, relying on sync catch-up. `Hub.Drain`/`Unregister` accounting was also checked for double-decrement — `Unregister` after `Drain` correctly no-ops because the map entry is gone.)*

- **Severity:** None (informational)

## Dead code / cleanup

| Item | Location | Note |
|---|---|---|
| `webrtc.SignalingService` interface | `server/internal/webrtc/webrtc.go` | Referenced nowhere; keep only if the LiveKit work will use it, otherwise delete |
| `Store.DeleteAccount` wrapper | `storage/account_store.go:80` | Unused (handlers call `DeleteAccountData`) |
| `Store.PruneExpiredMessages` | `message_store.go:379` | Unused wrapper over `PruneExpiredContent` |
| `Store.CreateChannel` | `community_store.go` | Handlers use `CreateChannelWithConversation`; the plain variant creates channels without conversations/memberships — a footgun if ever wired |
| `messageByIdempotency` / `pruneExpiredMessageByIdempotency` | `message_store.go:191,372` | Unused (logic inlined in `saveMessageEnvelope`) |
| `effectiveConversationRole` | `httpapi/api.go:153` | Thin unused wrapper |
| `ApiClient.createConversation` | `mobile/lib/core/api_client.dart:186` | Superseded by `createConversationDetailed` |

---

## Production Blockers

Must be fixed before launch (excluding the documented crypto blocker #0):

0. **[Documented] Mobile MLS integration** — messaging is fail-closed end-to-end (`UnavailableCryptoService`); every send throws. Tracked in `REMAINING-WORK.md`.
1. **L-1** — `conversation_members` table does not exist; key-package claim endpoint always 500s.
2. **L-2** — WebSocket per-IP cap counts the reverse proxy; realtime hard-capped at 20 devices per instance in the recommended deployment.
3. **L-3** — unsynchronized read-modify-write on the mobile persistent record (data loss under normal concurrency).
4. **L-4** — DMs can be silently expanded to groups.
5. **L-5** — backup/attachment downloads killed at 30 s (recovery path broken on slow links).
6. **L-12** — no leave/kick/member-list; required for abuse handling and MLS-removal design.
7. **L-13** — members have no password recovery path.
8. **S-1** (see `security-issues.md`) — tokenless owner setup is spoofable in the systemd + host-proxy topology.

Recommended fix order: L-1 → S-1 → L-2 → L-4 → L-5 → L-3 → L-12 → L-13, then the Medium items above.
