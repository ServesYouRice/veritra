# Performance and Reliability Issues

**Audit date:** 2026-07-21  
**Target:** The documented single-node, small-instance deployment—not hyperscale.

## Findings

### PERF-01 — Every local state change rewrites one potentially huge JSON value

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `mobile/lib/storage/local_store.dart:146-354` |
| Blocker before production | **Yes**, paired with data-integrity risk |

**Description:** Cursor updates, outbox changes, session changes, and cache updates decode and re-encode the entire secure-storage record. Its bounds still permit thousands of base64 ciphertext envelopes and large sealed crypto state.

**Why it matters:** Work and allocation scale with total cache size, causing UI stalls, excessive platform-channel/keychain work, write failures, and battery/storage overhead.

**Recommended fix:** Move bulk data to an encrypted indexed database with row-level transactions; retain only small keys/credentials in platform secure storage. Batch cursor/snapshot writes and benchmark realistic ciphertext sizes.

**Risks/dependencies:** Same redesign as `LOG-03`; must preserve atomic crypto-state/cursor commits.

### PERF-02 — One sync event can trigger broad list and cache rewrites

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `mobile/lib/core/app_state.dart:930-1002`; `background_push.dart` |
| Blocker before production | No, but fix before scale testing |

**Description:** Any conversation-scoped event marks the full conversation list for refresh. A selected-conversation event also reloads its newest message page and rewrites the entire bounded local snapshot. Background push similarly refreshes all conversations.

**Why it matters:** Active chats create disproportionate API, SQLite, JSON, platform-channel, bandwidth, and battery work.

**Recommended fix:** Apply typed event deltas where safe, fetch only referenced resources, coalesce bursts, debounce list refreshes, and persist only changed rows. Retain a bounded full-resync path for cursor expiry.

**Risks/dependencies:** Requires a reliable event payload/single-message contract and transactional local database.

### PERF-03 — Conversation listing performs correlated work per row

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `server/internal/storage/community_store.go:865-956` |
| Blocker before production | No |

**Description:** The list query calculates unread counts with correlated message/receipt subqueries, performs cursor timestamp lookup, and applies per-row blocked-sender logic while ordering by latest activity.

**Why it matters:** As messages and conversations grow, opening/refreshing the main screen can become the hottest and most contention-prone SQLite query.

**Recommended fix:** Capture `EXPLAIN QUERY PLAN` for realistic data, add/select supporting indexes, and consider transactionally maintained per-membership summary fields (`last_message_at`, unread watermark/count) only after measurement.

**Risks/dependencies:** Denormalized counters must remain correct under retries, deletion, retention, block changes, and receipts.

### PERF-04 — Realtime registration scans every connected client

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `server/internal/realtime/hub.go:41-71` |
| Blocker before production | No |

**Description:** Each new socket iterates all subscribers to calculate account, device, and IP counts while holding the hub write lock.

**Why it matters:** Reconnect storms become O(total connections × reconnects), delaying registration, publish snapshots, and disconnect operations.

**Recommended fix:** Maintain exact counters keyed by account/device/IP, update them atomically during register/unregister/drain, and assert invariants in race tests.

**Risks/dependencies:** Incorrect decrement paths could bypass limits or deny valid users; central client-IP resolution must be fixed first.

### PERF-05 — Push targets are delivered serially per message

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `server/internal/httpapi/content_handlers.go:248-266`; push provider deadlines |
| Blocker before production | No |

**Description:** `deliverPush` loops targets sequentially. A message can target hundreds of subscriptions, and each network request has bounded but nontrivial latency. The provider semaphore helps across goroutines but not within one fan-out.

**Why it matters:** Push wakeups can arrive minutes late and message bursts create many long-lived goroutines.

**Recommended fix:** Use a bounded worker pool/queue with per-target deadlines, terminal-error disablement, aggregate metrics, and graceful shutdown/drain behavior.

**Risks/dependencies:** Never persist or log endpoint secrets. Push remains best-effort and must not delay message acknowledgement.

### PERF-06 — Sync catch-up repeats JSON extraction and visibility work

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `server/internal/storage/message_store.go:523-614`; `SyncBounds` and `ListSyncEvents` |
| Blocker before production | No |

**Description:** Visibility/block filtering derives sender identity using `json_extract` and correlated message lookup over the sync log. Cursor-expiry handling runs bounds work separately, repeating similar joins.

**Why it matters:** Catch-up latency grows with event volume precisely during reconnect storms or after downtime.

**Recommended fix:** Store privacy-reviewed structured routing fields (such as actor/sender account ID) in indexed columns when events are inserted, reuse one visibility predicate, and benchmark retained-log windows.

**Risks/dependencies:** Do not add message content or excessive metadata; migrations must backfill safely.

### PERF-07 — Upload quota checks aggregate full tables

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | attachment and backup quota methods in `server/internal/storage/content_store.go` |
| Blocker before production | No |

**Description:** Quota admission calculates current usage with aggregate sums for each upload instead of maintained counters or reservation accounting.

**Why it matters:** Concurrent uploads and growing blob tables increase write-path latency and can contend on SQLite. Check-then-insert logic also deserves concurrent quota testing.

**Recommended fix:** First add covering indexes and measure. If needed, introduce transactionally updated per-account/instance usage rows and upload reservations reconciled with committed blob metadata.

**Risks/dependencies:** Counter drift can either exceed disk capacity or deny valid uploads; provide a repair/recompute command.

### PERF-08 — Blob downloads lack Range/resume and suitable deadlines

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `server/internal/httpapi/content_handlers.go:166-209`; `server/internal/app/app.go:151-173` |
| Blocker before production | **Yes** for dependable backups |

**Description:** Downloads use plain `io.Copy`, no `Range` support, and the item routes retain a 30-second write deadline.

**Why it matters:** Interrupted or slow 50–100 MiB downloads restart from zero or fail outright, wasting bandwidth and making recovery unreliable.

**Recommended fix:** Add authorized single-range serving with `Accept-Ranges`, `Content-Length`, checksum verification metadata, streaming timeouts, and Caddy/throttled-network tests.

**Risks/dependencies:** Prevent path traversal, multi-range amplification, and unauthorized metadata disclosure.

### PERF-09 — Capacity limits are undocumented by evidence

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | server CI/tests; SQLite/realtime/push/upload configuration; deployment docs |
| Blocker before production | No, if launch capacity is tightly limited |

**Description:** The code defines connection and page limits but contains no reproducible load profile, soak test, database-size fixture, latency target, or capacity recommendation for the 1 GiB Compose limit.

**Why it matters:** Operators cannot size an instance or set alerts before real users discover bottlenecks.

**Recommended fix:** Establish a privacy-safe benchmark profile covering concurrent sockets, message bursts, catch-up after downtime, upload/download, retention pruning, and backup. Publish supported ranges and p95/p99 targets.

**Risks/dependencies:** Use synthetic ciphertext/metadata only; never collect production telemetry or message content.

