# T49A/T49B server benchmark baseline

Measurement only (card I49). No production code changed. Benchmarks live in
`*_bench_test.go` under `server/internal/{storage,realtime,uploads,httpapi}`.
All data is synthetic random ciphertext from a fixed seed.

- **Host:** 4 vCPU Intel Xeon @ 2.80GHz, 15 GiB RAM, Linux 6.18 amd64
- **Toolchain:** go1.26.8 (before the 1.26.10 bump; no storage-path change)
- **Storage:** SQLite WAL, one writer connection, local blobs
- **Command:** `cd server && go test -run '^$' -bench . -benchmem -benchtime 1s ./internal/storage ./internal/realtime ./internal/uploads ./internal/httpapi` (about 3 minutes)

## Datasets

- **small:** 50 accounts, 100 conversations (25% DMs, groups of 5), measured
  account in 50; 10k messages of 256 B; about 10.2k sync events; 1k
  attachments; 50 backups.
- **large:** 500 accounts, 1,000 conversations, measured account in 200;
  100k messages; about 102k sync events; 10k attachments; 500 backups.
- **quota:** 1k/10k/100k attachments of 64 KiB plus 50/500 backups.
- **realtime hub:** 0/1k/5k/9k live sockets, one account each.

## Results

| Benchmark | Dataset | ns/op | B/op | allocs/op |
|---|---|---|---|---|
| ListConversationsPage(100) | small / large | 28.2M / **354.6M** | 71k / 140k | 1308 / 2557 |
| ListMessages latest 100 | small / large | 1.43M / 1.81M | 227k | 3376 |
| ListMessages before mid 100 | small / large | 0.97M / 1.39M | 115k | 1754 |
| SyncBounds | small / large | 89.2M / **929M** | 1200 | 39 |
| ListSyncEvents from 0, 100 | small / large | 73.8M / **714M** | 194k | 1578 |
| ListSyncEvents from mid, 100 | small / large | 97.7M / **1.23G** | 86k | 1780 |
| MarkDeviceSeen, throttled no-op | small | 29.4k | 376 | 13 |
| MarkDeviceSeen, throttled, parallel | small | 52.5k | 519 | 15 |
| MarkDeviceSeen, real write | small | 628k | 376 | 13 |
| Send message with parallel seen writes | small | 1.71M | 10.8k | 230 |
| SaveMessageEnvelopeWithSyncEvent | small / large | 1.44M / 1.36M | 10.4k | 211 |
| Hub Register+Unregister | 0 / 1k / 5k / 9k sockets | 1.7k / 98k / 676k / **1.64M** | 1296 | 5 |
| Hub Register, parallel | 9k sockets | 1.57M | 996 | 3 |
| Hub Publish to 5 accounts | 1k / 9k sockets | 5.2k / 4.0k | 448 | 7 |
| Typing, steady active pairs | 1k / 5k / 10,001 / 20k | 206 / 220 / **158k** / **318k** | 16 | 1 |
| Typing burst of new pairs (per call) | 5k / 10k / 20k | 404 / 400 / **131.8k** | - | - |
| Typing, throttled | - | 124 | 16 | 1 |
| EnforceBlobQuota | 1k / 10k / 100k attachments | 0.54M / 4.4M / **87.9M** | 1.75k | 45 |
| CreateAttachmentEnvelope | 1k / 10k / 100k | 1.30M / 5.83M / **84.9M** | 2.6k | 71 |
| CreateAttachmentEnvelope, parallel | 1k / 10k / 100k | 1.28M / 4.94M / 86.3M | 2.8k | 74 |
| Blob deletion reconcile, 500-key batch | 500 x 4 KiB | 385M (770k per blob) | 239k | 6526 |
| ListDatabaseBlobReferences | 1k / 10k / 100k | 3.8M / 23.0M / 252M | 42 MB at 100k | 602k |
| PutEncryptedBlob | 64K / 1M / 16M / 50M | 3.0M / 10.7M / 102M / 296M | 34k | 22 |
| PutEncryptedBlob, parallel | 64K / 1M | 0.97M / 4.6M | 35k | 25 |
| Oversized upload (60 MiB body, 50 MiB cap) | - | 261M; reads cap+1 bytes, leaves no file | 34k | 20 |
| Open + full read | 1M / 16M / 50M / 100M | 4.1M / 64M / 188M / 400M | 34k | 11 |
| Open + 64 KiB range read | 1M / 16M / 50M / 100M | 4.1M / 63M / 214M / 370M | 34k | 12 |
| SHA-256 only (reference) | 1M / 100M | 3.7M / 397M | 33k | 9 |
| Disk use per blob | 1 B / 1 KiB / 4097 B / 64 KiB | 4096 / 4096 / 8192 / 65536 B | - | - |
| CleanupTemporaryFiles (flat dir scan) | 1k / 10k / 100k blobs | 1.1M / 14.9M / 179M | 20 MB at 100k | 200k |

