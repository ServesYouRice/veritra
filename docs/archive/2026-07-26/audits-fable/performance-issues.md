# Performance Issues

Target scale (per ADRs): single-node, SQLite-first, small/medium self-hosted communities. Findings are judged against that target, not hyperscale.

---

## P-1. Conversation list query does correlated per-row unread counting

- **Severity:** Medium
- **Location:** `server/internal/storage/community_store.go` — `ListConversationsPage` CTE: `COALESCE((SELECT COUNT(*) FROM message_envelopes me WHERE me.conversation_id = c.id AND ... me.created_at > (SELECT created_at FROM message_envelopes WHERE id = rr.message_id)), 0)`
- **Problem:** For every conversation row, the query counts unread messages with a correlated subquery that itself contains a nested per-message `SELECT created_at`, plus a `NOT EXISTS` block probe per candidate message. With a busy channel (say 100k envelopes) and a user whose read cursor is old, a single conversation-list call scans large index ranges repeatedly — and the mobile client calls `conversations()` (all pages!) after **every** sync event burst (`_catchUpSyncEvents` → `_refreshConversations`).
- **Why it matters:** This is the hottest query in the app (home screen + every catch-up), and it degrades with message volume, not user count — a single active community makes the whole client feel slow.
- **Recommended fix:** Materialize the read-cursor timestamp once per conversation (join `read_receipts` to `message_envelopes` for `read_at_created`), or maintain an `unread_count`/`last_message_at` denormalization updated in the message-insert transaction. Add an index shaped like `(conversation_id, created_at)` filtered on `deleted_at IS NULL` if not already present (`0004`/`0005` migrations cover expiry/prefix but verify this shape with `EXPLAIN QUERY PLAN`).
- **Blocker before production:** No, but instrument it (the `/metrics` route histogram will show it) and fix before communities grow.

