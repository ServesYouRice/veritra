# Logical issues

Application logic, data handling, async behaviour, and implementation quality.

Scope note: this reviews the **envelope transport, sync, storage and state**
paths. It is **not** a cryptographic review of MLS — see
[`audit-plan.md` §5](audit-plan.md#5-limits-of-this-audit).

| ID | Severity | Title | Area | Blocker |
| --- | --- | --- | --- | --- |
| [L1](#l1) | **Critical** | Outbox silently deletes the oldest queued messages at the cap | Mobile / storage | **Yes** |
| [L2](#l2) | **High** | One malformed or unfetchable sync event wedges catch-up forever | Mobile / sync | **Yes** |
| [L3](#l3) | **High** | MLS outbox has no error handling and blocks head-of-line forever | Mobile / sync | **Yes** |
| [L4](#l4) | **High** | Committed message returns 500 and then never fans out | Server / messaging | **Yes** |
| [L5](#l5) | **High** | Expired-message sweeper drains only 500 rows per 6 hours | Server / retention | **Yes** |
| [L6](#l6) | **High** | Attachment prune deletes blobs whose database rows survive | Server / retention | **Yes** |
| [L7](#l7) | **High** | `resetOnError: true` silently destroys the local database key | Mobile / storage | **Yes** |
| [L8](#l8) | Medium | Unbounded client paging loops with no iteration cap | Mobile / API | No |
| [L9](#l9) | Medium | Catch-up does one sequential round trip per repaired message | Mobile / sync | No |
| [L10](#l10) | Medium | Quota rejection (507) is retried forever | Mobile / outbox | No |
| [L11](#l11) | Medium | Unchecked casts throw `TypeError` instead of `ApiException` | Mobile / API | No |
| [L12](#l12) | Medium | `_flushOutbox` has no re-entrancy guard | Mobile / sync | No |
| [L13](#l13) | Low | Typing throttle map grows unbounded and rescans on insert | Server / httpapi | No |
| [L14](#l14) | Low | `parseTime` silently yields the zero time | Server / storage | No |
| [L15](#l15) | Low | Non-null assertion depends on a distant condition | Mobile / sync | No |
| [L16](#l16) | Low | Trailing slashes 404 on subroute handlers | Server / httpapi | No |
| [L17](#l17) | Low | WebSocket drain sends no close frame | Server / realtime | No |
| [L18](#l18) | Low | Rust release profile does not pin `panic` or enable overflow checks | Crypto | No |

---

## L1

### Outbox silently deletes the oldest queued messages at the cap

**Severity:** Critical
**Location:** [`mobile/lib/storage/encrypted_database.dart:479-503`](../mobile/lib/storage/encrypted_database.dart#L479-L503), cap set at [`mobile/lib/storage/local_store.dart:530`](../mobile/lib/storage/local_store.dart#L530), call sites at `local_store.dart:636` and `:788`

**Problem**

Every enqueue into the durable outbox runs a trim inside the same transaction:

```dart
final excess = rows.length - maxEntries;          // maxEntries = 100
for (final row in rows.take(excess > 0 ? excess : 0)) {
  await (delete(localOutboxEntries)
        ..where((table) => table.idempotencyKey.equals(row.idempotencyKey)))
      .go();
}
```

`rows` is ordered `queuedAt ASC, idempotencyKey ASC`, so `rows.take(excess)`
selects the **oldest** entries. Once a user has 100 unsent messages, message 101
evicts message 1. The delete is unconditional, returns nothing, raises nothing,
and writes no marker. `AppState.pendingOutbox` is rebuilt from the table on the
next flush, so the pending bubble for the evicted message simply disappears from
the thread.

**Why it matters in production**

This is silent, unrecoverable message loss in the core send path, and it picks
the worst possible victim. A user composing on a plane, on a train, or on a rural
connection loses the messages they typed **first** — the ones they are most
likely to believe were delivered — while later messages go through. The
conversation arrives at the recipient with a hole in it and both sides are
reordered relative to intent. No error is shown, no log is written, and there is
nothing in the UI that would let a user notice, let alone recover.

A privacy messenger's entire value proposition is that the user's words go where
they intended and nowhere else. Losing them without saying so is worse than
refusing to accept them.

**Fix**

Never evict a queued message. At the cap, refuse the enqueue and surface it:

1. Change `writeOutboxEntry` to return a boolean (or throw a typed
   `OutboxFullException`) instead of trimming.
2. In `AppState.sendMessageTo`, treat a refusal as an operation-scoped error on
   `Ops.send`, leaving the composer text intact so the user can retry or copy it.
3. If a hard cap must stay for storage reasons, raise it substantially (the rows
   are small) and make eviction **explicit**: mark the entry
   `OutboxDeliveryState.terminal` with a distinct `failureClass: 'dropped'` and
   keep it visible in the thread as a failed bubble rather than deleting it.
4. Add a test: enqueue `maxEntries + 1` and assert the oldest entry still exists
   and the newest was refused.

**Blocker:** **Yes.** Silent data loss in the send path.

**Related risks**

- Interacts with [L10](#l10): a conversation that hits the server quota
  accumulates retrying entries, walking the outbox toward the cap and triggering
  this eviction on unrelated messages.
- The same `maxEntries` trim pattern appears at `encrypted_database.dart:754-790`
  for a second table; check whether it has the same semantics.
- `_maxCachedConversations = 20` and `_maxMessagesPerConversation = 200`
  (`local_store.dart:528-529`) truncate the *read* cache. That is far less
  serious — the data is recoverable from the server — but it means a user with
  more than 20 conversations has no offline access to the rest, with no
  indication which ones are cached.

---

## L2

### One malformed or unfetchable sync event wedges catch-up forever

**Severity:** High
**Location:** [`mobile/lib/core/app_state.dart:1543-1571`](../mobile/lib/core/app_state.dart#L1543-L1571) (`_processCryptoSyncEvent`), consumed at `:1467-1472`, error handler at `:1503-1524`

**Problem**

`_processCryptoSyncEvent` throws on anything it does not understand:

```dart
case 'mls.message.created':
  final id = _mlsMessageIdFromSyncEvent(event);
  if (id == null)
    throw StateError('MLS sync event is missing its message');
  await mls.processMlsMessage(await client.mlsMessage(current.token, id));
```

Three ways to throw: a payload without the expected key (`StateError`), an HTTP
failure fetching the referenced message (`ApiException` — including a **404**
when the server has already pruned it under retention), and any decrypt failure
inside `processMlsMessage`.

The throw propagates to `_catchUpSyncEvents`'s `catch (err)`, which sets
`syncError` and `ConnectionStatus.offline`. Critically, **the cursor is not
advanced past the offending event.** `_lastSyncEventId` is only written at
`:1509` after the whole loop succeeds, and inside the crypto loop it is re-read
from `localStore.loadSyncCursor()`. So the next catch-up starts at the same
cursor, fetches the same event, and throws again.

`_repairMessage` gets this right — it explicitly swallows 404 at
`app_state.dart:1595-1604` — which shows the pattern was understood in one place
and not applied in the other.

**Why it matters in production**

The device goes permanently offline and stays there. Every retry path — the
WebSocket event listener, the push wake, the manual pull-to-refresh — funnels
into `_catchUpSyncEvents` and hits the same event. The user sees a persistent
"offline" banner while the network is fine, receives nothing, and has no
recourse short of reinstalling (which, per [L7](#l7), is itself lossy).

The most likely real-world trigger is entirely benign: a message referenced by a
sync event is pruned by disappearing-message retention or by
`PruneExpiredContent` before a device that was offline comes back. That is not an
exotic condition — it is the *expected* interaction between retention and offline
devices, and it currently bricks the client.

**Fix**

Make event processing skip-tolerant and cursor-advancing:

1. Wrap the per-event body in a `try`. On `StateError`, on `ApiException` with
   status 404 or 410, and on any decode failure, **skip the event, advance the
   cursor past it**, and increment a counter.
2. Keep hard failures hard: a 401 must still clear the session, and a network
   error (`SocketException`) must still mark offline **without** advancing —
   distinguish "the server said this event is gone" from "I could not reach the
   server".
3. Surface skipped events distinctly rather than silently: a
   `syncSkippedCount` on `AppState` and a one-line notice ("Some older updates
   could not be applied") is enough. Do not reuse `syncError`, which drives the
   offline banner.
4. Add tests: a sync event whose payload lacks `mls_message_id`, and one whose
   referenced message returns 404. Assert catch-up completes and the cursor
   advanced.

**Blocker:** **Yes.** A single server-side retention event can permanently
disable a device.

**Related risks**

- The same wedge exists for the plain `message.envelope.created` branch at
  `:1554-1559`, which also has no 404 handling.
- `_repairMessage` rethrows every non-404 `ApiException` (`:1598-1600`), so a
  transient 500 on one message ID aborts the whole catch-up pass. Less severe
  (it self-heals when the 500 stops) but the same shape.
- Once crypto is unwired and `_mlsCrypto` is non-null, this path becomes the
  primary message-delivery route, so the blast radius grows.

---

## L3

### MLS outbox has no error handling and blocks head-of-line forever

**Severity:** High
**Location:** [`mobile/lib/core/app_state.dart:1757-1771`](../mobile/lib/core/app_state.dart#L1757-L1771)

**Problem**

```dart
Future<void> _flushMlsOutbox() async {
  ...
  for (final message in await localStore.pendingMlsMessages()) {
    await client.sendMlsMessage(...);
    await localStore.removePendingMlsMessage(message.idempotencyKey);
  }
}
```

There is no `try`, no failure classification, no backoff, no attempt counter and
no terminal state. Compare `_flushOutbox` (`:1696-1726`), which has all five.

Two consequences:

1. **Head-of-line block.** If `sendMlsMessage` fails permanently for the first
   queued message — a 400 from a malformed payload, a 403 after the sender was
   removed from the conversation, a 409 idempotency conflict — the loop throws
   before `removePendingMlsMessage`, so the entry stays queued forever and every
   subsequent flush dies on the same message. No later MLS message ever sends.
   Because MLS commits are ordered, this halts group membership changes and key
   rotation for that device permanently.

2. **Unhandled async exception.** `_startSync` calls it as
   `unawaited(_flushMlsOutbox())` (`:1297`). With no `catch`, the rejection has no
   handler and no `runZonedGuarded` wrapper exists in `main.dart` — so it surfaces
   as an uncaught Flutter error on every sync start once the queue is stuck.

`_processMlsRevocations` (`:1786-1808`) calls it again inside
`_catchUpSyncEvents`, so the same failure also triggers [L2](#l2)'s wedge.

**Why it matters in production**

This is the transport for group commits and device revocation. A stuck MLS outbox
means a revoked device is never actually removed from the group, which is a
security-relevant failure, not just a delivery one — the board's own model
(`docs/board.md`, "Revocation is pending, commit-submitted, then complete only
after every snapshotted active device confirms") depends on this queue draining.

**Fix**

Give it the same discipline `_flushOutbox` already has:

1. Wrap each iteration in `try`/`catch`.
2. Classify: 400/403/404/409/413/422 → terminal, remove from the queue and
   record it; 401 → clear session and stop; everything else → retryable with
   exponential backoff, exactly as `_recordOutboxFailure` does.
3. `continue` past a terminal entry so one bad message cannot block the rest.
4. Surface terminal MLS failures — unlike a text message, the user cannot see
   these, so they need an explicit state (e.g. "This device could not complete a
   security update").
5. Extend `pendingMlsMessages` storage with `attemptCount` / `nextAttemptAt` /
   `terminal` columns, mirroring the outbox table.
6. Independently: wrap `main()` in `runZonedGuarded` so no `unawaited` future can
   escape unlogged.

**Blocker:** **Yes.** Permanently stalls revocation and group membership.

**Related risks**

- Directly amplifies [L2](#l2): a stuck MLS message thrown from
  `_processMlsRevocations` wedges the whole catch-up loop.
- `_processMlsRevocations` itself has no error handling and calls
  `mls.createRevocationCommit` and `client.confirmMlsRevocation` unguarded.
- `_publishInitialMlsKeyPackages` (`:1774-1784`) is likewise unguarded; a failure
  there leaves the device with no published key packages and therefore
  unaddressable in new conversations, silently.

---

## L4

### Committed message returns 500 and then never fans out

**Severity:** High
**Location:** [`server/internal/messaging/service.go:34-52`](../server/internal/messaging/service.go#L34-L52), handler at [`server/internal/httpapi/conversation_handlers.go:422-447`](../server/internal/httpapi/conversation_handlers.go#L422-L447)

**Problem**

```go
stored, duplicate, eventID, err := s.repository.SaveMessageEnvelopeWithSyncEvent(ctx, envelope)
// ... envelope and sync event are now COMMITTED ...
recipients, err := s.repository.ListConversationMemberIDs(ctx, stored.ConversationID)
if err != nil {
    return CreateResult{}, err          // handler → 500 storage_error
}
```

If the recipient lookup fails after the commit, the handler returns 500. The
client's outbox treats 500 as retryable and re-posts with the same idempotency
key. `saveMessageEnvelope` finds the existing row and returns `duplicate: true`
— and the handler explicitly skips both fan-out paths on a duplicate:

```go
if !result.Duplicate {
    a.publishCommittedEvent(...)   // realtime
    a.notifyPush(...)              // push
}
```

So the message is stored, the durable sync event exists, and **neither realtime
delivery nor push wake ever fires for it** — not on the first attempt (which
errored before publishing) and not on any retry (which is a duplicate).

The comment on the error return says clients "still recover through sync
catch-up", which is true, but understates the cost: catch-up only runs on
WebSocket activity, a push wake, or app foreground. With no realtime event and no
push, none of those triggers fire for this message.

**Why it matters in production**

The recipient's phone stays asleep. The message is not delivered until something
*else* wakes the device — the next message from someone, a periodic foreground
resume, or the user opening the app. On a quiet one-to-one conversation that can
be hours. The sender sees a red "Send failed" bubble for a message that was in
fact stored and will eventually arrive, which is the most confusing possible
outcome: retrying appears to do nothing, and then the message shows up much later
on the other side.

**Fix**

The commit is the point of no return; treat it that way.

1. On recipient-lookup failure after a successful commit, return **201** with the
   stored envelope and log a warning. The message is durable; the response should
   say so.
2. Attempt the fan-out with the recipient list you can get. If it is empty,
   enqueue a deferred fan-out rather than dropping it.
3. Better: make the fan-out independent of the request. Have
   `SaveMessageEnvelopeWithSyncEvent` return the recipients from **inside the same
   transaction** (it already holds the membership rows for the
   `ErrNotMember` check at `message_store.go:69-75`), removing the second query
   and the window entirely.
4. Regardless of (1)–(3), make the duplicate path safe: on `duplicate: true`,
   still publish realtime and push if the caller can determine the event was not
   previously announced. Simplest correct version is (3), which removes the case.

**Blocker:** **Yes.** Non-deterministic delivery latency on the primary path.

**Related risks**

- Failure of `ListConversationMemberIDs` is most likely under SQLite writer
  contention or an exhausted reader pool, i.e. exactly under load.
- Same shape exists wherever a handler publishes after a commit and can fail in
  between; `conversationSubroute` calls `a.conversationMemberIDs(...)` post-commit
  in several places, though those log-and-continue rather than erroring, which is
  the correct behaviour and should be the model here.

---

## L5

### Expired-message sweeper drains only 500 rows per 6 hours

**Severity:** High
**Location:** [`server/internal/storage/message_store.go:483-530`](../server/internal/storage/message_store.go#L483-L530), scheduled at [`server/internal/app/app.go:229-282`](../server/internal/app/app.go#L229-L282)

**Problem**

`PruneExpiredContent` deletes at most 500 expired message envelopes per call:

```go
DELETE FROM message_envelopes WHERE id IN (
    SELECT id FROM message_envelopes
    WHERE expires_at IS NOT NULL AND expires_at <= ?
    ORDER BY expires_at, id LIMIT 500)
```

`runRetentionSweeper` calls `sweep()` on a **6-hour** ticker and does not loop.
Ceiling: 2,000 expired messages removed per day.

The same file gets this right elsewhere — `pruneEventRows` (`:582-605`) loops
until a page comes back short, with a 5 ms yield between batches. The message
prune simply does not.

**Why it matters in production**

Disappearing messages are a *promised privacy property*, not a housekeeping
nicety. A 30-person group with a 24-hour retention window generating 100
messages/day produces 100 expirations/day — fine. The same group at 3,000
messages/day produces 3,000 expirations/day against a 2,000/day ceiling, and the
backlog grows without bound. Ciphertext the user was told would be gone stays on
the server indefinitely, and the gap widens every day.

Because it degrades gradually and only under volume, it will not appear in
testing and will appear in production on the busiest instances — the ones where
it matters most.

Secondary effect: `expires_at`-filtered reads (`ListMessages`, `MessageByID`,
`messageCursor` all carry `expires_at > ?`) scan a table that keeps growing with
rows that should not exist, so the backlog also costs read performance.

**Fix**

Drain the backlog the way `pruneEventRows` already does:

```go
for {
    removed, keys, err := s.pruneExpiredContentPage(ctx, now)
    if err != nil || removed < 500 { return ... }
    // yield briefly so the single writer connection is not monopolised
}
```

1. Loop `PruneExpiredContent` until a page returns fewer than 500 rows, with the
   same 5 ms inter-batch sleep and `ctx.Done()` check.
2. Add a total-work ceiling per sweep (e.g. 50,000 rows) so one sweep cannot pin
   the writer indefinitely, and shorten the ticker to 1 hour so the ceiling is
   rarely reached.
3. Emit a metric for `expired_messages_pending` (a `COUNT(*) WHERE expires_at <= now`)
   so an operator can see a backlog forming. There is already an
   `httpMetrics` surface to hang it on.
4. Test: insert 1,200 expired envelopes, run one sweep, assert zero remain.

**Blocker:** **Yes.** The product makes a retention promise it cannot keep at
volume.

**Related risks**

- Compounded by [L6](#l6), which is in the same function.
- `PruneCallSessions` and `PruneOperationalRows` should be checked for the same
  single-page pattern.
- Each sweep contends for the single SQLite writer connection
  (`sqlite.go:91`), so the fix must yield between batches or it will stall writes
  for the duration.

---

## L6

### Attachment prune deletes blobs whose database rows survive

**Severity:** High
**Location:** [`server/internal/storage/message_store.go:490-522`](../server/internal/storage/message_store.go#L490-L522)

**Problem**

Three statements in the same transaction use **inconsistent `LIMIT` scopes**.

*Collect storage keys* — limits the inner query to 500 **messages**:

```sql
SELECT DISTINCT a.storage_key FROM attachment_envelopes a
JOIN message_attachments ma ON ma.attachment_id = a.id
WHERE ma.message_id IN (
    SELECT id FROM message_envelopes
    WHERE expires_at IS NOT NULL AND expires_at <= ? ORDER BY expires_at, id LIMIT 500)
```

*Delete attachment rows* — limits to 500 **(message, attachment) join rows**:

```sql
DELETE FROM attachment_envelopes WHERE id IN (
    SELECT ma.attachment_id FROM message_attachments ma
    JOIN message_envelopes me ON me.id = ma.message_id
    WHERE me.expires_at IS NOT NULL AND me.expires_at <= ?
    ORDER BY me.expires_at, me.id LIMIT 500)
```

*Delete messages* — limits to 500 **messages**.

Whenever expiring messages average more than one attachment, the join produces
more than 500 rows for fewer than 500 messages. So the second statement covers a
**strictly smaller set of messages** than the first and third.

Concretely, with two attachments per message: messages 1–500 are deleted and all
~1,000 of their storage keys are enqueued for blob deletion, but only the
attachment rows belonging to messages 1–250 are removed. **The
`attachment_envelopes` rows for messages 251–500 survive while their blobs are
deleted from disk.**

`parseAttachmentIDs` allows up to 20 refs per message (`:146`), so the skew can
be far worse than 2×.

**Why it matters in production**

Three visible consequences:

1. **Dangling downloads.** `AttachmentForAccount` still returns the surviving
   row, `serveEncryptedBlob` calls `LocalStore.Open`, the file is gone, and the
   client gets `blob_not_found`. The attachment is listed but permanently broken.
2. **Quota drift.** `enforceBlobQuota` (`content_store.go:611-628`) sums
   `size_bytes` from `attachment_envelopes`. Orphaned rows keep counting against
   the user's 1 GiB and the instance's 10 GiB even though the bytes are gone. Over
   time users are refused uploads for space that is not in use.
3. **Deletion-queue churn.** The orphan reaper later re-enqueues these same keys
   for deletion. `LocalStore.Delete` maps `os.IsNotExist` to `nil` (`local.go:202`)
   so it does not loop forever — but only by luck, not design.

**Fix**

Make all three statements operate on one explicitly materialised message set:

1. Select the 500 expiring message IDs **once** into a temp table or a Go slice.
2. Drive the storage-key collection, the attachment-row delete, and the message
   delete from that same set.
3. Assert the invariant in a test: create 500 expiring messages with 3
   attachments each, run one prune, and assert that
   `COUNT(*) FROM attachment_envelopes` referencing those messages is zero **and**
   that the enqueued key count matches.
4. Add a consistency check to `messenger-server doctor`: report
   `attachment_envelopes` rows whose blob is missing on disk. That turns this
   class of bug into an operator-visible signal rather than a user-visible 404.

**Blocker:** **Yes.** Silent divergence between the database and the blob store.

**Related risks**

- Depends on [L5](#l5): the more the backlog grows, the more often a full 500-row
  page is processed and the more skew accumulates.
- The orphan-reaper branch immediately below (`:539-557`) uses a consistent scope
  and is correct — it is a good model for the fix.

---

## L7

### `resetOnError: true` silently destroys the local database key

**Severity:** High
**Location:** [`mobile/lib/storage/local_store.dart:511-518`](../mobile/lib/storage/local_store.dart#L511-L518)

**Problem**

```dart
_storage = storage ?? const FlutterSecureStorage(
      aOptions: AndroidOptions(resetOnError: true),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    ),
```

`resetOnError: true` instructs `flutter_secure_storage` to **wipe all stored
values** when it cannot decrypt them, rather than propagating the error. The only
long-lived value stored there is `veritra.database_key.v1` — the 256-bit key for
the entire encrypted local database.

Android Keystore entries do become unreadable in practice: after certain OS
upgrades, after a device-to-device transfer or restore, after biometric
enrolment changes on some OEM builds, and after Keystore corruption. When that
happens, the key is silently regenerated, the existing encrypted database can no
longer be opened, and the user has lost — with no prompt, no error and no
warning:

- the session token **and the device secret**, which per
  [`ui-issues.md` U3](ui-issues.md#u3) is the only credential that makes
  password sign-in possible;
- all MLS group state and the rollback counter;
- the queued outbox (messages typed but not yet sent);
- the cached conversation and message history.

The iOS side is configured correctly (`first_unlock_this_device` is device-bound
and excluded from iCloud backup). Android is the exposed case, and
`android:allowBackup="false"` in the manifest means there is no backup to restore
from either.

**Why it matters in production**

This directly contradicts decision **D01**, recorded on the board as: *"Keep a
random 256-bit hex key in device-bound `flutter_secure_storage`; **fail closed**
on cipher or key-check failure."* `resetOnError: true` is the definition of
failing open — it discards the failure and the data with it.

The user experience is: open the app, be signed out, be unable to sign in
(password + device secret required, secret gone), and be told nothing about why.
The only path forward is to re-link from another device or use a fresh invite —
and if this was their only device, there is no path forward at all.

**Fix**

1. **Set `resetOnError: false`** (the default) and handle the read failure
   explicitly.
2. On an unreadable key, fail closed with a dedicated recovery screen that states
   plainly what happened ("This device's secure storage could not be read. Your
   local data cannot be recovered.") and offers the two real options: link this
   device again from another device, or start over.
3. Only wipe the encrypted database file **after** the user acknowledges, and do
   it explicitly rather than as a side effect of a storage-plugin flag.
4. Confirm the Android backend in use — pin `encryptedSharedPreferences: true`
   explicitly in `AndroidOptions` rather than relying on the plugin's default,
   so a future dependency bump cannot change the storage substrate silently.
5. Wire card **I18**'s encrypted backup/recovery into a user-facing flow (see
   [nice-to-haves.md](nice-to-haves.md)) so there is a recovery path that does not
   depend on a second device being available. That capability already exists on
   the server; it is unreachable from the client.

**Blocker:** **Yes.** Unbounded silent local data loss, and it contradicts a
recorded approved decision.

**Related risks**

- Interacts with [L1](#l1): both destroy queued messages, and neither says so.
- Amplified by the absence of a client backup/restore UI ([F14](audit-plan.md)),
  which is the mitigation this failure mode is supposed to have.
- Should be explicitly listed in the **I25** review brief as a failure case; the
  brief already lists "wrong local database key" under mandatory failure cases,
  and this is the mechanism that produces one.

---

## L8

### Unbounded client paging loops with no iteration cap

**Severity:** Medium
**Location:** [`mobile/lib/core/api_client.dart:114-134`](../mobile/lib/core/api_client.dart#L114-L134) (`conversations`), [`:136-155`](../mobile/lib/core/api_client.dart#L136-L155) (`devices`)

**Problem**

```dart
while (true) {
  final json = await _jsonRequest('GET', path, token: token);
  final page = ...;
  result.addAll(page);
  if (page.length < pageSize) return result;
  before = page.last.id;
}
```

No iteration cap, no total-result cap, no cursor-progress assertion. Termination
depends entirely on the server eventually returning a short page and on the
cursor strictly advancing. If a cursor is ever misinterpreted server-side, or a
duplicate ID appears, or a boundary condition returns the same full page twice,
the client loops indefinitely — hammering the server as fast as the network
allows, from a background task the user cannot see or stop.

There is also no memory bound: `result` accumulates every conversation the
account has ever been in.

**Why it matters in production**

A client-side infinite request loop is a self-inflicted denial of service against
the user's own server, and it drains the battery of the device running it. The
server's 240-requests-per-minute general rate limit throttles it but does not
stop it — the loop simply spins on 429s, which are not handled here at all.

**Fix**

1. Cap iterations (e.g. 50 pages = 5,000 conversations) and stop with a logged
   warning past it.
2. Assert cursor progress: if `page.last.id` equals the previous cursor, break.
3. Handle a non-2xx mid-loop by returning what has been collected so far rather
   than throwing away the whole result.
4. Reconsider whether the chat list needs *all* conversations eagerly. The local
   cache only keeps 20 (`local_store.dart:528`), so paging thousands into memory
   to persist 20 is wasted work — page lazily as the list scrolls.

**Blocker:** No.

**Related risks** — same shape should be checked in any other `while (true)`
paging helper in `api_client.dart`.

---

## L9

### Catch-up does one sequential round trip per repaired message

**Severity:** Medium
**Location:** [`mobile/lib/core/app_state.dart:1461-1463`](../mobile/lib/core/app_state.dart#L1461-L1463), `_repairMessage` at `:1578-1604`

**Problem**

```dart
for (final messageId in messageRepairIds) {
  await _repairMessage(messageId);
}
```

`messageRepairIds` accumulates **every** `message.envelope.*` event across every
page of the entire catch-up before any repair runs. Each repair is a separate
`GET /api/v1/messages/{id}`, executed strictly serially.

A device offline for a week in an active group returns to hundreds or thousands
of IDs and therefore that many sequential HTTP round trips. At a realistic 80 ms
each, 1,000 messages is 80 seconds of catch-up during which the app is marked
offline and `_catchingUpSync` blocks every other sync attempt.

`_repairMessage` also rebuilds the entire `messagesByConversation` map and
re-sorts the affected conversation's list **per message** (`:1585-1596`) — see
[`performance-issues.md` P8](performance-issues.md#p8).

**Why it matters in production**

"Open the app after a holiday and it hangs for a minute and a half showing
offline" is the single most visible reliability symptom a messenger can have, and
it lands on exactly the users who most need catch-up to work.

**Fix**

1. Add a batch endpoint — `GET /api/v1/messages?ids=a,b,c` (bounded, e.g. 100
   per request) — and fetch in chunks. The server already has
   `MessageForAccount`; a batched variant with the same membership and block
   filtering is a small change.
2. Interim, without a server change: run repairs with bounded concurrency (6–8 in
   flight) instead of strictly serially.
3. Bound the repair set per pass (e.g. 500) and continue on the next pass, so a
   very long absence produces incremental progress rather than one long stall.
4. Show progress. `_catchingUpSync` already exists; expose it so the UI can say
   "Catching up…" rather than "offline".

**Blocker:** No — degraded experience, not incorrect.

**Related risks** — worsens [L2](#l2): the longer the pass, the more likely it
hits a poison event.

---

## L10

### Quota rejection (507) is retried forever

**Severity:** Medium
**Location:** [`mobile/lib/core/app_state.dart:1735`](../mobile/lib/core/app_state.dart#L1735)

**Problem**

```dart
final terminal = error is ApiException &&
    <int>{400, 403, 404, 409, 413, 422}.contains(error.statusCode);
```

The server returns **507 Insufficient Storage** with
`storage_quota_exceeded` when an account exceeds its 1 GiB blob quota or the
instance exceeds 10 GiB (`content_store.go:611-628`, surfaced by
`handleStorageError` at `api.go:399-401`). 507 is not in the terminal set, so it
is classified retryable and re-attempted with exponential backoff — capped at
`1 << 8` = 256 seconds. The entry never leaves the queue.

**Why it matters in production**

A quota is not transient. The client will re-attempt roughly every four minutes,
indefinitely, until a human deletes something — burning battery and requests, and
occupying an outbox slot that (per [L1](#l1)) can evict a *different* user
message. The user sees a permanent "Sending…" or "retrying" state with no
explanation, when the actual cause is one they can act on.

**Fix**

1. Add `507` to the terminal set.
2. Give it a real message. `ApiException.message` has no case for
   `storage_quota_exceeded`, so it currently falls through to "The server
   rejected the request. Check your input and try again." — actively misleading.
   Add: *"This server is out of storage for your account. Delete older
   attachments or ask the admin for more space."* (See
   [`ui-issues.md` U14](ui-issues.md#u14).)
3. While there: `429` is correctly retryable, but the code ignores the
   `Retry-After` header the server sets (`app.go:586`, `auth_handlers.go:257`).
   Honour it instead of the local exponential backoff.

**Blocker:** No.

---

## L11

### Unchecked casts throw `TypeError` instead of `ApiException`

**Severity:** Medium
**Location:** [`mobile/lib/core/api_client.dart:944`](../mobile/lib/core/api_client.dart#L944) and the surrounding `_sessionFromAuthJson`

**Problem**

```dart
return Session(
  baseUrl: baseUrl,
  token: json['token'] as String,     // hard cast
  ...
);
```

Also `_jsonRequest`'s final line: `Map<String, Object?>.from(jsonDecode(text) as Map)`.

If a response is well-formed JSON but structurally unexpected — an
intercepting proxy, a captive portal returning an HTML-ish JSON error, a version
skew where a field moves — the cast raises `TypeError`, not `ApiException`.

Every error-handling path in `AppState` is written around `ApiException`:
`_run`/`_runScoped` check `err is ApiException && err.statusCode == 401`,
`_recordOutboxFailure` classifies by `statusCode`, and `describeError` produces
user copy from it. A `TypeError` bypasses all of that and surfaces as a raw
`"type 'Null' is not a subtype of type 'String'"` in the UI.

The rest of the client is careful about exactly this — `_decodeRequiredBytes`
(`:917-925`) converts a bad field into `ApiException(502, ...)`. The auth path
just missed it.

**Why it matters in production**

Captive portals and corporate proxies are the normal case on public Wi-Fi, and
sign-in is the flow most likely to be attempted there. A Dart type error shown to
a user is both unhelpful and unprofessional.

**Fix**

1. Route every response-shape violation through `ApiException(502, ...)`, as
   `_decodeRequiredBytes` already does. A small `_requireString(json, 'token')`
   helper covers the whole file.
2. Guard `jsonDecode` in `_jsonRequest` with a `try` and a `FormatException`
   catch, and verify the decoded value is a `Map` before casting.
3. Add a `Content-Type` check: if the response is not `application/json`, fail
   with a distinct code so the "you are behind a captive portal" case can get its
   own message.

**Blocker:** No.

---

## L12

### `_flushOutbox` has no re-entrancy guard

**Severity:** Medium
**Location:** [`mobile/lib/core/app_state.dart:1696`](../mobile/lib/core/app_state.dart#L1696)

**Problem**

`_catchUpSyncEvents` guards itself with `_catchingUpSync` / `_catchUpRequested`
(`:1400-1409`) — a correct coalescing pattern. `_flushOutbox` has no equivalent.
It is invoked from `_startSync` and from retry paths; two concurrent invocations
both call `localStore.pendingEnvelopeRecords()`, both iterate the same records,
and both `POST` the same envelopes.

Server-side idempotency keys prevent duplicate storage, so this is not a
correctness bug at the message level. Client-side, though, both flushes then call
`_recordOutboxFailure` or `_removeFromOutbox` on the same key, double-incrementing
attempt counters and racing on `_outboxStates` and `pendingOutbox` list rebuilds.

**Why it matters in production**

Doubled attempt counts push entries into terminal state or long backoff sooner
than intended, and doubled requests eat the auth rate-limit budget. Under a
reconnect flap (which is when flushes fire most often) both effects compound.

**Fix**

Apply the same `_flushingOutbox` / `_flushRequested` coalescing pattern already
proven in `_catchUpSyncEvents`. Same for `_flushMlsOutbox` when fixing
[L3](#l3).

**Blocker:** No.

---

## L13

### Typing throttle map grows unbounded and rescans on insert

**Severity:** Low
**Location:** [`server/internal/httpapi/conversation_handlers.go:357-377`](../server/internal/httpapi/conversation_handlers.go#L357-L377)

**Problem**

```go
a.typingLast[key] = now
if len(a.typingLast) > 10_000 {
  cutoff := now.Add(-time.Minute)
  for item, last := range a.typingLast {
    if last.Before(cutoff) { delete(a.typingLast, item) }
  }
}
```

Two issues. The cleanup only removes entries older than one minute, so if more
than 10,000 `(account, conversation)` pairs are actively typing within any
one-minute window the map never shrinks and keeps growing. And once past the
threshold, **every** typing request performs a full O(n) scan of the map while
holding `typingMu` — so cost grows with size at exactly the point size is a
problem.

**Why it matters in production**

Unbounded memory plus a serialised O(n) scan on a hot, adversarially-triggerable
endpoint. The 2-second per-key throttle limits an individual attacker, but an
account in many conversations can create many keys cheaply.

**Fix**

Replace with a periodic sweeper on a ticker (the pattern
`rateLimiter.cleanupLoop` at `app.go:533-550` already uses), or a small
fixed-capacity LRU. Both remove the growth and the per-request scan.

**Blocker:** No.

---

## L14

### `parseTime` silently yields the zero time

**Severity:** Low
**Location:** [`server/internal/storage/sqlite.go:707-713`](../server/internal/storage/sqlite.go#L707-L713)

**Problem**

```go
func parseTime(value string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, value)
	if err != nil { return time.Time{} }
	return t
}
```

The error is discarded. Any unparseable timestamp becomes `0001-01-01T00:00:00Z`
and flows into API responses as a real value.

Today this is latent rather than active: all migrations were checked and none use
`CURRENT_TIMESTAMP` or `datetime()`, so every timestamp is written by `formatTime`
in a matching format. The risk is a restored database from an older format, a
hand-edited row, or a future migration adding a SQL-side default.

**Why it matters in production**

A zero timestamp sorts first everywhere. In the chat list it would pin a
conversation to the bottom permanently; in pagination cursors it would break
`before`/`after` ordering. And because it is silent, the cause would be very hard
to find from the symptom.

**Fix**

Return `(time.Time, error)` and let callers decide, or at minimum log once per
occurrence with the column name. Add `RFC3339` (second precision) as a fallback
parse before giving up. Add a `messenger-server doctor` check for zero-valued
timestamps in the main tables.

**Blocker:** No.

---

## L15

### Non-null assertion depends on a distant condition

**Severity:** Low
**Location:** [`mobile/lib/core/app_state.dart:1459`](../mobile/lib/core/app_state.dart#L1459)

**Problem**

```dart
if (refreshSelectedMessagesNeeded) {
  await refreshSelectedMessages(notify: false);
  await markNewestMessageRead(selectedId!);
}
```

`selectedId!` is safe **only** because `refreshSelectedMessagesNeeded` can only
be set inside branches guarded by `event.conversationId == selectedId` with a
non-null `event.conversationId` — a chain of reasoning three nested blocks and
~30 lines away.

**Why it matters in production**

It is correct today and will not survive a refactor. Any new code path that sets
`refreshSelectedMessagesNeeded` without that guard produces a null-check crash in
the background sync loop, which — per [L2](#l2) — wedges sync for that device.

**Fix**

```dart
final target = selectedId;
if (refreshSelectedMessagesNeeded && target != null) {
  await refreshSelectedMessages(notify: false);
  await markNewestMessageRead(target);
}
```

Cheap, and removes the dependency on distant reasoning.

**Blocker:** No.

---

## L16

### Trailing slashes 404 on subroute handlers

**Severity:** Low
**Location:** [`server/internal/httpapi/conversation_handlers.go:44`](../server/internal/httpapi/conversation_handlers.go#L44) and `:170`

**Problem**

`communitySubroute` and `conversationSubroute` split the path without trimming a
trailing separator:

```go
parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/v1/communities/"), "/")
```

`/api/v1/communities/abc/members/` yields `["abc", "members", ""]` — length 3, no
branch matches, 404. Meanwhile `deviceLinkSubroute` (`auth_handlers.go:614`) and
`attachmentSubroute` (`content_handlers.go:105`) *do* trim, so the behaviour is
inconsistent across the API.

**Why it matters in production**

Trailing slashes are added routinely by proxies, API clients, and copy-paste. An
API that returns 404 for a URL that differs only by a trailing separator is a
support burden and is inconsistent with its own other endpoints.

**Fix**

Apply `strings.Trim(..., "/")` uniformly, matching the handlers that already do
it. Add a contract test asserting both forms resolve identically.

**Blocker:** No.

---

## L17

### WebSocket drain sends no close frame

**Severity:** Low
**Location:** [`server/internal/realtime/hub.go:141-152`](../server/internal/realtime/hub.go#L141-L152) and [`server/internal/realtime/websocket.go:79-115`](../server/internal/realtime/websocket.go#L79-L115)

**Problem**

`Hub.Drain()` calls `client.Close()`, which closes the send channel; the serve
loop sees `!ok` and returns, and the deferred `conn.Close()` drops TCP. No
WebSocket Close frame (opcode `0x8`) is ever written. The code can write pong
frames (`writePongFrame`) but has no close-frame writer at all.

**Why it matters in production**

Clients see an abnormal closure (`1006`) and cannot distinguish "the server is
restarting, come back shortly" from "the network died". Every connected client
therefore enters full reconnect backoff on a planned restart. On a
single-instance deployment where every client is on that one server, a routine
upgrade produces a synchronised reconnect storm at the end of the backoff window
— which, per [`performance-issues.md` P4](performance-issues.md#p4), is the
worst case for `Hub.Register`.

**Fix**

1. Add `writeCloseFrame(w, code, reason)` and send `1001 going away` before
   closing during drain. Signal it through the client (a `closing` flag or a
   sentinel on the send channel) so the serve loop writes it.
2. Client side: treat `1001` as an immediate short-delay reconnect with jitter
   rather than full backoff.
3. Add jitter to reconnect regardless, so a hard restart does not produce a
   synchronised herd.

**Blocker:** No.

---

## L18

### Rust release profile does not pin `panic` or enable overflow checks

**Severity:** Low
**Location:** [`crypto/rust/Cargo.toml`](../crypto/rust/Cargo.toml) — no `[profile.release]` section

**Problem**

`ffi.rs:49` correctly wraps every FFI entry point:

```rust
match catch_unwind(AssertUnwindSafe(operation)) { ... }
```

This is the right pattern — a Rust panic unwinding across a C ABI boundary is
undefined behaviour, and `catch_unwind` prevents it. But it **only works under
`panic = "unwind"`**. Under `panic = "abort"` the process dies instead.

`Cargo.toml` declares no `[profile.release]`, so the crate relies on the
compiler default. `panic = "abort"` is a common size optimisation for Android
builds and could be introduced by a profile change, a workspace-level setting, or
a build flag in `scripts/build-mobile-crypto.sh` — silently disabling the entire
protection with no compile error and no test failure.

Separately, `overflow-checks` defaults to off in release. For a crypto library
handling length-prefixed buffers, on is the safer default.

**Why it matters in production**

The board lists "ABI ownership/panic failures" as a mandatory review case for
**I25**. Making the guarantee explicit in the manifest is what makes it
reviewable — right now a reviewer has to verify a compiler default rather than
read an intent.

**Fix**

```toml
[profile.release]
panic = "unwind"        # catch_unwind at the C ABI depends on this
overflow-checks = true  # crypto buffer arithmetic
```

Add a comment stating the dependency, and a CI assertion that the built
`cdylib` was compiled with unwind (or simply a test that a deliberate panic
inside an FFI call returns the error code rather than aborting — the ABI
lifecycle test in `ffi.rs` is the natural home).

**Blocker:** No — but it should be in the I25 brief.

---

# Production blockers

Must be fixed and verified before any production release. Ordered by the sequence
in which they should be tackled.

### Client-side data integrity

- [ ] **[L1](#l1)** — Outbox stops silently deleting the oldest queued messages.
      *Verify:* a test enqueuing `maxEntries + 1` asserts the first entry
      survives and the enqueue was refused with a visible error.
- [ ] **[L7](#l7)** — `resetOnError: false`; unreadable key fails closed with a
      recovery screen. *Verify:* injected keystore read failure produces the
      recovery screen, not a silent wipe. Restores compliance with **D01**.

### Client-side sync liveness

- [ ] **[L2](#l2)** — Poison sync events are skipped and the cursor advances.
      *Verify:* tests for a payload missing its ID field and for a referenced
      message returning 404; catch-up completes in both.
- [ ] **[L3](#l3)** — MLS outbox classifies failures and cannot head-of-line
      block. *Verify:* a permanently-4xx MLS message becomes terminal and later
      messages still send. Also add `runZonedGuarded` in `main.dart`.
- [ ] **[L12](#l12)** — `_flushOutbox` re-entrancy guard (fix alongside L3).

### Server-side data integrity

- [ ] **[L5](#l5)** — Expiry sweeper drains its backlog. *Verify:* 1,200 expired
      envelopes are all removed by a single sweep; add a pending-expiry metric.
- [ ] **[L6](#l6)** — Prune uses one consistent message set. *Verify:* 500
      messages × 3 attachments leaves no orphan `attachment_envelopes` rows;
      add the corresponding `doctor` check.
- [ ] **[L4](#l4)** — A committed message is acknowledged and always fans out.
      *Verify:* injected recipient-lookup failure still yields 201 and a
      published event.

### Cross-cutting verification once the above land

- [ ] Re-run `scripts/test.ps1` and `scripts/lint.ps1` on the pinned toolchains.
- [ ] Add the regression tests named above to CI — a fix without a test will not
      survive the next refactor of these files.
- [ ] Record the results in the board's release-evidence matrix bound to a
      commit, per the existing process.

### Deliberately **not** listed as blockers

[L8](#l8)–[L18](#l18) are real and should be scheduled, but none of them lose
data, wedge a device, or break a release guarantee. They belong in the first
maintenance cycle, not the launch gate.
