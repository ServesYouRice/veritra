# Performance & Scalability Issues — Veritra Audit (audits-fable)

The server is SQLite-on-a-single-binary by design, so "scale" here means "vertical, single-node, tens-to-low-thousands of users," which is the stated target. Findings are about avoiding cliffs within that envelope and removing needless work.

> **Historical snapshot:** findings and severities describe `c939f26`, not the
> current tree. Use [`../audits-codex/README.md`](../audits-codex/README.md) for
> current release status.

**Severity scale:** Critical / High / Medium / Low / Nice-to-have.

---

## Summary table

| ID | Title | Severity | Blocker |
|---|---|---|---|
| PERF-1 | Fan-out repeats a member query and holds the hub read lock while delivering | Medium | No |
| PERF-2 | Every message mutation issues 3–4 separate DB round-trips (member list, save event, publish) | Medium | No |
| PERF-3 | `ListSyncEvents` UNION+JOIN scans grow with membership; catch-up called on every event | Medium | No |
| PERF-4 | Mobile catch-up refetches entire conversation list + full message page on any event | Medium | No |
| PERF-5 | No client-side message persistence: every conversation open is a network round-trip | Medium | No |
| PERF-6 | Reader-pool benefit is workload-dependent and unmeasured | Low | No |
| PERF-7 | `SaveSyncEvent`/audit writes are synchronous on the request path | Low | No |
| PERF-8 | Retention/prune sweeps do full-table deletes without batching | Low | No |
| PERF-9 | Metrics counters and scrape share one mutex | Low | No |
| PERF-10 | Rate-limiter bucket map hashing on every request | Low | No |

---

## PERF-1 — Hub fan-out repeats member lookups and holds a delivery lock

- **Severity:** Medium
- **Location:** `server/internal/realtime/hub.go:84-99` (`Publish` marshals before `RLock`, then iterates under the lock), callers in `server/internal/httpapi/api.go` each precede it with `conversationMemberIDs` (`:856-863`) → `ListConversationMemberIDs` (`storage/sqlite.go:971-986`)
- **Description:** Each message send/edit/delete/reaction/read/typing performs one `SELECT account_id FROM memberships` to build the recipient list, then walks `subscribers[accountID]` under the hub's `RLock`. The original title's “N+1” and “lock-held marshal” wording was wrong: there is one repeated member query per event, and `json.Marshal` already occurs before the lock. The remaining concern is the extra query and lock-held fan-out iteration.
- **Why it matters:** At low volume it is invisible; under a busy group it adds a DB round-trip and makes register/unregister writers wait for fan-out iteration on every event.
- **Recommended fix:** Measure first. If this becomes hot, cache conversation member lists with correct invalidation or subscribe sockets by conversation; copy target clients under the lock and perform channel sends after releasing it.
- **Blocker:** No.

## PERF-2 — Message write path is several sequential round-trips

- **Severity:** Medium
- **Location:** `server/internal/httpapi/api.go:688-743` (`createMessageEnvelope`): `SaveMessageEnvelope` → `SaveSyncEvent` → `ListConversationMemberIDs` → `Hub.Publish`
- **Description:** A single send performs (inside `SaveMessageEnvelope`) a prune + idempotency select + membership check + insert (LOG-6), then a sync-event insert, then a member-list select, then publish. That's ~6 DB statements per message on the single writer connection.
- **Why it matters:** All writes funnel through one SQLite writer connection (`SetMaxOpenConns(1)`). Reducing statements should improve the write ceiling, but the original “halving statements roughly doubles throughput” claim was not benchmarked and should not be treated as a measured result.
- **Recommended fix:** Fold the envelope insert + sync-event insert into one transaction for durability and fewer round-trips. Fetch or return the member list once for publish; the original insert path knew only whether the sender was a member, not the complete list.
- **Blocker:** No.

## PERF-3 — Sync catch-up query cost scales with membership

- **Severity:** Medium
- **Location:** `server/internal/storage/sqlite.go:1312-1343` (`ListSyncEvents`: `UNION ALL` of account-scoped rows and a `memberships`-JOIN of conversation-scoped rows)
- **Description:** Every realtime event triggers the client to call `/sync/events` (LOG-7 / mobile `_catchUpSyncEvents`). That endpoint runs a UNION with a JOIN across `memberships` for the caller. Indices exist (`idx_sync_events_account`, `idx_sync_events_conversation`, `idx_memberships_account_conversation`), but the conversation-scoped side must join the member's conversations against the event stream on every poll. With many conversations and a busy instance, this is the most frequently executed read.
- **Why it matters:** Read frequency is high (once per delivered event per connected client), and the reconnect churn from LOG-2 multiplies it further. This query's cost sets the read ceiling.
- **Recommended fix:** Fix LOG-2 (stops needless reconnect-driven catch-ups) and LOG-7 (coalesce). Consider delivering event bodies over the socket so the client only calls `/sync/events` on reconnect/gap, not on every event. Add a covering index if EXPLAIN shows a scan.
- **Blocker:** No.

