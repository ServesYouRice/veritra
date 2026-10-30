# C1 prerequisite: isolate MLS failures by conversation

Design proposal, 2026-10-26. Not implemented or approved. Independent security
review must precede the cursor, migration and recovery changes. D51 permits
clear channel IDs, while content/names stay encrypted. This design addresses
the C1 prerequisite recorded in [C0](C0-community-groups.md); it does not
change the production release gate.

## Decision proposed

Use an account event stream and independent conversation event streams, each
with its own durable cursor. Keep **one** device-wide, sealed MLS provider
snapshot and its monotonically increasing counter. Native operations remain
serialized; they do not become parallel crypto workers.

A failure freezes only its conversation cursor and outbound MLS work. Other
conversation streams continue. No failed ciphertext is marked processed,
dropped or retried automatically in a loop. No earlier provider snapshot is
restored after another conversation has advanced.

### Why the current transaction cannot simply skip an event

`MlsStateTransition`, `SyncEventCommit` and their encrypted-database methods
compare one global cursor. Incoming crypto commits require the new cursor
to be greater than that cursor. `NativeCryptoService` rejects an incoming
event already behind it. `_runOwnedCatchUp` saves one `SyncRecovery`, then
stops all work whenever that record exists. All MLS groups live in the same
sealed provider snapshot.

Advancing the current cursor past a poisoned event makes a later retry
impossible under these contracts. Saving a whole pre-failure snapshot to
restore during that retry would roll back unrelated groups. A bounded
global ciphertext inbox alone also fails the C1 goal: an admitted sender
can fill its quota and block further global intake. Separate server streams
avoid buffering the paused conversation's entire future traffic locally.

## Server contract

Add these routes without changing the legacy global route:

- `GET /api/v1/sync/account-events?after=<id>&limit=<1..200>`
- `GET /api/v1/conversations/{id}/sync-events?after=<id>&limit=<1..200>`

Responses retain `events`, `sync_epoch`, `oldest_event_id`,
`latest_event_id`; add `scope` (`account` or `conversation`) and
`scope_id`. Event IDs remain the existing monotonically increasing IDs.
Clients check scope, strict ID ordering and every event's scope before
processing. Existing response/body bounds and authentication apply.

The account route includes only events for the authenticated account whose
row has no conversation ID. This includes the targeted leave/removal notice
whose conversation is identified in its payload. It must not include MLS
Welcomes: those rows already carry their actual conversation ID.

The conversation route requires current membership and includes that
conversation's eligible shared events **and** account/device-targeted
events, including the recipient's Welcome. Reuse the current block filters,
device-targeted Welcome checks and MLS join/epoch visibility predicates.
Do not join only `account_id IS NULL`, which would lose Welcomes. Never use
the global account bounds to decide whether one conversation cursor expired.

Existing indexes cover `(account_id,id)` and `(conversation_id,id)`. Put the
new store methods in `server/internal/storage/conversation_sync_store.go`
and route adapters in a new scoped-sync handler file; retain common visibility
helpers in one place so the new routes cannot diverge from authorization.

### Retention and fresh joins

Persist a conservative per-scope retention floor in an additive
`sync_retention_floors(scope, scope_id, through_event_id)` table. In the same
transaction that prunes a batch of events, advance each affected scope's
floor to the highest deleted ID, then delete that batch. The account floor
applies only to its unscoped events; a conversation floor applies only to
that conversation. Floor checks use the device's authorized join position.
No reader infers that rows are missing merely from a gap between IDs.

An established stream behind its applicable floor receives 409 with a
scoped recovery reason; only that conversation pauses. A changed server
`sync_epoch` remains a device-wide recovery condition. Missing account-wide
security events also remain device-wide; this design isolates a member's
bad conversation traffic, not every account/server integrity failure.

For a fresh MLS membership with no local group state, the client explicitly
requests bootstrap from the recorded device join/Welcome position. It may
not use bootstrap to skip a failed established stream. The server must
retain/return the actual authorized Welcome or return scoped recovery; it
must never answer with current application ciphertext and pretend it is a
replacement Welcome. The exact floor/join predicate needs review against
the existing `mlsJoinFilterEventFor` helper before implementation.

The conservative floor can reject a stale device even when only hidden
events were pruned. This costs availability in that conversation rather
than allowing an unverifiable jump. A future per-device floor optimization
must not weaken this check.

## Local model and atomic commits

Add independently named tables/modules; use the next unallocated local
schema version after W8/K2, assigned by the coordinator:

| State | Required fields/invariant |
|---|---|
| Scope cursors | `(scope, scope_id)` primary key; `applied_event_id`, `server_epoch`; monotonically increasing within a scope |
| Conversation recovery | Conversation primary key; first failed event ID/type, reason, recorded time, bounded raw event/ciphertext if available, retry generation; no plaintext or key material |
| Migration marker | Protocol version plus the previous global cursor `G`; one atomic initialization, restart safe |
| Processed markers | Existing event-derived marker, with scope binding; a marker from another scope can never suppress an event |

Keep the account cursor in the existing cursor slot initially, minimizing
outgoing-state CAS changes. It now means **account stream applied**, not
"every conversation applied." Add a separate `ScopedMlsTransition` API;
do not loosen the old `cursor > expectedCursor` validation globally.

One successful conversation crypto transaction must atomically:

1. Hold the existing profile/sync lease; require the expected device-wide
   crypto counter, expected account cursor, and expected conversation cursor.