## Measured misses (1-5 fixed 2026-10-23; 6 needs advisor approval)

1. **Sync bounds:** `SyncBounds` costs about 0.93 s at the large dataset and
   runs on every `ListSyncEvents` page (0.7-1.2 s per page). Suspected:
   MIN/MAX over the UNION with per-row block-check subqueries (not yet
   confirmed with EXPLAIN).
2. **Conversation list:** `ListConversationsPage` costs 355 ms at large; the
   last-message subquery groups over every message on the instance, and
   unread counts are per conversation.
3. **Quota SQL:** `enforceBlobQuota` sums all attachment and backup rows on
   the instance inside the single-writer transaction (88 ms at 100k).
4. **Realtime registration:** `Hub.Register` scans every live socket under
   the global lock (about 1.6 ms at 9k sockets).
5. **Typing state:** past 10,000 fresh entries `allowTyping` sweeps the whole
   map on every admitted call (about 200 ns to 160-320 us per call).
6. **Range verification:** `LocalStore.Open` hashes the whole blob before
   serving any range. Any change needs advisor approval and must keep
   integrity checks.

Observations, not cards: oversized uploads stream to the cap before
rejection and quota is checked after the blob is durable; the flat blob
directory makes the temp sweep linear; small blobs take a full 4 KiB block.

## After: misses 1-3 fixed (commit ce74280)

Same benchmarks and dataset sizes (small/large, quota 1k/10k/100k).
Measured on a different host than the baseline, so both columns below were
run on it: 4 vCPU Intel Xeon @ 2.10GHz, go1.26.10, Linux amd64.
Command: `cd server && go test -run '^$' -bench . -benchmem ./internal/storage`.

| Benchmark | Dataset | Before ns/op | After ns/op |
|---|---|---|---|
| SyncBounds | small / large | 50.0M / 452M | 0.85M / **2.84M** |
| ListSyncEvents from 0, 100 | small / large | 48.9M / 486M | 2.0M / 4.1M |
| ListSyncEvents from mid, 100 | small / large | 66.7M / 718M | 25.1M / 252M |
| ListConversationsPage(100) | small / large | 18.0M / 198M | 3.5M / **7.9M** |
| EnforceBlobQuota | 1k / 10k / 100k | 0.35M / 2.5M / 38.8M | 22k / 25k / **22k** |
| CreateAttachmentEnvelope | 1k / 10k / 100k | 0.90M / 3.6M / 39.1M | 0.42M / 0.39M / 0.33M |
| CreateAttachmentEnvelope, parallel | 1k / 10k / 100k | 0.98M / 4.1M / 43.5M | 0.41M / 0.42M / 0.36M |

Other storage benchmarks are unchanged within noise.

**EXPLAIN QUERY PLAN (before):**

- SyncBounds: `SEARCH se USING INDEX idx_sync_events_account (account_id=?)`
  for `account_id IS NULL`, i.e. every conversation event on the instance,
  with the block subquery and a membership probe per row.
- ListConversationsPage: the last-message `GROUP BY` read every message;
  unread counts ran for every membership (`conversation_id=?` only, no
  receipt range); DM peer lookups did `SCAN m2` (no index led by
  `memberships.conversation_id`).
- Quota: `SCAN attachment_envelopes` and `SCAN backup_blobs`, twice.

**After:**

