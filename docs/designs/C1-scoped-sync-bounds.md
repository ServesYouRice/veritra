# C1: per-conversation sync bounds and the client-cursor plan

**Status: proposed (2026-11-07), not built.** Decides the open point in
STATE.md C1: "Bounds are still account-wide; decide per-conversation bounds
before a client uses them". It applies to the scoped routes behind
`PRIVATE_MESSENGER_SCOPED_SYNC`
(`server/internal/httpapi/scoped_sync_handlers.go`,
`server/internal/storage/scoped_sync_store.go`). Read it with
[C1-sync-isolation](C1-sync-isolation.md) and [C1-progress](C1-progress.md).
It touches MLS ordering and sync, so it needs an independent review before
code.

## The problem

Both scoped routes return `SyncBounds(account)`:

- the server-wide `sync_epoch`;
- the account's `oldest_event_id`;
- `latest_event_id`, the newest event over every membership.

That is not a scope's progress. A conversation client that read it as "the
end of this conversation" would refetch forever or stop early.

What clients use today:

- **The legacy app** reads `latest_event_id` in one place, the D70 leave
  floor fallback (`ApiClient.syncLatestEventId`).
- **`oldest_event_id`** is read by no client.
- **Expiry** is decided on the server (409), from the prune marks.

There is also no way to know which conversations have new events without
asking each one. D38 allows up to 1,000 conversations per account.

## Decision

1. **Per-scope bounds in the scoped envelopes.** These are envelope changes
   only, with no migration. The routes are off by default and no client
   calls them yet, so they can change now without a compatibility path.
   - **`scope_head`** is the highest event id this stream would scan for
     this device. The name is deliberately new, because the legacy
     `latest_event_id` means something else and the app already parses it.
     The rows it covers:
     - **account scope:** the account's rows with no conversation,
       addressed to every device or to this one;
     - **conversation scope:** that conversation's shared rows, plus the
       account's own rows for it (the Welcome), as `ListConversationSyncEvents`
       selects them.

     It counts hidden rows (join filter, blocks, dead envelopes). It is one
     index probe per scope: `MAX(id)` on `idx_sync_events_conversation` or
     `idx_sync_events_account`. It never walks a hidden run.
   - **`scanned_through`** is the highest id the server examined for this
     page, hidden rows included.
     - The account scope has no hidden rows, so it equals the last event
       returned.
     - A full conversation page stops right after its last visible event,
       so it equals that event.
     - A short page scanned to the end, so it equals the head at the read.

     The client may advance its cursor to `scanned_through`, so a hidden
     run is crossed once instead of being scanned again on every pass.
   - **`sync_epoch`** stays as it is: a change remains a device-wide
     recovery condition.
   - **`oldest_event_id` and `latest_event_id` are removed** from scoped
     envelopes and 409 bodies.
     - No client reads `oldest_event_id`.
     - A per-conversation oldest bound would have to walk expired messages
       at the old end (the `syncBoundsQuery` comment explains why the
       legacy one skips that).
     - Expiry stays the server's 409.
   - **Order of reads.** Heads and `scanned_through` are read in the same
     statement as the page, or after it, never before. So a client never
     believes it is caught up while a newer event exists.
2. **A discovery route.** `GET /api/v1/sync/heads?since=<id>`, behind the
   same switch.
   - **Response:** `{sync_epoch, account_head, conversations:
     [{conversation_id, scope_head}], watermark}`, with only the current
     memberships whose head is above `since`.
   - **`watermark`** is the highest id the server has issued that this
     account can be shown: the maximum of the heads. The client passes it
     as the next `since`.
   - **Cost:** one index probe per membership, the same order as the legacy
     `syncVisibleLatestExpr` on every legacy page, but without its
     visibility walk.
   - **Paging:** at most 1,000 memberships (D38), so the route answers one
     page. If D38 is raised, the route pages by conversation id.
   - **Leaks:** nothing new. A member already sees these ids by reading the
     stream. Event ids are global and monotonic in every response today.
3. **Caught up**, per scope: `cursor >= scope_head`. A conversation has work
   when `heads.scope_head > cursor`. A realtime event carries `id` and
   `conversation_id` (`realtime.Event`), so while connected the client
   raises that conversation's known head without a heads call.

### Why not the alternatives

