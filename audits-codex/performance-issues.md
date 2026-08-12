# Performance and Capacity Audit

## Executive assessment

The current single-node SQLite architecture is a reasonable fit for a small self-hosted deployment, and the code includes useful foundations such as bounded HTTP bodies, WAL-oriented persistence, encrypted blob streaming, and bounded sync pages. The main risk is not the stack choice itself; it is that several hot paths perform work proportional to historical data, connected clients, or notification recipients without a measured capacity envelope.

No supported user, message, attachment, or concurrent-connection limits are currently backed by load evidence. Items marked as blockers are blockers before advertising production capacity, even if a very small private preview could operate below the triggering thresholds.

## Findings

### PERF-01 - Conversation-list reads repeatedly scan message history

- **Severity:** High
- **Location:** `server/internal/storage/community_store.go`, `ListConversationsPage`; message indexes in the SQLite schema
- **Description:** The conversation-list query combines a grouped latest-message computation, a correlated unread count, peer/member lookups, ordering, and pagination. The available message index is centered on `(conversation_id, created_at)`, but the query still performs substantial work over message history before applying the page limit. Mobile sync refreshes this list frequently.
- **Why it matters for production:** Inbox latency and database CPU will grow with retained message volume, not just with the number of visible conversations. On SQLite, a slow reader can also amplify contention with writes and cleanup work.
- **Recommended fix:** Capture `EXPLAIN QUERY PLAN` and benchmark representative datasets first. Consider transactionally maintained conversation summary/unread tables, a latest-message pointer, and indexes aligned with unread predicates. Refresh only affected conversations after sync events rather than reloading the entire first page.
- **Blocker before production:** Yes, before publishing a capacity claim beyond a small private deployment.
- **Related risks or dependencies:** Read-model consistency; LOG-07; PERF-08; migration strategy.

### PERF-02 - Push delivery creates unbounded per-message goroutines

- **Severity:** High
- **Location:** Server messaging service push fanout, `go ...deliverPush(...)`; push provider delivery loop
- **Description:** Each accepted message can start a new delivery goroutine. Within that job, targets are sent sequentially and may consume a long network timeout per endpoint. There is no durable queue, global worker bound, backpressure policy, or observable backlog.
- **Why it matters for production:** A burst of messages or a slow provider can create large numbers of goroutines, sockets, and retained request state. Process restart loses work, and provider latency can turn ordinary load into memory and connection pressure.
- **Recommended fix:** Persist privacy-minimized wake jobs after the message transaction, process them through a bounded worker pool with per-provider concurrency, deadlines, retry/backoff, deduplication, and a dead-letter/expiry policy. Export queue depth, age, attempts, and provider outcomes.
- **Blocker before production:** Yes if push is enabled.
- **Related risks or dependencies:** Push privacy model; LOG-07; notification observability; durable side-effect architecture.

### PERF-03 - Sync bursts can trigger one repair request per message event

- **Severity:** High
- **Location:** `mobile/lib/core/app_state.dart`, `_catchUpSyncEvents` and `_repairMessage`
- **Description:** Catch-up gathers message identifiers and repairs them through individual API calls. A page or reconnect burst can therefore turn up to hundreds of events into hundreds of sequential network round trips in addition to the sync request itself.
- **Why it matters for production:** Recovery time becomes dominated by latency, mobile radio use, and request overhead. Large gaps can keep the app stale for a long time and produce avoidable load spikes after an outage.
- **Recommended fix:** Include sufficient message metadata/ciphertext in authorized sync events, or add a bounded batch repair endpoint. Deduplicate IDs across pages, fetch in small concurrent batches, and persist progress so reconnects do not restart the same repair wave.
- **Blocker before production:** Yes for credible offline/reconnect behavior.
- **Related risks or dependencies:** Event privacy payload; API limits; LOG-01 and LOG-08.

### PERF-04 - Realtime connection registration is linear under a global lock

- **Severity:** Medium
- **Location:** Server realtime hub, `Register`
- **Description:** Registration scans existing connections while holding the hub lock to enforce connection limits/identity rules. With the existing 10,000-connection ceiling, reconnect storms can make registration work approach quadratic behavior across the storm.
- **Why it matters for production:** A server restart, network flap, or mobile reconnect wave can increase lock hold time and delay otherwise independent registration, broadcast, and cleanup operations.
- **Recommended fix:** Maintain indexed counts/sets by account and device, update them atomically on register/unregister, and keep the critical section constant-time. Load-test cold reconnect and mass disconnect scenarios.
- **Blocker before production:** No for a small single-instance target, but required before claiming high connection counts.
- **Related risks or dependencies:** Hub lifecycle correctness; supported-capacity definition.

### PERF-05 - Retention cleanup is both throughput-limited and poorly indexed

- **Severity:** High
- **Location:** Server retention sweeper and SQLite cleanup queries for messages, sync events, audit events, and blobs
- **Description:** Cleanup runs every six hours and each query deletes at most 500 rows per pass. That caps steady-state removal at roughly 2,000 rows/day per category, while normal activity can exceed that rate. Several cutoff scans do not have an index beginning with their timestamp predicate.
- **Why it matters for production:** Expired metadata and ciphertext can accumulate indefinitely, increasing storage, backup time, query cost, and privacy exposure despite the configured retention promise.
- **Recommended fix:** Delete in bounded repeated batches until no eligible rows remain or a time budget is exhausted. Run more frequently, add cutoff-aligned indexes after measuring write cost, expose backlog age/count, and test sustained ingest above the expected peak.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** LOG-05; privacy/retention commitments; vacuum/checkpoint strategy; backup duration.