- SyncBounds: per membership, `SEARCH se USING INDEX
  idx_sync_events_conversation (conversation_id=?)` in id order, stopping at
  the first unblocked event from each end. The block predicate runs only on
  edge rows. `+account_id` keeps the planner off the account index.
- ListConversationsPage: per membership, a newest-first `SEARCH me USING
  INDEX idx_messages_conversation_created` with LIMIT 1 (materialized CTE).
  Unread counts and peers run only on the page; unread uses
  `(conversation_id=? AND created_at>?)`; peers use the new covering
  `idx_memberships_conversation_created`.
- Quota: two primary-key reads of `blob_usage_accounts` and
  `blob_usage_instance`.

**Migrations (additive):** `0030_read_model_indexes.sql` (memberships index);
`0031_blob_usage_counters.sql` (two counter tables, backfill, insert/delete/
update triggers on attachment and backup rows). Counters change in the same
transaction as the row, including FK cascades, and admission still reads
them inside the single-writer transaction, so the quota is exactly as
strict. A covering index alone would still scan every row for the
instance total.

**Equivalence:** `read_model_equivalence_test.go` keeps the original
queries and compares results on seeded data: blocks, deleted and expired
messages, blocked edge events, reaction/receipt/call events, another
device's Welcome, MLS join cursors, paging cursors, retention pruning and
account deletion. Counter tests cover every write path, cascades and the
upgrade backfill (`migration_history_test.go`).

**Still open:** ListSyncEvents from a cursor past most of the account's
conversations scans later instance events (252 ms at large). It is the
page query, not the bounds; a separate card if wanted.

## After: items 4-5 (realtime registration, typing state)

Same host class and benchmarks (`hub_bench_test.go`, `typing_bench_test.go`);
`go test -run '^$' -bench 'Hub|Typing' -benchmem -benchtime 1s -count 2
./internal/realtime ./internal/httpapi`. "Before" is a fresh re-run of the
old code on this host just before the change (so it differs slightly from the
table above). The host was shared and noisy; treat small (<2x) differences
as noise.

| Benchmark | Dataset | Before ns/op | After ns/op |
|---|---|---|---|
| Hub Register+Unregister | 0 / 1k / 5k / 9k sockets | 737 / 79k / 429k / **921k** | 1.0k / 1.8k / 1.1k / **0.9k** |
| Hub Register, parallel | 9k sockets | 996k | 0.88k |
| Hub Publish to 5 accounts | 1k / 9k sockets | 2.4k / 2.6k | 2.5k / 2.5k |
| Typing, steady active pairs | 1k / 5k / 10,001 / 20k | 114 / 121 / **117k** / **240k** | 197 / 224 / 252 / 257 |
| Typing burst of new pairs (per call) | 5k / 10k / 20k | 190 / 256 / **96.8k** | 194 / 208 / 282 |
| Typing, throttled | - | 92 | 97 |

- **Item 4:** `Hub` keeps a per-IP socket count next to the per-account set.
  Register reads the account and IP counts directly and counts devices only
  within the account (at most 10 sockets). Limits (10,000 total, 20 per IP,
  10 per account, 3 per device per account), rejection with
  `ErrConnectionLimit`, draining, and all removal paths (Unregister,
  DisconnectDevice, DisconnectAccountExceptDevice, DisconnectAccount, Drain)
  are unchanged; all removals share one index-cleanup helper under the hub
  lock. Register never replaced an older socket and still does not.
- **Item 5:** typing state moved to `typingLimiter`: two time generations,
  each at most one 2 s throttle interval wide; rotation drops the older one
  wholesale, so expiry is O(1) amortised. Every entry young enough to
  throttle survives rotation, so admit/throttle decisions match an unbounded
  per-pair map (randomised test against a reference). Hard bound: 50,000
  pairs across both generations; a new pair past it is refused (429, as for
  throttling) until the generation rotates. Steady state costs about 100 ns
  more than the old sub-cap path because entries move between generations.
- **Tests:** `server/internal/realtime/hub_test.go` (each limit, slot reuse,
  double unregister, every disconnect path, drain, concurrent churn with a
  brute-force index check) and `server/internal/httpapi/typing_limiter_test.go`
  (window, rotation boundary, reference equivalence, expiry, memory bound,
  concurrency); run with `-race`.