## PERF-4 — Mobile over-refetches on every sync event

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart:547-597` (`_catchUpSyncEvents`)
- **Description:** For any event touching a conversation, the client sets `refreshConversationsNeeded = true` and re-fetches the **entire** conversation list; if it touches the selected conversation, it re-fetches the **entire** first message page (50). A single incoming message thus triggers two full list GETs, discarding and rebuilding state, and losing scroll position / any paginated history (LOG-15).
- **Why it matters:** Bandwidth and jank scale with conversation count, not with the delta. On a large account, each received message re-downloads everything.
- **Recommended fix:** Apply deltas from event payloads (the socket already carries full envelopes for `message.envelope.created`) instead of blanket refetches; only refetch the conversation list when a membership/creation event arrives.
- **Blocker:** No.

## PERF-5 — No local message cache

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart:38-39` (`messagesByConversation` is in-memory only), `mobile/lib/storage/local_store.dart` (persists session + sync cursor only)
- **Description:** Messages, conversations, devices, communities, and invites live only in RAM. Every cold start re-fetches from the network; opening any conversation is always a round-trip; offline shows nothing.
- **Why it matters:** A messenger is expected to open instantly to cached content and work offline for reading. This also makes PERF-4's over-refetch more painful (nothing to fall back on).
- **Recommended fix:** Persist decrypted messages locally (once LOG-0 lands) in an encrypted local DB (SQLite/Drift/Isar), keyed by the sync cursor, so cold start renders cache-first and syncs deltas.
- **Blocker:** No (design item; large).

## PERF-6 — Reader pool may not deliver its intended parallelism

- **Severity:** Low
- **Location:** `server/internal/storage/sqlite.go:93-117` (reader pool sized `NumCPU`, clamped 4–16)
- **Description:** The split writer/reader-pool design is sound and WAL permits concurrent readers. Code inspection alone does not establish whether 4–16 reader connections materially help this workload; the original claim that modernc reads “still serialize on the file” was too broad. This is a measurement question, not a defect.
- **Recommended fix:** Benchmark actual read concurrency before tuning the pool up; the current clamp is reasonable.
- **Blocker:** No.

## PERF-7 — Sync/audit event writes are synchronous on the request path

- **Severity:** Low
- **Location:** `server/internal/httpapi/api.go:848-869` (`saveSyncEvent`, `recordAuditEvent` awaited inline)
- **Description:** Each mutating request writes its sync event and (sometimes) audit event synchronously through the single writer before responding. These are on the critical path and compete with message inserts for the writer.
- **Recommended fix:** Sync events must stay durable-before-ack (clients rely on them), so keep those synchronous but batch within the message transaction (PERF-2). Audit events are metadata-only and could be buffered to an async writer.
- **Blocker:** No.

## PERF-8 — Prune sweeps are unbatched full-table deletes

- **Severity:** Low
- **Location:** `server/internal/storage/sqlite.go:1256-1282` (`PruneExpiredMessages`, `PruneSyncEvents`, `PruneAuditEvents`), invoked every 6 h
- **Description:** Each sweep is a single `DELETE … WHERE … <= cutoff`. On a large table this takes a long write lock, stalling all writes for the duration (single writer). At MVP scale it's fine; at scale it's a periodic latency spike.
- **Recommended fix:** Delete in bounded batches (`LIMIT` in a loop) with small pauses, so the writer lock is released between batches.
- **Blocker:** No.

## PERF-9 — Metrics scrape copies the class map under lock

- **Severity:** Low
- **Location:** `server/internal/app/app.go:199-223`
- **Description:** `record` locks a mutex on **every** request to bump counters; `handle` copies the map under lock. Fine for low sensitivity/low cardinality, but the per-request mutex is a (tiny) shared contention point on the hot path.
- **Recommended fix:** Use `sync/atomic` counters (fixed set of status classes) to drop the per-request lock entirely.
- **Blocker:** No.

## PERF-10 — Rate limiter hashes and locks on every request

- **Severity:** Low
- **Location:** `server/internal/app/app.go:331-363` (`middleware`: SHA-256 of salt+IP, then global mutex)
- **Description:** Each request computes a SHA-256 over the client IP and takes a single global mutex to touch the bucket map. SHA-256 per request is more than needed (the salt protects the map keys from being reversible, which is nice-to-have, not essential); the global mutex serializes all requests briefly.
- **Recommended fix:** Consider a cheaper keyed hash (e.g., maphash) and/or sharded buckets if profiling shows contention. Low priority at target scale.
- **Blocker:** No.

---

## Notes on scale ceiling

- **Single SQLite writer** is the throughput governor; every write finding above ultimately competes for it. The realistic ceiling is hundreds of writes/sec, which is ample for the stated "self-hosted, small community" target but rules out large public instances — consistent with ADR-0003.
- **WebSocket goroutines** are one-per-connection with a 32-slot buffer; memory scales linearly with concurrent connections. Combined with SEC-10 (no per-account cap), this is the main memory risk.
- **No horizontal scaling path** exists (in-memory Hub, local blob store, single DB file). That is an explicit design choice (ADR-0005 single-node); flagged here only so it's a known ceiling, not a surprise. See architecture recommendations in [nice-to-haves.md](nice-to-haves.md).