### PERF-06 - Attachment download reads each blob twice

- **Severity:** Medium
- **Location:** Server blob open/download path and HTTP content serving
- **Description:** Blob access hashes the full encrypted file to verify integrity, then `ServeContent` reads it again to send the response. For the configured maximum attachment size this doubles disk I/O and delays first byte.
- **Why it matters for production:** Concurrent large downloads can saturate disk throughput and increase request duration on modest self-hosting hardware.
- **Recommended fix:** Decide and document the integrity boundary. If verification on every read is required, stream verification and response in one pass where range semantics allow, or cache verified immutable content state safely. Benchmark full and range downloads before changing behavior; do not weaken integrity silently.
- **Blocker before production:** No.
- **Related risks or dependencies:** Range requests; encrypted-blob immutability; corruption detection and recovery policy.

### PERF-07 - Attachment quota checks aggregate all stored data on every upload

- **Severity:** Medium
- **Location:** Server blob quota/accounting query
- **Description:** Each upload admission computes aggregate storage with `SUM`/union-style reads across stored blob records rather than consulting transactionally maintained counters.
- **Why it matters for production:** Upload admission becomes slower as stored object count grows and can increase database contention around a user-visible operation.
- **Recommended fix:** Benchmark the current query, then maintain scoped usage counters transactionally with upload finalization and deletion. Add reconciliation tooling so counters can be repaired from source records.
- **Blocker before production:** No for small deployments.
- **Related risks or dependencies:** Orphan cleanup; quota consistency; backup/restore reconciliation.

### PERF-08 - Mobile catch-up rewrites broad snapshots after incremental events

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart`; `mobile/lib/storage/local_store.dart`, snapshot persistence
- **Description:** Catch-up applies incremental events but then persists broad conversation/message snapshots, including bounded collections per conversation. This creates repeated JSON encoding and encrypted SQLite writes even when only a small subset changed.
- **Why it matters for production:** Frequent sync events can increase battery use, flash writes, database contention, and UI notification churn on mobile devices.
- **Recommended fix:** Move toward normalized incremental upserts keyed by event identity and affected conversation, while keeping cursor advancement in the same transaction. Measure write volume and catch-up duration on low-end devices before and after.
- **Blocker before production:** No, but the atomicity redesign needed for LOG-01 should address it.
- **Related risks or dependencies:** Sync transaction design; database migration; PERF-03.

### PERF-09 - Global state notifications can rebuild the entire application tree

- **Severity:** Medium
- **Location:** `mobile/lib/main.dart`/root `MaterialApp` `AnimatedBuilder`; feature screens with additional `AnimatedBuilder` listeners; `AppState`
- **Description:** The root application listens to the monolithic `AppState`, while many child screens also listen directly. A broad `notifyListeners()` can rebuild routing/theme scaffolding and screen subtrees for changes unrelated to the visible feature.
- **Why it matters for production:** Sync bursts, connection updates, upload progress, or typing state can cause avoidable build work and jank, especially as the app grows.
- **Recommended fix:** Profile before refactoring. Split state by domain and expose narrow selectors/listenables so only dependent widgets rebuild. Keep navigation/session state separate from high-frequency message, transfer, and presence updates.
- **Blocker before production:** No unless profiling shows missed frame budgets on supported devices.
- **Related risks or dependencies:** ARCH-02; state lifecycle fixes in LOG-03 and LOG-04.

### PERF-10 - There is no measured production capacity envelope

- **Severity:** Medium
- **Location:** Project-wide operations, benchmarks, and documentation
- **Description:** The repository does not define tested limits for accounts, devices, concurrent sockets, conversations, messages/day, retained events, attachment throughput, database size, or recovery time. Basic metrics exist but omit key queue/backlog and database indicators.
- **Why it matters for production:** Operators cannot size a host, recognize saturation, or know when the single-node design is outside its safe operating range.
- **Recommended fix:** Define target deployment tiers and run reproducible load/soak tests against each. Publish p50/p95/p99 latency, error rate, resource use, database growth, reconnect recovery, push backlog, cleanup throughput, backup duration, and restore duration. Turn tested limits into alerts and documentation.
- **Blocker before production:** Yes before making any scale or reliability claim; not necessarily for a tightly scoped private alpha.
- **Related risks or dependencies:** TEST-07; observability; hardware profiles; retention configuration.

## Recommended performance work order

1. Correct and load-test retention throughput (PERF-05).
2. Replace fire-and-forget push fanout with bounded durable work (PERF-02).
3. Eliminate per-event repair request amplification (PERF-03).
4. Benchmark and redesign the conversation read model if the query exceeds the target budget (PERF-01).
5. Define the supported capacity envelope and associated alerts (PERF-10).
6. Optimize mobile persistence/rebuilds and secondary storage paths using profiler evidence (PERF-06 through PERF-09).
