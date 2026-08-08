# Performance issues

**Method note.** Nothing was executed or profiled. Every finding below is derived
from reading the code and reasoning about its cost curve, and each one names
where to measure. The board's own position is right — *"Measure query plans,
load, soak behavior, and push fan-out before tuning"* (`docs/board.md`, "Later,
not release-blocking"). This file exists to say **which** things to measure and
why, so that measurement is targeted rather than exploratory.

**The shape of the problem.** Almost nothing here hurts at small scale. Every
finding is a cost curve that is flat for a family instance and steep for a
200-person one — which is exactly the class of problem that passes testing and
then arrives in production. The three High findings are all superlinear.

| ID | Severity | Title | Cost driver | Bites at |
| --- | --- | --- | --- | --- |
| [P1](#p1) | **High** | Full blob re-hash on every download and every Range request | O(file size) per request | first large attachment |
| [P2](#p2) | **High** | `SyncBounds` scans the account's entire event history per poll | O(events) per sync | ~weeks of history |
| [P3](#p3) | **High** | Quota check runs two unindexed `SUM()` scans in the write transaction | O(all blobs) per upload | ~thousands of blobs |
| [P4](#p4) | Medium | `Hub.Register` is O(connections) under the global write lock | O(n) per connect, O(n²) per storm | reconnect after restart |
| [P5](#p5) | Medium | Root rebuild reconstructs both `ThemeData`s per notification | O(1) but large, per event | catch-up bursts |
| [P6](#p6) | Medium | Linear roster and conversation scans per message bubble per frame | O(messages × members) per frame | large groups |
| [P7](#p7) | Medium | `MarkDeviceSeen` takes the write lock on every authenticated request | 1 write txn per request | any sustained load |
| [P8](#p8) | Medium | `_repairMessage` copies the message map and re-sorts per message | O(n²) per catch-up | long absence |
| [P9](#p9) | Medium | Flat blob directory, fully enumerated every 6 hours | O(all blobs) per sweep | ~100k blobs |
| [P10](#p10) | Medium | Push fan-out is unbounded goroutines, serial delivery, one shared budget | drops on large groups | ~50+ devices |
| [P11](#p11) | Low | Startup fires ~8 concurrent unawaited network operations | burst per launch | cold start on mobile data |

---

## P1

### Full blob re-hash on every download and every Range request

**Severity:** High
**Location:** [`server/internal/uploads/local.go:159-191`](../server/internal/uploads/local.go#L159-L191); called from [`content_handlers.go:242-260`](../server/internal/httpapi/content_handlers.go#L242-L260)

**Problem**

`LocalStore.Open` verifies integrity by reading and hashing the **entire file**
before returning a handle:

```go
hash := sha256.New()
if _, err := io.Copy(hash, &contextReader{ctx: ctx, reader: file}); err != nil { ... }
expected, err := hex.DecodeString(expectedSHA256)
if err != nil || subtle.ConstantTimeCompare(hash.Sum(nil), expected) != 1 {
    return fail(ErrBlobIntegrity)
}
if _, err := file.Seek(0, io.SeekStart); err != nil { ... }
```

Then `serveEncryptedBlob` hands the file to `http.ServeContent`, which **supports
Range requests**. So:

- A 50 MB attachment download reads 100 MB from disk (once to hash, once to
  serve) and computes SHA-256 over 50 MB.
- A client resuming an interrupted download issues `Range: bytes=30000000-` — and
  pays the **full 50 MB hash again** to serve the remaining 20 MB.
- A media player or a chunked downloader issuing 10 range requests triggers **10
  full-file hashes**: 500 MB of reads and 500 MB of hashing to deliver 50 MB.

Backups are worse — the limit there is 100 MB (`content_handlers.go:155`).

The integrity check itself is correct and worth having. The problem is that it is
performed per **request** rather than per **object**, and the digest was already
computed and stored at write time (`PutEncryptedBlob` returns it,
`attachment_envelopes.ciphertext_sha256` persists it).

**Why it matters in production**

On the target hardware — a small VPS, a NAS, a Raspberry Pi — SHA-256 runs at
roughly 200–500 MB/s per core. A single 50 MB download costs 100–250 ms of pure
CPU before the first byte is sent, on top of the disk read. That is per request,
single-threaded, competing with every other request on a box sized for a handful
of users.

It is also a trivially cheap amplification primitive: an authorised conversation
member (or anyone holding a leaked recovery token — see
[`security-issues.md` S2](security-issues.md#s2)) can issue range requests in a
loop and convert a few bytes of request into hundreds of megabytes of disk and
CPU each. There is no upload-specific rate class; the general limit is 240
requests/minute.

**Fix**

Verify per object, not per request.

1. **Trust the stored digest for reads.** It was computed under the server's own
   control at write time and the file is only mutated by delete. Verify size and
   mode (already done, cheaply, via `file.Stat()`) and serve.
2. **If a read-time check is wanted, scope it:** verify the full digest only when
   the request has **no** `Range` header, so a plain download is checked once and
   a resumed transfer is not re-checked repeatedly.
3. **Add a background integrity scrub.** The retention sweeper already runs every
   6 hours; have it verify a rotating slice of blobs and quarantine mismatches.
   That gives stronger coverage than the current design — which never checks a
   blob nobody downloads — at a fraction of the cost.
4. **Expose the result.** A `veritra_blob_integrity_failures_total` counter turns
   silent corruption into an alert rather than a user-visible 500.
5. **Measure:** time-to-first-byte for a 50 MB attachment, and the same for a
   `Range` request at 60% offset. The gap between them is this finding.

**Blocker:** No — but it should be fixed before attachments are unblocked, since
today no client can upload one, and the day they can this becomes the hottest
path on the server.

---

## P2

### `SyncBounds` scans the account's entire event history per poll

**Severity:** High
**Location:** [`server/internal/storage/message_store.go:700-728`](../server/internal/storage/message_store.go#L700-L728); called unconditionally from `ListSyncEvents` at `:651`

**Problem**

Every call to `ListSyncEvents` — i.e. every sync poll, every WebSocket-triggered
catch-up, every push wake — first calls `SyncBounds`, which runs:

```sql
SELECT MIN(id), MAX(id) FROM (
    SELECT id FROM sync_events WHERE account_id = ?
    UNION ALL
    SELECT se.id FROM sync_events se
    JOIN memberships m ON m.conversation_id = se.conversation_id
    WHERE se.account_id IS NULL AND m.account_id = ?
      AND NOT EXISTS (
        SELECT 1 FROM account_blocks b
        WHERE b.blocker_account_id = m.account_id
          AND b.blocked_account_id = CASE
            WHEN se.event_type LIKE 'message.%' THEN
                (SELECT sender_account_id FROM message_envelopes
                 WHERE id = json_extract(se.payload_json, '$.message_id'))
            WHEN se.event_type LIKE 'reaction.%' OR se.event_type = 'read_receipt.updated'
                THEN json_extract(se.payload_json, '$.account_id')
            WHEN se.event_type LIKE 'call.%' THEN json_extract(se.payload_json, '$.created_by')
            ELSE NULL END)
)
```

Note what is **absent**: any `id >` predicate. This aggregates over the account's
**entire retained event history** — 30 days by default, configurable to 3,650.
And for every row it performs a `LIKE` on the event type, a `json_extract` on the
payload text, and — for message events — a **correlated subquery into
`message_envelopes`**.

`ListSyncEvents` then runs essentially the same expensive expression again, this
time correctly bounded by `id > afterID` and `LIMIT`.

The result of all that work is used for exactly one thing:

```go
_, oldest, _, err := s.SyncBounds(ctx, accountID)
if afterID > 0 && oldest > 0 && afterID < oldest-1 {
    return nil, ErrSyncCursorExpired
}
```

Only `oldest` is read, and only to detect a cursor that fell behind the retention
floor. **The block filter cannot affect that answer in any way that matters** —
whether a blocked sender's event is counted does not change whether the client's
cursor has aged out of retention.

**Why it matters in production**

Cost scales with **history size**, while the useful work scales with **new events
since the cursor**. An idle client polling every 30 seconds and receiving nothing
still pays a full-history scan each time. A 30-person group at 500 messages/day
produces ~15,000 sync events per member per month; each poll parses 15,000 JSON
payloads and runs several thousand correlated subqueries — to return zero rows.

Every one of these runs on the reader pool (4–16 connections), so under a
reconnect storm the pool saturates on scans that produce no data, and genuine
queries queue behind them.

**Fix**

1. **Make `SyncBounds` cheap and unfiltered for its actual purpose.** The
   retention floor is a global property of the `sync_events` table:
   ```sql
   SELECT MIN(id), MAX(id) FROM sync_events
   ```
   `MIN(id)`/`MAX(id)` on an `INTEGER PRIMARY KEY` are index-terminal — effectively
   free. A cursor older than the global minimum has definitively expired, which is
   the exact question being asked. If a per-account floor is genuinely needed,
   maintain it incrementally rather than deriving it by scan.
2. **Split the API.** `SyncBounds` currently returns `(epoch, oldest, latest)` and
   is presumably used elsewhere for the epoch. Give `ListSyncEvents` a narrow
   `oldestRetainedEventID(ctx)` helper and leave the richer call for callers that
   need it.
3. **Denormalise the block filter out of the hot query.** `json_extract` plus a
   correlated subquery per row is the dominant cost in both `SyncBounds` and
   `ListSyncEvents`. Store the subject account ID in a dedicated
   `sync_events.subject_account_id` column at insert time (the writer always knows
   it) and index it. The filter becomes a simple indexed `NOT EXISTS` and the JSON
   parsing disappears from the read path entirely. This is the single highest-value
   schema change in this document.
4. **Measure:** `EXPLAIN QUERY PLAN` for both statements on a seeded database with
   ~50,000 events across ~20 conversations, and wall-clock a poll that returns zero
   rows. That number is what an idle client costs today.

**Blocker:** No — but it is the first thing to fix under load, and (3) is a
migration, so it wants doing before the instance has data to migrate.

**Related risks** — migration `0003_sync_event_indexes.sql` and
`0011_sync_epoch.sql` already exist; check whether their indexes are usable by the
current query shape, because the `json_extract` in the `NOT EXISTS` almost
certainly prevents index use on the block lookup.

---

## P3

### Quota check runs two unindexed `SUM()` scans in the write transaction

**Severity:** High
**Location:** [`server/internal/storage/content_store.go:611-628`](../server/internal/storage/content_store.go#L611-L628)

**Problem**

```go
const usageQuery = `SELECT COALESCE(SUM(size_bytes), 0) FROM (
    SELECT owner_account_id AS account_id, size_bytes FROM attachment_envelopes
    UNION ALL SELECT account_id, size_bytes FROM backup_blobs
)`
var accountUsage, instanceUsage int64
tx.QueryRowContext(ctx, usageQuery+` WHERE account_id = ?`, accountID).Scan(&accountUsage)
tx.QueryRowContext(ctx, usageQuery).Scan(&instanceUsage)
```

Three compounding problems:

1. **The subquery defeats indexing.** The `WHERE account_id = ?` is applied to the
   *result* of a `UNION ALL`, so SQLite must materialise both tables in full and
   then filter. An index on `attachment_envelopes(owner_account_id)` cannot be
   used.
2. **The second query has no filter at all** — a deliberate full scan of both
   tables, every upload.
3. **Both run inside the write transaction**, on the single writer connection
   (`sqlite.go:91`, `SetMaxOpenConns(1)`). While they run, **every other write on
   the instance is blocked**: message sends, sync-event inserts, read receipts,
   session creation, the retention sweeper.

**Why it matters in production**

Cost grows with total blob count while the useful answer — "does this account have
room?" — is a single number that could be maintained incrementally. At 100,000
blob rows, two full scans per upload is tens of milliseconds of writer-lock hold
per upload, and it lengthens as the instance grows.

The worst interaction is with [`security-issues.md` S5](security-issues.md#s5):
the quota check runs *after* the body is written, so an account that is already
full pays this cost on **every rejected upload**, at up to 240 requests/minute.
That converts a rejected upload into a writer-lock stall for everyone.

**Fix**

1. **Maintain usage incrementally.** Add a `blob_usage(account_id, bytes)` table
   updated in the same transaction as every insert and delete of an
   `attachment_envelope` or `backup_blob`, plus a single instance-total row. The
   quota check becomes two indexed point lookups. Because every mutation already
   runs in a transaction, the counter cannot drift.
2. **Interim, without a migration:** rewrite as two separate indexed aggregates
   and add the indexes:
   ```sql
   SELECT (SELECT COALESCE(SUM(size_bytes),0) FROM attachment_envelopes WHERE owner_account_id = ?)
        + (SELECT COALESCE(SUM(size_bytes),0) FROM backup_blobs WHERE account_id = ?)
   ```
   with `CREATE INDEX ... ON attachment_envelopes(owner_account_id)` and the
   equivalent on `backup_blobs(account_id)`. Keeps the instance total as a scan,
   but removes the per-account one.
3. **Cache the instance total** in memory with a short TTL, refreshed by the
   retention sweeper. A 10 GiB instance ceiling does not need to be exact to the
   byte on every request.
4. **Add a `doctor` reconciliation** that recomputes the counters and reports
   drift, so the incremental design is verifiable.
5. **Measure:** wall-clock `enforceBlobQuota` against 10, 1,000 and 100,000 blob
   rows. The curve is the finding.

**Blocker:** No — but fix it together with [S5](security-issues.md#s5) and before
attachments are unblocked.

---

## P4

### `Hub.Register` is O(connections) under the global write lock

**Severity:** Medium
**Location:** [`server/internal/realtime/hub.go:50-81`](../server/internal/realtime/hub.go#L50-L81)

**Problem**

Every new WebSocket connection counts its limits by walking every existing
connection:

```go
h.mu.Lock()
defer h.mu.Unlock()
accountCount, deviceCount, ipCount := 0, 0, 0
for _, clients := range h.subscribers {
    for existing := range clients {
        if existing.accountID == accountID { accountCount++ }
        if existing.accountID == accountID && existing.deviceID == deviceID { deviceCount++ }
        if existing.remoteIP == remoteIP { ipCount++ }
    }
}
```

`maxConnections` is 10,000, so a single registration can compare up to 10,000
clients — while holding `h.mu.Lock()`, which also excludes `Publish` (`RLock`),
`Unregister`, `DisconnectDevice`, `DisconnectAccountExceptDevice` and
`ConnectionCount`.

Note the per-account and per-device counts only need `h.subscribers[accountID]`
— a single map already keyed by account. Only the per-IP count needs a global
view, and that is what forces the full walk.

**Why it matters in production**

Individually O(n); in aggregate O(n²). The triggering scenario is routine: the
server restarts, all connected clients reconnect. Each registration walks the
set built so far, so restoring N connections costs ~N²/2 comparisons, fully
serialised behind one mutex. At 5,000 clients that is ~12.5 million comparisons
with every realtime publish blocked behind them — so message fan-out stalls
exactly when everyone is reconnecting.

[`logical-issues.md` L17](logical-issues.md#l17) makes this more likely: without a
close frame, clients cannot distinguish a planned restart from a network failure,
so they all back off by the same amount and return in a synchronised herd.

**Fix**

1. **Maintain counters instead of scanning.** Three maps —
   `map[string]int` for account, `map[accountDeviceKey]int`, `map[string]int` for
   IP — incremented in `Register` and decremented in `Unregister` and the
   `Disconnect*` paths. Registration becomes O(1). The per-account map already
   exists; only the IP counter is genuinely new state.
2. **Delete empty counter entries** on decrement so the IP map does not grow
   unbounded (it is keyed by client IP, so it is attacker-influenced).
3. **Shrink the critical section.** `Publish` copies the client list under
   `RLock` and sends outside it, which is already correct; `Register` should be
   equally brief.
4. **Add jitter to client reconnect** so a restart does not produce a herd
   regardless.
5. **Measure:** a benchmark registering 10,000 clients sequentially, plus
   `ConnectionCount` latency during that run.

**Blocker:** No.

---

## P5

### Root rebuild reconstructs both `ThemeData`s per notification

**Severity:** Medium
**Location:** [`mobile/lib/main.dart:44-58`](../mobile/lib/main.dart#L44-L58)

**Problem**

```dart
AnimatedBuilder(
  animation: state,
  builder: (context, _) => MaterialApp(
    theme: veritraLightTheme(),
    darkTheme: veritraDarkTheme(),
    ...
```

`AppState.notifyListeners()` fires for every message, typing event, busy-flag
change, connection-status change and sync tick. Each one:

- calls `veritraLightTheme()` **and** `veritraDarkTheme()`, each constructing a
  full `ColorScheme`, `TextTheme` and roughly a dozen component sub-themes
  (`theme.dart` is 272 lines of exactly this);
- marks the entire widget subtree below `MaterialApp` dirty;
- forces `Theme.of(context)` consumers to re-resolve, because the `ThemeData`
  identity changed even though its values did not.

Discussed as a UI concern in [`ui-issues.md` U9](ui-issues.md#u9); listed here for
its cost profile.

**Why it matters in production**

The rebuild rate peaks exactly when the app is busiest — during catch-up after a
period offline, when `notifyListeners()` fires repeatedly as message lists mutate
— and it compounds with [P6](#p6), which is O(messages × members) per frame in the
same window. That combination is the most likely source of visible jank in the
app.

**Fix**

1. **Hoist the themes.** `static final _light = veritraLightTheme();` and the
   same for dark. One line each, no behavioural change, and it removes the
   dominant per-notification allocation immediately.
2. **Move the listener below `MaterialApp`** so the app scaffold, navigator and
   theme are stable and only `AppShell` rebuilds.
3. **Narrow the notifications.** Split `AppState` or expose targeted
   `Listenable`s (conversation list, selected-conversation messages, connection
   status) so an event in conversation A does not rebuild conversation B.
4. **Measure:** DevTools timeline during a simulated 500-event catch-up, before
   and after step 1. Step 1 alone should be visible.

**Blocker:** No.

---

## P6

### Linear roster and conversation scans per message bubble per frame

**Severity:** Medium
**Location:** [`mobile/lib/features/chat/chat_screen.dart:309-315`](../mobile/lib/features/chat/chat_screen.dart#L309-L315) (`_senderLabel`), `:299-304` (`_isDm`)

**Problem**

```dart
String _senderLabel(String accountId) {
  final member = state
      .membersFor(conversationId)
      .where((item) => item.accountId == accountId)
      .firstOrNull;
  return accountLabel(accountId, member?.username);
}
```

`membersFor` returns a `List`, and this is called from `itemBuilder` for **every
message bubble** — so it is O(members) per bubble, and the builder runs for every
item in the viewport on every frame of a scroll.

A 100-member group with ~15 bubbles on screen is ~1,500 comparisons per frame,
each allocating a lazy `where` iterable. Per [P5](#p5), the whole subtree rebuilds
on unrelated state changes too, so this runs far more often than scrolling alone
would require.

`_isDm` has the same shape against `state.conversations` — once per `_MessageList`
build rather than per bubble, so much cheaper, but the same avoidable pattern.

**Why it matters in production**

At 60 fps the frame budget is 16.7 ms. This is unlikely to blow it alone, but it
is pure waste in the hot path of the app's main screen, and it grows with group
size — so the largest, most active conversations are the ones that stutter.

**Fix**

1. **Index the roster once per build.** Build
   `Map<String, ConversationMember>` in `_MessageList.build` (or memoise it on
   `AppState` keyed by conversation, invalidated when the roster changes) and look
   up by key. O(1) per bubble.
2. **Hoist `_isDm`** to a single lookup in `build` rather than a getter that
   rescans.
3. **Give `AppState` a `conversationById` map.** `chat_screen.dart:75-77`,
   `chat_list_screen.dart` and several other call sites all do
   `state.conversations.where((item) => item.id == …).firstOrNull` — the same
   linear scan repeated across the codebase.
4. **Measure:** DevTools timeline scrolling a 200-message conversation in a
   100-member group, before and after.

**Blocker:** No.

---

## P7

### `MarkDeviceSeen` takes the write lock on every authenticated request

**Severity:** Medium
**Location:** [`server/internal/httpapi/api.go:136-138`](../server/internal/httpapi/api.go#L136-L138); statement at [`server/internal/storage/identity_store.go:207-221`](../server/internal/storage/identity_store.go#L207-L221)

**Problem**

`withAuth` wraps **every** authenticated route and calls:

```go
UPDATE devices SET last_seen_at = ?
WHERE id = ? AND revoked_at IS NULL
  AND (last_seen_at IS NULL OR last_seen_at <= ?)   -- now - 5 minutes
```

The 5-minute predicate is a good throttle — the row is updated at most every 5
minutes per device. But the **statement still executes on every request**, and
`dbRouter.ExecContext` routes all writes to the single writer connection
(`sqlite.go:55-57`, `SetMaxOpenConns(1)`). In WAL mode an `UPDATE` that matches
zero rows still opens a write transaction, acquires the writer lock and commits.

So the throttle prevents the *write*, not the *lock acquisition*. Every
authenticated request — including every `GET` — serialises through the single
writer.

**Why it matters in production**

The one writer connection is the instance's fundamental throughput limit. Adding
a mandatory write-lock round trip to every read request means read throughput is
bounded by write concurrency, which is 1. Under a reconnect storm — thousands of
clients each firing `syncEvents`, `conversations`, `devices` — the writer becomes
the bottleneck for requests that write nothing.

It also interacts badly with [P3](#p3): while an upload holds the writer for two
full table scans, every authenticated request on the instance is queued behind it,
including pure reads.

**Fix**

1. **Check before writing.** Keep a small in-process
   `map[deviceID]time.Time` of last-marked times and skip the statement entirely
   when the device was seen within the window. Bounded by active device count, and
   swept on the existing ticker. Removes the lock acquisition in the common case.
2. **Or batch it.** Buffer device IDs in memory and flush them in one transaction
   every 30 seconds. `last_seen_at` does not need to be exact.
3. **Do it asynchronously** either way, so request latency never depends on the
   writer lock for a field nobody is waiting on.
4. **Measure:** p99 latency of `GET /api/v1/conversations` with and without the
   call, under concurrent upload load.

**Blocker:** No.

---

## P8

### `_repairMessage` copies the message map and re-sorts per message

**Severity:** Medium
**Location:** [`mobile/lib/core/app_state.dart:1578-1604`](../mobile/lib/core/app_state.dart#L1578-L1604)

**Problem**

```dart
final updated = <ReceivedMessageEnvelope>[
  repaired,
  ...existing.where((message) => message.id != repaired.id),
]..sort((left, right) { ... });
messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
  ...messagesByConversation,
  repaired.conversationId: updated,
};
```

Per repaired message: rebuild the conversation's full list (O(m)), sort it
(O(m log m)), and shallow-copy the entire outer map (O(c)). And per
[`logical-issues.md` L9](logical-issues.md#l9), repairs run one at a time in a
loop over every `message.envelope.*` event in the whole catch-up.

For 500 repairs in a conversation holding 200 cached messages: 500 sorts of 200
elements plus 500 map copies — on top of 500 sequential HTTP round trips.

**Why it matters in production**

Catch-up after a long absence is the moment the app most needs to feel fast, and
this makes it quadratic in the number of repaired messages. It runs on the UI
isolate, so it competes directly with rendering.

**Fix**

1. **Batch the repairs.** Collect all repaired envelopes first, then apply them in
   a single pass: one merge, one sort, one map assignment.
2. **Insert in order rather than re-sorting.** The list is already sorted; a
   binary-search insertion is O(log m) instead of O(m log m).
3. **Mutate the inner list in place** and only replace the outer map reference
   once at the end — the map copy exists to trigger the `ChangeNotifier`, and one
   copy per batch is enough.
4. Combine with [L9](logical-issues.md#l9)'s batch fetch so both the network and
   the CPU cost collapse together.
5. **Measure:** time a synthetic catch-up applying 500 repairs across 5
   conversations, before and after.

**Blocker:** No.

---

## P9

### Flat blob directory, fully enumerated every 6 hours

**Severity:** Medium
**Location:** [`server/internal/uploads/local.go:32-43`](../server/internal/uploads/local.go#L32-L43) (flat root), `:56-82` (`CleanupTemporaryFiles`)

**Problem**

Every blob is written directly into one directory:

```go
path := filepath.Join(s.root, id)     // s.root/blob_xxxxx
```

No sharding. And the temp-file sweeper enumerates the whole directory to find the
`.tmp` files:

```go
entries, err := os.ReadDir(s.root)
for _, entry := range entries {
    if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".tmp") { continue }
```

`os.ReadDir` reads **and sorts** every entry — so with 500,000 attachments, a
sweep that is looking for a handful of partial uploads allocates and sorts
500,000 strings, every 6 hours.

**Why it matters in production**

Two curves. Directory operations degrade with entry count — acceptable on ext4
with `dir_index`, noticeably worse on XFS without, and poor on network or
overlay filesystems, which is a realistic self-hosting substrate (NAS, mounted
volume, Docker overlay). And `ReadDir`'s allocate-and-sort cost is unnecessary in
full: the sweeper does not need sorted order, or non-`.tmp` entries.

Operationally, a directory with hundreds of thousands of entries is also hostile
to the operator: `ls`, `rsync`, `tar` and backup tooling all slow down, and
`messenger-server backup` copies this tree.

**Fix**

1. **Shard by ID prefix.** `s.root/ab/cd/blob_abcd…` using two levels of two hex
   characters gives 65,536 leaf directories. `LocalStore.path` is the only place
   that maps a key to a path, so this is a contained change — plus a one-time
   migration that moves existing files and a fallback that checks the flat
   location for keys not yet moved.
2. **Use `os.Open` + `File.ReadDir(n)`** in the sweeper to stream entries in
   batches without sorting or allocating the whole listing.
3. **Better: put temp files in their own subdirectory** (`s.root/tmp/`). Then the
   sweeper enumerates only partial uploads and never touches the blob tree at all.
   This is the smallest change with the largest effect and is worth doing even if
   sharding is deferred.
4. **Measure:** `CleanupTemporaryFiles` wall time against 1,000 / 100,000 /
   500,000 blob files.

**Blocker:** No — but (3) is cheap and (1) gets much more expensive once an
instance has data to migrate.

---

## P10

### Push fan-out is unbounded goroutines, serial delivery, one shared budget

**Severity:** Medium
**Location:** [`server/internal/httpapi/content_handlers.go:318-354`](../server/internal/httpapi/content_handlers.go#L318-L354)

**Problem**

```go
func (a *API) notifyPush(ctx context.Context, conversationID, senderAccountID string) {
    targets, err := a.Store.PushTargetsForConversation(ctx, conversationID, senderAccountID)
    if err != nil || len(targets) == 0 { return }
    go a.deliverPush(targets)
}

func (a *API) deliverPush(targets []storage.PushTarget) {
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()
    for _, target := range targets {
        err := a.Push.SendEncryptedEventAvailable(ctx, push.Notification{...})
        ...
        if ctx.Err() != nil { break }
    }
    ...
}
```

Four problems:

1. **Serial delivery under one shared 30-second budget.** Every target is
   contacted in sequence. A 40-member group with 2 devices each is 80 sequential
   HTTPS calls to FCM/APNs; at 400 ms each that is 32 seconds — so the loop hits
   `ctx.Err()` and **silently `break`s**, and the remaining members are never
   notified. No retry, no queue, no metric distinguishing "delivered" from "ran out
   of time". `failures` counts errors, not abandonment.
2. **Unbounded goroutines.** One per message, with no worker pool and no cap.
   A burst of messages spawns a goroutine per message, each holding its target
   slice and its HTTP connections.
3. **`context.Background()`** detaches from shutdown, so a drain can cut delivery
   mid-flight with no coordination — `Serve`'s 25-second shutdown deadline does
   not wait for these.
4. **No retry on transient failure.** `ErrSubscriptionGone` correctly disables the
   target; everything else just increments a counter and is dropped.

**Why it matters in production**

Push is what makes a messenger arrive. Silent partial delivery on large
conversations is the failure mode users describe as "I only get some messages" —
and it is size-dependent, so it will not reproduce in a two-person test. Card I24
step 4 tests background wake on two devices, which will pass while an 80-device
group fails.

**Fix**

1. **Parallelise with a bounded worker pool** — 8–16 concurrent sends — and give
   **each** send its own timeout (5–10 s) rather than sharing one budget across
   all of them. That alone converts 32 seconds serial into a few seconds.
2. **Replace the goroutine-per-message with a queue** and a fixed set of workers,
   so concurrency is bounded by design.
3. **Persist and retry.** A `push_deliveries` table with attempt counts lets the
   existing retention sweeper drain a backlog, and makes delivery survive a
   restart. The blob-deletion queue (`blob_deletion_store.go`) is a good model —
   the same durable-retry shape already exists in this codebase.
4. **Derive the context from the server's lifecycle**, not `Background()`, so
   drain waits for in-flight sends.
5. **Meter it:** attempted, delivered, failed, abandoned — per provider. Right now
   abandonment is invisible.
6. **Measure:** wall time and delivery ratio for a conversation with 100 push
   targets against a stubbed slow provider.

**Blocker:** No — but it should be fixed before I24's push verification, or that
verification will pass while the real behaviour is broken.

---

## P11

### Startup fires ~8 concurrent unawaited network operations

**Severity:** Low
**Location:** [`mobile/lib/core/app_state.dart:1278-1305`](../mobile/lib/core/app_state.dart#L1278-L1305)

**Problem**

```dart
unawaited(_catchUpSyncEvents());
unawaited(_flushOutbox());
unawaited(_flushMlsOutbox());
unawaited(sync!.connect());
unawaited(refreshInvites());
unawaited(refreshCommunities());
unawaited(refreshBlocks());
unawaited(_startPush());
```

Eight concurrent operations, several of which page internally —
`refreshConversations` and `refreshDevices` each loop until a short page
([`logical-issues.md` L8](logical-issues.md#l8)) — so the real request count at
cold start is well above eight and unbounded from the client's point of view.

There is no ordering and no prioritisation: the invite list (which the user is
almost certainly not looking at) competes with catch-up (which they are).

**Why it matters in production**

On a slow mobile connection this is a burst of parallel TLS handshakes and
requests at exactly the moment the user is waiting for the chat list. It also
consumes the server's 240/minute per-IP budget, which matters when several
devices behind one NAT start together. And because [P7](#p7) puts a writer-lock
acquisition on every authenticated request, the burst serialises server-side
anyway — so the parallelism buys little.

**Fix**

1. **Prioritise.** Connect the socket and run catch-up first; defer invites,
   communities and blocks until the first catch-up completes or the relevant
   screen is opened. `refreshInvites` in particular only matters on the Invites
   screen.
2. **Bound concurrency** with a small scheduler (3–4 in flight).
3. **Handle failures.** Each of these is `unawaited` with error handling that
   varies by callee — `_flushMlsOutbox` has none at all
   ([`logical-issues.md` L3](logical-issues.md#l3)). Wrap `main()` in
   `runZonedGuarded` so nothing escapes silently.
4. **Measure:** time to first painted chat list on a throttled connection.

**Blocker:** No.

---

# Priorities

**Before attachments are unblocked** — these three become hot paths the moment
the crypto gate opens, and two of them want schema changes that are cheaper now
than later:

1. **[P1](#p1)** Stop re-hashing blobs per request. Biggest single win; the
   digest is already stored.
2. **[P3](#p3)** Maintain blob usage incrementally instead of scanning. Fix
   together with [`security-issues.md` S5](security-issues.md#s5).
3. **[P2](#p2)** Give `SyncBounds` a cheap query, and denormalise the block
   subject out of the sync payload JSON. The migration is the reason to do it
   early.

**Before real-device verification (card I24)** — otherwise the verification will
pass while the behaviour is wrong at scale:

4. **[P10](#p10)** Bounded-concurrency push with per-send timeouts and metrics.
   A two-device test cannot detect the current failure.

**Under load, whenever load arrives:**

5. **[P7](#p7)** Remove the writer-lock acquisition from every read request.
6. **[P4](#p4)** O(1) connection registration.
7. **[P9](#p9)** At minimum, move temp files to their own subdirectory.

**Client-side, alongside the UI work:**

8. **[P5](#p5)** Hoist the themes — one line, immediate.
9. **[P6](#p6)** Index the roster; add `conversationById` to `AppState`.
10. **[P8](#p8)** + [`logical-issues.md` L9](logical-issues.md#l9) — batch
    catch-up repairs in both network and CPU.
11. **[P11](#p11)** Prioritise startup work.

## Instrumentation to add first

Every finding above says "measure X". The server already has a metrics surface
(`app.go:353-433`) exposing request counts, latency histograms and realtime
connections. Four additions would make this whole file empirical rather than
analytical, and they are small:

| Metric | Answers |
| --- | --- |
| `veritra_sqlite_writer_wait_seconds` | [P3](#p3), [P7](#p7) — is the single writer the bottleneck? |
| `veritra_blob_read_bytes_total` / `_hash_bytes_total` | [P1](#p1) — the ratio *is* the amplification factor |
| `veritra_push_deliveries_total{result="delivered\|failed\|abandoned"}` | [P10](#p10) — abandonment is currently invisible |
| `veritra_sync_events_query_seconds` | [P2](#p2) — does idle-poll cost grow with history? |

All four are counters or histograms on paths that already exist, none touches the
privacy boundary (no account, device or conversation identifiers), and together
they turn "measure before tuning" from a principle into a practice.