| Option | Why not |
|---|---|
| Keep account-wide bounds, and the client ignores them | Works only by polling every conversation's stream each pass (up to 1,000 requests), and leaves a misleading field in the envelope |
| Per-scope **visible** latest (the stream's own predicate) | Exact, but walking back to the newest visible row crosses whole hidden runs. A device waiting for its Welcome in a busy group walks that group's history on every call. Heads plus `scanned_through` reach the same end cheaply |
| Activity marker events in the account stream | An extra write per message and a second ordering to keep correct |

## Constraints the review must check

- **Unblocking.** `scanned_through` is safe only for rows that stay hidden
  from this device.
  - **Rows that stay hidden.** Join-filter rows do:
    - `joined_after_event_id` only grows;
    - events between a removal and a re-add stay outside.

    Expired and deleted envelopes stay hidden too.
  - **Block-hidden rows do not** (`syncEventBlockedFor` reads the current
    block).
  - **The difference from legacy:**
    - **Legacy**, after an unblock, delivers a block-hidden *tail* that no
      later visible event has passed yet.
    - **Scoped**, with `scanned_through`, never delivers it.
    - Both skip block-hidden rows once a later visible event has moved the
      cursor.

    Blocks hide messages, reactions, receipts and calls, never MLS
    handshake messages, so no group state is lost.
  - **Proposed:** accept it. A block means "I do not want these", and the
    legacy behaviour is already "sometimes".
  - **The alternative** is to advance only past join-filter and
    dead-envelope rows, by returning `scanned_through` only up to the first
    block-hidden row. It costs one more flag per row.
- **Commit order.** `since` and `scanned_through` assume that ids become
  visible in commit order. SQLite's single writer gives that, and the
  legacy cursor relies on it too.
  - **Any future PostgreSQL backend** (AGENTS.md) must keep it. Possible
    ways: a sequence assigned under the account's lock, or reading only up
    to the oldest id still in an open transaction.
  - **Write this into the storage interface's contract.**
- **No leave-floor fallback.** After a leave, the conversation route answers
  403, so a scoped client cannot read a head for it.
  - A scoped client takes the D70 leave floor only from the leave
    response's `event_id` (#106).
  - It treats a server that omits it as one without scoped support.
  - Scoped mode has no `latest_event_id` fallback.
- **The conservative expiry stays.** C1-progress owner question 2 is still
  open: split account prune marks by conversation (a migration), or accept
  that a pruned account event also pauses conversation cursors older than
  it. This decision does not settle it.
  - **Observed effect:** the pause hits only a conversation cursor that is
    behind a pruned account event while the account cursor is not.
  - **That is rare,** because a paused or rarely read conversation is the
    only way to get there.

## Client-cursor plan

It follows [C1-sync-isolation](C1-sync-isolation.md), "Local model and
atomic commits", with these bounds.

1. **Capability.** The client uses scoped sync only when the heads route
   answers. It answers 404 while the switch is off. The leave response must
   also carry `event_id`; otherwise the client stays on the legacy stream.
   Legacy and scoped devices of one account coexist, because the streams
   are views over the same rows.
2. **Local schema.** This plan, not K1, takes the next free local schema at
   landing (19 today).
   - **Tables:**
     - `sync_scope_cursors(scope, scope_id, applied_through, server_epoch)`;
     - `conversation_sync_recovery` (as in the isolation design);
     - a migration marker holding the old global cursor `G` and the
       protocol version.
   - **The account cursor** stays in the existing cursor slot. It now means
     "account stream applied".
3. **Migration.**
   - In one transaction, record `G`.
   - Each conversation's cursor defaults to `G` the first time it is seen.
     Every event visible before `G` was handled by the legacy stream.
   - An existing global recovery with a valid conversation id becomes that
     conversation's recovery.
   - A downgrade after this migration is refused.
4. **A pass.**
   - Drain the account stream.
   - Call heads with the stored watermark.
   - Do round-robin pages over unpaused conversations where
     `scope_head > cursor`, each page under the existing lease and `_serial`.
   - On startup and after any membership event in the account stream, call
     heads with `since=0`.
5. **Advancing a cursor.**
   - **A page with events:** the last event's atomic `ScopedMlsTransition`
     sets the cursor to `max(last event, scanned_through)`.
   - **An all-hidden page:** a cursor-only, no-ratchet write that checks the
     expected cursor and that no recovery record exists.
   - **Never past a failed event.** A conversation never advances while
     paused.
6. **Errors.**
   - **409 `conversation_recovery_required`:** pause that conversation and
     show its notice. Never relink the device.
   - **409 `device_recovery_required`** on the account scope, or a changed
     `sync_epoch`: device-wide, as today.
   - **403 on a conversation:** drop it from the schedule. The account
     stream's leave or removal notice settles the local state.
7. **Fairness.** At most one page per conversation per round, and a round
   ends after a time budget. A busy or failing group cannot starve the
   others (isolation design, "Required evidence").

## Packages and counters

Counters are the next free ones at landing.

| Step | Work | Counter | Route |
|---|---|---|---|
| C1-B1 Server bounds | Per-scope `scope_head` and `scanned_through`, remove the account bounds from scoped envelopes, heads route behind the switch, tests (head equals the stream's last scanned row; hidden tail crossed once; heads `since`; order of reads under a concurrent insert) | none (no migration) | Opus review |
| C1-B2 Client model | Pure scheduler and cursor model with fake streams and an in-memory transactional store | none | Sonnet, Opus review |
| C1-B3 Client storage | The tables, the `G` migration, recovery conversion, downgrade refusal | **local schema +1** | Opus review |
| C1-B4 Integration | `ScopedMlsTransition`, `app_state.dart` wiring, the native two-group poison test | none | Opus review (MLS ordering) |

## Open questions for the owner

1. **Unblock semantics.** Accept that a block-hidden tail skipped by
   `scanned_through` is not delivered after an unblock (recommended), or
   pay for the narrower advance?
2. **Prune marks.** Carried from C1-progress question 2: split account
   prune marks by conversation (a migration), or accept the conservative
   pause (recommended until a false pause is seen)?
3. **Ownership.** Who owns `app_state.dart`, `local_store.dart` and the
   local schema number for C1-B3 and C1-B4 once K2 releases them? Carried
   from C1-progress question 3.
