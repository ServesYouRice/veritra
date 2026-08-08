# Plan 07 — Measure before optimizing

Do not introduce PostgreSQL, Redis, NATS, object storage, or denormalized
counters from audit speculation. Capture reproducible measurements first and
keep privacy-safe raw data local.

## P01 — Define a synthetic performance baseline

Audit references: PERF-01 through PERF-09.

Objective:
Create repeatable, content-free workloads and publish supported instance
targets.

Steps:

1. Define small, medium, and stress datasets using random ciphertext bytes and
   synthetic identifiers only.
2. Cover login, conversation list, unread counts, sync, send, realtime fanout,
   upload/download, push enqueue, and backup.
3. Record latency percentiles, throughput, database busy time, memory, CPU,
   file descriptors, queue depth, and data-root growth.
4. Pin environment and command metadata beside each result.
5. Establish regression budgets only after the first stable runs.

Acceptance:

- The workload contains no real user data or readable message fixtures.
- Another operator can reproduce the baseline.
- Claimed capacity is tied to a documented machine and workload.

## P02 — Measure conversation and unread query plans

Audit references: PERF-01, PERF-02.

Depends on: P01.

Objective:
Determine whether list/unread correlated queries are an actual bottleneck.

Steps:

1. Capture EXPLAIN QUERY PLAN and timings at several membership/message sizes.
2. Record the existing messages(conversation_id, created_at) index; do not add
   the already-present index again.
3. Add a new index or query shape only when evidence shows a regression.
4. Compare write amplification and read latency before selecting a change.
5. Add a focused benchmark and result threshold for the chosen implementation.

Acceptance:

- The before/after plan and data sizes are recorded.
- Any schema change has a migration, rollback note, and write-cost evidence.

## P03 — Reduce redundant sync and local-store work

Audit references: PERF-03, PERF-07.

Depends on: Y08, C03.

Objective:
Use incremental cursors and indexed encrypted local tables instead of repeated
full-window scans and one-blob rewrites.

Steps:

1. Instrument request counts and local transaction duration without IDs or
   content.
2. Debounce/coalesce sync hints while preserving the highest durable cursor.
3. Query only changed rows and update them in one local transaction.
4. Bound cache eviction and retry behavior.
5. Benchmark reconnect storms and background/foreground overlap.

Acceptance:

- Repeated hints do not trigger redundant full syncs.
- Local write cost grows with changed rows, not the entire cache.
- Correctness tests still cover gaps, duplicates, and out-of-order hints.

## P04 — Make realtime caps constant-time

Audit reference: PERF-04.

Depends on: Y05, P01.

Objective:
Replace connection-map scans with correct O(1) aggregate counters if profiling
shows measurable hub lock contention.

Steps:

1. Profile hub lock wait under many accounts and connections.
2. If justified, maintain total, per-account, and per-client-identity counters
   under the same lock as connection membership.
3. Assert counters on every register, reject, unregister, and shutdown path.
4. Add race tests and churn benchmarks.

Acceptance:

- Counters never diverge from connection membership in tests.
- The change has measured lock-time benefit; otherwise close the card with
  evidence and no production edit.

## P05 — Bound push delivery work

Audit reference: PERF-05.

Objective:
Prevent slow push providers from creating unbounded goroutines or memory use.

Steps:

1. Measure current fanout concurrency and failure behavior.
2. Add a bounded queue and fixed workers with context cancellation.
3. Define overflow, retry, backoff, and shutdown semantics.
4. Preserve generic payloads without sender names or message text.
5. Test slow, failed, wedged, and recovering providers.

Acceptance:

- Concurrency and queue memory have explicit limits.
- Provider failure cannot block message durability.
- Push payload privacy tests remain green.

## P06 — Evaluate structured sync routing columns

Audit reference: PERF-06.

Depends on: P01.

Objective:
Avoid repeated JSON extraction only if it is costly and the metadata exposure
is acceptable.

Steps:

1. Benchmark current sync filtering and JSON extraction at target history
   sizes.
2. List candidate routing columns and review each against the threat model.
3. Prefer minimal opaque IDs already visible to the server.
4. Add columns/indexes only with a migration, backfill, compatibility test, and
   recorded benefit.

Acceptance:

- No plaintext message data is promoted into server-visible columns.
- Any new metadata is justified in the threat model and privacy documentation.

## P07 — Evaluate quota accounting

Audit reference: PERF-08.

Depends on: P01.

Objective:
Replace repeated aggregate scans only if quota checks become material.

Steps:

1. Measure quota query plans and latency at target blob counts.
2. If needed, compare cached counters, periodic aggregation, and current SQL.
3. Design crash-safe reconciliation before using stored counters for rejects.
4. Test upload/delete/restore races and repair after injected failures.

Acceptance:

- Quota enforcement cannot undercount after a crash.
- A more complex counter design ships only with measured benefit.

## P08 — Publish load and soak evidence

Audit references: TEST-10, PERF-09.

Depends on: P01, D05.

Objective:
Find resource leaks and turn the baseline into an honest capacity statement.

Steps:

1. Run burst, sustained, reconnect-storm, slow-client, large-blob, and backup
   overlap scenarios.
2. Include WebSocket churn, push failure, SQLite contention, and graceful
   shutdown.
3. Run a long soak and record resource trends plus recovery after load stops.
4. Publish limits and bottlenecks; do not generalize beyond the measured host.

Acceptance:

- Results include commands, versions, workload, host, and raw aggregate data.
- No steadily growing goroutine, connection, file, queue, or memory count is
  left unexplained.