2. Require the event to belong to that scope, be the next pending event
   returned by its ordered stream, and not have a processed marker.
3. Write the next sealed global snapshot with counter exactly `previous+1`.
4. Apply decrypted effects, ciphertext cache changes and resolved outbox
   removal from that operation.
5. Add the processed marker and advance **only** that conversation cursor.
   Clear its recovery record only if this is the original failed event and
   its retry generation still matches.

Account cursor stays unchanged in this transaction. A stale CAS fails the
whole transaction; the crypto service restores from the current durable
state before retrying, under its existing `_serial` owner. Own echoes and
proven-expired tombstones use a scoped no-ratchet transaction that commits
the marker/effects/cursor together, without changing the crypto counter.

All existing outgoing/local mutations still CAS against the current global
counter and account cursor. They must additionally refuse sends, calls,
membership reconciliation, pending commit merges and self-updates for a
paused conversation. Existing queued ciphertext remains queued; it is not
discarded, regenerated or sent around the pause. Other groups' outboxes
continue. Account revocation polling may update metadata while a group is
paused, but cannot mutate that group's MLS state through a side path.

## Failure and retry

On native decryption/control failure, restore the operation's in-memory
state before releasing `_serial`, then durably write the first scoped
recovery record. The conversation cursor and all message projections stay
unchanged. Persisting recovery must not overwrite a newer recovery generation.
If storage itself fails or the lease is lost, halt intake device-wide;
there is no safe isolation without a durable boundary.

At most one failed raw event/ciphertext record is retained per paused
conversation; honor the existing maximum event/control/envelope sizes.
Do not fetch the rest of that stream while paused. There is no unbounded
quarantine queue and no promise that the server retains later events forever.
Scope limits follow existing conversation admission limits, not a new
unbounded attacker-controlled identifier map.

Retry is explicit and reuses the original event ID/type and conversation
cursor. It reads the latest device-wide snapshot, in which the paused
group's state has not changed but other groups may have advanced. If the
source changed at the same event ID, preserve the original failure record
and refuse silent substitution; a separately reviewed repair path must
decide how to authenticate a replacement. No “skip bad message” or automatic
group reset is introduced. Persistent failure leaves this conversation paused.

Unknown crypto event with a valid server-assigned conversation scope pauses
that scope. An event without a trustworthy scope, wrong account identity,
server epoch mismatch or storage failure keeps the device-wide halt. Successfully
decrypted invalid/unsupported application payloads retain W7's current
commit-and-placeholder behavior; this design changes only failures before
that successful commit.

## Migration and startup

Atomically record old global cursor `G` as the default conversation floor
and account cursor for the upgraded profile, with no crypto snapshot rewrite
or message deletion. Existing per-event markers remain. Any conversation
discovered later defaults to `G`: every event visible before that point was
already handled by the old global stream, while a truly later join has newer
IDs. Fresh enrollment/K2 restores use baseline zero and the fresh-join rules.

Convert an existing global recovery with a validated conversation ID into
that conversation's recovery, keeping its original failing event ID.
Retain device-wide recovery when scope is missing/unverifiable or the cause
is account epoch, unavailable crypto or local storage. Do not advance `G`
to the failing event during migration.

Startup discovers conversations from the authenticated list, drains account
events, then schedules bounded round-robin work over unpaused conversations.
One slow/failed group gets no monopoly. A newly seen Welcome triggers normal
key-package replenishment after its atomic commit. Current membership is
refreshed independently of paused message processing, so a leave/removal is
not hidden behind the very group it removes.

Downgrading to a client that only understands the old global cursor is
refused after migration; presenting the account cursor to that client would
allow replays or missing history. This is a local schema/protocol minimum,
not a production release-gate exception.

## Smallest safe parallel implementation slice

Before W8 finishes, a separate agent may implement **server-only scoped
read methods and their authorization/equivalence tests** in new disjoint
files, plus inactive routes after coordinator review. No client switches to
them yet; no current cursor semantics change. Retention-floor schema and
pruning require a separately reviewed migration and coordinator allocation.

The next slice is a pure scoped scheduler/model with fake streams and an
in-memory transactional test store in new modules. Integrating real storage,
native crypto and `app_state.dart` waits until W8/K2 relinquish those files.
One owner then implements the atomic transition end to end; another agent
reviews the diff independently.

## Required evidence

- A native two-group test: poison A, receive/decrypt/send in B, restart,
  then retry A without rolling back B's keys, counters, history or outbox.
- Crash/failure injection at every atomic write stage and stale counter/
  account cursor/conversation cursor/lease races; neither duplicate effects
  nor partial state/cursor advancement is possible.
- Strict ordering, own echoes, Welcomes, concurrent membership commits,
  expired application tombstones, invalid/unsupported payloads and unknown
  crypto types; paused-group sends/calls/reconcile stay blocked.
- Server scope equivalence under blocks, targeted Welcomes, removals,
  outsider reads, hidden runs, retention batches and sync-epoch changes.
- Malicious group flood does not grow local quarantine or starve B;
  quotas/cancellation/fair scheduling remain bounded.
- Existing global recovery conversion, migration failure rollback,
  newly discovered groups, K2 fresh identity and downgrade refusal.
- Scoped UI shows a conversation warning while account connection and B
  remain healthy; no content/keys/ciphertext appear in logs or diagnostics.