## After: miss 6 (range verification)

Same `BenchmarkOpenVerify` and `BenchmarkPutEncryptedBlob` (64 KiB to
100 MiB of synthetic ciphertext). Both columns were run on this host: 4 vCPU
Intel Xeon with SHA-NI, 15 GiB, go1.26.10, Linux amd64, shared with other
jobs. Means of two runs of
`cd server && go test -run '^$' -bench 'OpenVerify|PutEncryptedBlob$' -benchmem -count 2 ./internal/uploads`.

| Benchmark | Size | Before ns/op | After ns/op |
|---|---|---|---|
| Open + 64 KiB range read | 64K / 1M / 16M / 50M / 100M | 51.6k / 622k / 10.4M / 32.8M / **69.3M** | 40.9k / 41.1k / 41.3k / 40.9k / **41.3k** |
| Open + full read | 64K / 1M / 16M / 50M / 100M | 51.8k / 658k / 11.9M / 38.7M / 83.0M | 41.0k / 624k / 10.7M / 35.6M / 72.7M |
| Range read, blob without a record (first open only) | 64K / 1M / 16M / 50M / 100M | same as the range row | 123k / 1.29M / 20.2M / 64.0M / 129M |
| PutEncryptedBlob | 64K / 1M / 16M / 50M | 857k / 2.64M / 24.0M / 78.6M | 834k / 3.23M / 36.2M / 111M |

- **Change:** an upload hashes each 64 KiB chunk in the same pass as the
  whole blob. The record (version, whole digest, chunk digests; 32 B per
  64 KiB, 51 KiB for 100 MiB) goes into the new nullable `chunk_digests`
  column in the same INSERT as the attachment or backup row
  (`0034_blob_chunk_digests.sql`, additive). `Open` checks the size; each
  read hashes the chunk it needs and serves only from that hashed buffer,
  which also closes the old hash-then-reread gap. Bytes appended after
  `Open` are never read.
- **Client view:** the chunk holding the first byte is verified before the
  status line, so a bad chunk there is the usual `500 blob_integrity_failed`.
  A bad chunk later aborts the response (`http.ErrAbortHandler`): a broken
  transfer, never an unverified byte. Resuming there gets the clean 500, and
  recovery records only the bytes sent before the bad chunk. The server logs
  `blob_integrity_failed` with no key or bytes.
- **Existing blobs (NULL):** still verified in full on open. A success stores
  the rebuilt record, only into a NULL row that still has the same digest and
  size, so later ranges are fast. A malformed record falls back to the full
  check and logs `blob_digest_record_invalid`.
- **Costs:** uploads hash twice (about +40% at 16-50 MiB when CPU-bound; real
  uploads are network-bound). The first open of an existing blob also hashes
  twice. Each open download holds one pooled 64 KiB buffer; sendfile is no
  longer used.
- **Detection:** downloads no longer notice damage outside the bytes they
  request. The daily backup still hashes every blob in full
  (`docs/operations.md`).
- **Rollback:** older binaries ignore the column. Rows they write get NULL,
  which is verified in full.
- **Tests:** `uploads/local_test.go`, `httpapi/blob_verification_test.go`,
  `storage/blob_chunk_digests_test.go`. They cover: a bad chunk inside and
  outside the range, a read across the boundary, multipart ranges, aborted
  downloads over a real connection, recovery progress and resume, legacy
  rows (fail, then backfill), malformed records, a file truncated or
  extended after open, the verified buffer, seek bounds, and concurrent
  readers under `-race`.
- **Advisor (before coding):** asked to find integrity holes in this design
  (substitution, truncation, TOCTOU, record/row mismatch, multipart ranges,
  recovery accounting, concurrency, crash safety), and to rule on the
  fallback, backfill and chunk size. No blocker. Adopted: an explicit abort
  instead of a short body; one response writer with an integrity flag for
  both download paths; strict record checks; exact chunk reads; backfill only
  into NULL, after the response; the operations note; the optional pooled
  buffer. Kept multipart ranges (still verified on read) and migration 0034,
  the number this batch assigned.
