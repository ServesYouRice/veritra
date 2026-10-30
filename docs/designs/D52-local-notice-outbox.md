# D52 local notification outbox

Reviewed coordinator/native-boundary design, 2026-10-29. Implementation pending.
This is private encrypted local state, never a server payload or history export.
It does not authorize subscription opt-in or open a release gate.

## Atomic capture

Allocate local schema15 after K2 schema14. Authenticated inbound application
commits may include a typed notice reference alongside state/cursor/history.
NativeCryptoService captures this option once per serialized operation. Capture
stays disabled until the current profile's verified opt-in registration; logout
invalidates the native permit before clearing private notification state.

Only successfully decoded new inbound text/reply/attachment inserts qualify.
Own-device echoes, own-account sibling messages, actions, unsupported/invalid/
sender-mismatch rows, restored history and hidden controls never enqueue.
References contain event ID, recipient account/device, message key, server
message ID, conversation/channel, authenticated sender IDs and creation/expiry
times. They contain no text, attachment manifest/key, ciphertext or token.
The transaction checks that its actual committed row still matches the reference
identity, context, server ID, kind and timestamps. Duplicate inserts/events do
not create another reference. Failure, quota or permit revocation rolls back
reference, ratchet, cursor, marker and history together.

Keep immutable per-event references. Two latest-message/mention pointers are
insufficient: a newer mention can later be edited/deleted and hide an earlier
eligible mention. Prune only beyond the ten-minute notification freshness
window (or expired message), with an explicit bounded reference count/byte cap.
A cap failure stops the atomic inbound commit; it never silently drops a notice
while advancing crypto state. Bound every batch read (at most200 references).

## Decisions and retries

Pending references are evaluated against their current committed local rows,
fresh block/mute data, D48 acceptance, exact current profile/session generation,
message expiry/freshness and the shared notice policy. Missing policy data means
retry, never unmuted. Mentions are validated locally. Attachments may produce
only a generic unmuted notice, never a manifest preview or mute override.

Freeze selected eligible references into one immutable generic batch decision
inside a transaction. Assign one CSPRNG128 opaque lowercasehex32 ID once; native
receives only that ID. New events retain separate pending references and cannot
be consumed by an older decision. Re-read all current rows/policy before
presentation; if none remain eligible, suppress the decision durably.

Native returns shown/suppressed/unavailable. Shown and permission/UI suppression
become terminal decisions; transient unavailable leaves a retry. A lost response
reuses the same frozen ID. Native durably records that ID before its OS alert
attempt, with bounded fresh deduplication, so it makes at most one attempt.
A crash between journal commit and OS scheduling may miss the generic alert;
this is not an exactly-once delivery guarantee. Message data remains durable.

Native ACK is allowed only after eligible catch-up and all its notice handling
are durable. Partial catch-up, missing policy, cancellation or unavailable
storage/keys/crypto leave the wake pending. SQL/crypto operations drain at atomic
boundaries; they are never force-timed-out or interrupted by engine destruction.

## Scope and cleanup

References, decisions and any usage counters are device-local and excluded from
K2 snapshots and legacy backups. Every backup restore, identity change, logout
and private-state clear removes them atomically. Imported descriptors/provenance
cannot enqueue or authorize a notice. Scope every read/decision to the exact
current stored origin/account/device, without persisting a session token.

Tests must cover cursor-commit/crash before notice evaluation, native-attempt/
SQL-result crash replay, missing policy, mention followed by deleted newer
mention, newer event while an older decision is frozen, scope switch, own/invalid/
copied exclusion, expiry, cap rollback, backup exclusion and migration14-to15
rollback/retry. Native scene/job tests remain separately required.
