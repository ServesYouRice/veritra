# K2 Flutter history snapshot slice

Implemented local slice, updated 2026-10-29; integration and final checks pending.
This does not implement the live handoff, grant membership, or open a release gate.
The coordinator reviewed the format/merge decisions before implementation.

`storage/history_snapshot.dart` defines a distinct history plaintext version 1.
It never calls the clone backup decoder. Native verified container/handoff
orchestration must supply its pinned import context before calling the internal
store operation; constructing `HistoryImportContext` is not proof of verification.
Its digest identifies the authenticated transfer, rather than an unauthenticated
digest supplied by downloaded JSON.

The exact root fields are `version`, `account_id`, `source_device_id`,
`snapshot_counter`, `snapshot_created_at`, `conversations`, `messages`,
`reactions`, `pins`, `starred`, `conversation_prefs`, and `origins`.
Unknown fields, duplicate JSON members, invalid types, conflicting identities,
duplicate keys/server IDs/descriptors and unsupported versions fail before writes.
UTF-8 payload bytes are capped at 64 MiB minus the eight-byte framing prefix;
the native container additionally enforces the full padded frame cap. Collections
are bounded at 100,000 list records, 10,000 descriptors, depth 32, and a bounded
JSON member count. Message content is at most 64 KiB; decoration is bounded to
W8's 256 entities and 50 mentions. Overflow fails explicitly without truncation.

Descriptors contain ID, immutable kind/community/channel mapping, historical
title and `historical_channel_ids`. Shared community descriptors have a community
ID, null singular channel ID, and an explicit historical channel allowlist. Every
shared row must carry an allowed channel. Isolated community descriptors have a
singular channel ID; their message rows retain W7's omitted inner channel.
These descriptors live only in `local_history_conversations`, never the live
conversation cache. They contain no roster, role, acceptance, invite, unread,
mute or posting authority. No profile lookup or attachment fetch is authorized
by their presence. The next UI slice must retain a separate read-only model and
verify current scoped routes/membership/MLS readiness before enabling live use.

Message objects explicitly project the current local message fields, excluding
`state` and `searchId`. Imported rows receive `state=restored`, not a delivery
claim. Pending messages and unauthenticated invalid/unverifiable warning
placeholders are omitted. Hidden, deleted and action rows are body-free;
unsupported hidden JSON retains the hidden flag without its body. Expired rows
are discarded at both ends. Existing encrypted attachment manifests are allowed,
with their original bounded keys/context; downloaded plaintext is excluded.
Actions are snapshots of materialized state, never replayed commands.

Schema 14 adds a private namespace: historical descriptors, per-message
provenance, import ledger, and an independent source snapshot counter. The ledger
key encodes canonical origin/account/source device/transfer ID. Import compares
the active local session's origin/account/recipient inside the transaction.
Identical transfer/digest repeats are no-ops; changed digest is a conflict.
Message key, sender identities, conversation/channel and server-ID uniqueness
cannot be relabeled by a snapshot. A receiver's existing row wins completely.
Only absent rows are inserted, using local FTS triggers and fresh local search IDs.
An insertion and its ledger/provenance/preferences commit together or roll back.
Session, credentials, MLS state/counter/key, cursor, processed markers, outboxes,
drafts, settings, request acceptance and pending pin commands are untouched.

Reactions and stars seed only newly inserted eligible targets. Pins and archived/
pinned-chat preferences seed only previously unknown historical/live conversations;
absence on an existing receiver is treated as a receiver choice. Pins obey the
three-pin cap, target expiry, and a newly allocated persistent local order.
Imported conversation pins use only remaining space under the five-chat cap.
Later transfers cannot restore a locally removed star, pin or archive choice.

Per-message provenance records snapshot source/counter/time and immediate transfer
source. Re-export preserves original snapshot provenance. Later authenticated
direct inserts reconcile copied rows: matching identities use direct content while
preserving receiver hides/deletions and known live edits/deletes; the provenance
separately records direct receipt and retained-body origin. Conflicting copied
identities/server IDs are quarantined and removed from active history, including
when a direct duplicate otherwise needs no insertion. Direct-vs-direct duplicate
behavior is unchanged. Quarantine is bounded to 128 records / 4 MiB, evicts oldest
evidence, and cannot stall authenticated sync. It is excluded from K2 export.
Legacy `restored` rows
without provenance retain a copied-origin marker on export. The existing timeline
union supplies historical rows without envelopes, deduplicates stable keys, and
orders local-backed entries by their stored time and stable key rather than a
relisted server envelope's time.

Authenticated edits/deletes received before their target are kept in a private
typed journal, scoped to account, conversation, channel, target and actor. It
coalesces the latest edit or terminal deletion in local receive order, bounded
to 4,096 records / 4 MiB with explicit overflow failure. Matching actor/scope
effects apply atomically before imported rows/extras/FTS. A copied identity
cannot discard mismatched live intents; only an authenticated direct target can
establish that mismatch. Deletion intents remain terminal across later imports.
The journal is backup-only state, never an exported command or MLS replay.
Restored own bubbles display copied-history provenance and do not receive live
delivery/read ticks.

Clone backup plaintext version 5 preserves the namespace, deferred journal and
quarantine with mixed direct and imported rows. Versions 1–4 remain readable and replace/clear the namespace
atomically. A same-origin/account/device restore retains the maximum local
history counter; a fresh database cannot reconstruct a missing old highwater.
That existing clone-restore limitation remains explicit. Fresh file keys avoid
nonce reuse; this slice does not make legacy clone restore a safe K2 fallback.