## P-2. Mobile catch-up refetches the world on every event

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart:912-1004` (`_catchUpSyncEvents`), `api_client.dart:114-134` (`conversations()` loops all pages)
- **Problem:** Any sync event with a `conversation_id` triggers a full conversation-list refetch (all pages, sequentially) and — if it's the selected conversation — a full newest-page message refetch, then a full snapshot rewrite to secure storage. One incoming message in a 300-conversation account = 3 paged list calls + 1 message page + a multi-hundred-KB secure-storage write. Events content is otherwise ignored (the WS payload is discarded and used only as a "poke").
- **Why it matters:** Battery, data, server load (multiplies P-1), and secure-storage churn (see P-6). The poke-then-refetch design is robust and fine to keep — but the refetch granularity is too coarse.
- **Recommended fix:** Apply sync events incrementally where cheap (the event already carries `conversation_id` and type): bump only that conversation's unread/last-activity locally, fetch only messages after the local newest (`after=` cursor exists server-side), and debounce snapshot persistence (e.g., ≥2 s coalescing window).
- **Blocker before production:** No.

## P-3. `Hub.Register` is O(total connections) per registration

- **Severity:** Low
- **Location:** `server/internal/realtime/hub.go:50-81`
- **Problem:** Each registration iterates every client of every account to compute per-account/per-device/per-IP counts under the write lock. At the 10k connection cap a reconnect storm (server restart → all clients reconnect with 1 s backoff) does 10k × avg-N scans while holding the hub mutex, also blocking `Publish`.
- **Recommended fix:** Maintain three counter maps (account, account+device, IP) updated on register/unregister; O(1) per registration.
- **Blocker before production:** No (matters only near the cap).

## P-4. Push delivery is a sequential loop per message with a 30 s budget

- **Severity:** Low–Medium
- **Location:** `server/internal/httpapi/content_handlers.go:240-275` (`notifyPush`/`deliverPush`), provider semaphore in `push/push.go` (32 slots)
- **Problem:** One goroutine per message iterates up to 500 targets sequentially; each Web Push POST can take up to 10 s (client timeout). A large channel with slow push endpoints exhausts the 30 s context after ~3 slow targets and silently drops the rest (only a warn log with a count). Meanwhile every new message spawns a new goroutine — unbounded concurrency across messages, bounded only by the provider's 32-slot semaphore, so goroutines pile up waiting for slots under burst.
- **Recommended fix:** Fan out within `deliverPush` using a small worker pool (reuse the 32-slot budget), and consider a single background delivery queue instead of per-message goroutines so bursts coalesce.
- **Blocker before production:** No.

## P-5. Sync-event visibility query re-derives blocked-sender logic with JSON extraction per row

- **Severity:** Low
- **Location:** `server/internal/storage/message_store.go:535-613` (`ListSyncEvents`, `SyncBounds` — `json_extract(se.payload_json, '$.message_id')` inside a `NOT EXISTS` per event, plus a nested envelope lookup)
- **Problem:** Every `/sync/events` page (called in a loop by every client on every poke) runs JSON extraction and per-row subqueries over the event window; `SyncBounds` additionally computes MIN/MAX over the same UNION **and is executed twice per request** (once inside `ListSyncEvents`, once again by the handler for the response envelope — `call_sync_handlers.go:112-135`).
- **Recommended fix:** Return bounds from the same call (single computation); consider storing `subject_account_id` as a real column on `sync_events` at write time so block filtering is an indexed join instead of JSON extraction.
- **Blocker before production:** No.

## P-6. Entire mobile cache lives in one secure-storage value

- **Severity:** Medium
- **Location:** `mobile/lib/storage/local_store.dart` (`SecureLocalStore`, single key `veritra.account_state.v2`; bounds: 20 conversations × 200 envelopes + 100 outbox entries)
- **Problem:** Every save serializes session + snapshot + outbox + crypto state to one JSON string and hands it to Keychain/EncryptedSharedPreferences. Envelope ciphertexts can be up to ~1 MB each (server body cap), so the theoretical record is enormous; even at realistic sizes (a few KB per message) this is hundreds of KB rewritten on every message event (see P-2). iOS Keychain and Android keystore-backed prefs are designed for small secrets — large values mean slow synchronous platform-channel writes and platform-specific size failure modes; the code treats any read failure as "delete everything" (`_readRecord` catch → delete), so hitting a limit nukes the outbox and cursor.
- **Recommended fix:** Keep only session + crypto state in secure storage; move snapshot/outbox to an encrypted local DB (SQLCipher/sqflite with a key held in secure storage). This also gives the transactionality that fixes logical L-3.
- **Blocker before production:** Yes in combination with L-3 (same refactor resolves both).

## P-7. Blob quota check sums the whole instance per upload

- **Severity:** Low
- **Location:** `server/internal/storage/content_store.go` (`enforceBlobQuota` — `SUM(size_bytes)` over a UNION of both tables, twice per upload, inside the write transaction)
- **Problem:** Full-table aggregate on every attachment/backup upload while holding the writer connection. Fine at thousands of rows; a running-total row (or per-account materialized usage) removes the scan and shortens writer occupancy.
- **Blocker before production:** No.

## P-8. No HTTP Range support on blob downloads

- **Severity:** Low–Medium
- **Location:** `content_handlers.go:194-209` (`serveEncryptedBlob` — plain `io.Copy`)
- **Problem:** Interrupted downloads restart from zero (compounds logical L-5's 30 s deadline). `http.ServeContent` with the on-disk file would give Range/If-None-Match for free (ETag already computed).
- **Blocker before production:** No, but do it together with L-5.

## P-9. Verified non-issues

- SQLite router (1 writer / 4–16 readers, WAL, busy_timeout 5 s) is a sound shape for the target scale; writes are short transactions.
- Retention/prune sweeps are paginated (LIMIT 500) with inter-batch sleep — no long table locks.
- Rate-limiter map is bounded (65,536 entries) with minutely cleanup; salted-hash keys avoid storing raw IPs.
- Metrics use atomics + `sync.Map` keyed by bounded route patterns; no per-request allocation hot spots of note.
- `readLimitedJSON` caps bodies at 1 MB before parsing; the plaintext-key scan double-parses JSON but on ≤1 MB bodies this is acceptable.
- Message list pagination is cursor-based (created_at, id) — no OFFSET scans.

---

**Priority order:** P-6 (with L-3) → P-1 → P-2 → P-4 → P-5 → P-8 → P-3/P-7.
