# C0 prerequisite: shared community routing without data loss

Design proposal, 2026-10-26. Not implemented or approved. This is the exact
schema/wire/cutover proposal for independent review, following owner D51:
the server may see channel IDs for posting/retention, but posts and names
stay encrypted. It supplements [C0](C0-community-groups.md) and
[C1 membership planning](C1-membership-plan.md).

The coordinator requires preserving existing demo data unless deletion is
explicitly authorized. Accordingly, this proposal replaces C0's earlier
“recreate demo communities” migration shortcut: **no conversation, MLS
state, message, attachment, membership or cached history is deleted by the
migration.** MLS groups cannot be merged by SQL or reinterpreting ciphertext.

## Target model

- One live shared MLS group per community for open/announcement channels.
- One separate live MLS group per private channel.
- Every new shared-group post carries the same `channel_id` in its clear
  envelope context and encrypted W7 payload. The server validates the route;
  the client authenticates the encrypted copy and rejects a mismatch.
- A channel may also have retired conversation history sources. Those
  groups retain original IDs, keys, ciphertext, sender/action identities and
  original context. History sources are read-only after cutover, never
  rewritten as messages from the new shared group.
- C1 opens invitations only after [scoped sync isolation](C1-sync-isolation.md)
  is implemented and independently reviewed. This migration does not weaken
  I33 or create a plaintext fallback.

## Additive schema proposal

Use the next coordinator-allocated migration number, never a number already
owned by K2. Create sidecars rather than rebuilding `conversations`, whose
original SQLite `CHECK(kind)` and many referencing foreign keys make a
table replacement unnecessarily risky for this change.

```sql
CREATE TABLE community_layouts (
  community_id TEXT PRIMARY KEY REFERENCES communities(id) ON DELETE CASCADE,
  version INTEGER NOT NULL CHECK(version = 1),
  state TEXT NOT NULL CHECK(state IN ('legacy','preparing','active')),
  generation INTEGER NOT NULL DEFAULT 0 CHECK(generation >= 0),
  shared_conversation_id TEXT REFERENCES conversations(id),
  cutover_event_id INTEGER,
  CHECK(state <> 'active' OR shared_conversation_id IS NOT NULL)
);

CREATE TABLE community_conversation_layouts (
  conversation_id TEXT PRIMARY KEY REFERENCES conversations(id),
  community_id TEXT NOT NULL REFERENCES communities(id),
  purpose TEXT NOT NULL CHECK(purpose IN ('shared','private','history')),
  generation INTEGER NOT NULL CHECK(generation >= 1),
  retired_at TEXT
);
CREATE UNIQUE INDEX community_one_live_shared
ON community_conversation_layouts(community_id)
WHERE purpose = 'shared' AND retired_at IS NULL;

CREATE TABLE community_channel_routes (
  channel_id TEXT PRIMARY KEY REFERENCES channels(id),
  community_id TEXT NOT NULL REFERENCES communities(id),
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  access_mode TEXT NOT NULL CHECK(access_mode IN ('open','announcement','private')),
  generation INTEGER NOT NULL CHECK(generation >= 1)
);
CREATE INDEX community_routes_conversation
ON community_channel_routes(conversation_id, channel_id);

CREATE TABLE community_channel_history_sources (
  channel_id TEXT NOT NULL REFERENCES channels(id),
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  cutover_event_id INTEGER NOT NULL,
  PRIMARY KEY(channel_id, conversation_id)
);
```

Sidecar writes occur only through `community_layout_store.go`, which checks
that all referenced communities/channels/conversations agree, each active
route matches its purpose, and no history source is a live route for the
same generation. Do not rely on independent foreign keys to prove those
cross-table relationships. Authorization and quota checks run in the same
writer transaction. Additional immutable layout/cutover commitment fields
belong to the signed control record described below; they must be finalized
in independent review before freezing the migration.

Current `ManageCommunityMember` loops over every `community_channel`
conversation. The active-layout membership service must replace that loop
with explicit live route/group selection: a new member is never added to
history-source memberships as a side effect of joining the community.
Leave/removal revokes server access to both current groups and any old
history sources the account could access; archived groups need no new MLS
commit because they accept no future application messages. Cached old
plaintext/keys on a former member's device cannot be remotely revoked.

The physical shared conversation may use existing base kind
`community_channel`, `community_id=<community>`, `channel_id=NULL`. Its
effective API/domain kind is **`community_shared`** through one canonical
layout projection. Every read/write path must use that projection; no
scattered caller-specific reinterpretation of `kind` is allowed. Private
conversations remain effective `community_channel`, with one channel ID.
The existing physical kind continues to make legacy receipt/typing filters
conservatively treat all of them as channels.

If review concludes effective-kind projection cannot be enforced centrally,
use a separately designed transactional table rebuild instead. Do not ship
two competing definitions of conversation kind.

## Wire and domain changes

The authenticated channel list returns IDs, `kind`, `conversation_id`,
`layout_version:1`, `layout_generation` and opaque encrypted metadata
references. Shared conversation responses use `kind:'community_shared'`,
community ID, and no single channel ID. History sources are separately
identified by channel, original conversation ID and cutover boundary.
Do not send plaintext names/titles from new-layout endpoints.

New-layout sends require envelope metadata `channel_id` and
`community_layout_generation`. `group_id` remains the MLS conversation ID;
`mls_epoch` retains its existing meaning. For a shared group, the writer
transaction checks that the channel is an open/announcement route of that
community, points to this conversation and generation, and that sender/device
membership is current. Missing/foreign/private/stale routes are refused.
Non-shared group envelopes must not add a different channel context.

W7's encrypted payload carries `channel_id` for `community_shared` and omits
it elsewhere. The receiver checks it against the received envelope and
its authenticated conversation context. Pins/actions/forward targets cannot
cross channel boundaries. Polling and decryption stay per MLS group;
per-channel paging, unread/search projections and conversation selection are
local filters over that group's authenticated channel IDs.

Legacy endpoint clients cannot write to active layouts without the required
context. New clients check server capabilities before using these routes.
There is no server-side conversion of an old client's text or envelope.
Until C2 is built, announcement classification must not be advertised as
client-enforced admin-only posting merely because its route exists.

## Existing-data preflight

Migration SQL only creates sidecars and a `legacy` layout row for each
existing community. It changes no old data, permissions or live route.
A new-layout client/admin performs preflight before preparing cutover:

1. Inventory existing channel/conversation pairs, including duplicates,
   orphan channels, absent MLS rosters and unfinished staged commits.
2. Compare each actual channel membership set with community membership.
   Do not assume equality: `ManageConversationMember` currently allows
   non-DM channels and can produce extra/different members.
3. Verify encrypted names and required metadata can be read/written by the
   appropriate existing members. The migration cannot encrypt old plaintext
   names on the server because it has no client keys.
4. Check current quotas and ciphertext/history access. Preserve the exact
   old membership/epoch filtering for every history source.

A normally matching legacy channel is eligible for an open route; an
announcement label remains announcement. An existing `private` label is
not proof of privacy: the current normal path gave every community member
access. Never claim old posts have retroactively become private.

Divergent membership, missing group evidence or ambiguous channel mapping
leaves that community **legacy/pending**, with its current data and access
untouched and a concrete repair reason. Do not widen an old channel's access
by folding it into the shared group. Resolving a real divergent dataset may
require an explicit membership decision by its administrator, not a silent
SQL default. New empty communities can use the target layout immediately.

## Staged cutover

1. **Prepare.** An authorized administrator requests a new layout generation
   at the expected old generation. The server transaction reserves a fresh
   shared conversation ID, target memberships and pending routes, leaving
   old routes live. The response contains no secrets. Repeated requests use
   a bound idempotency key; concurrent preparation returns a conflict.
2. **Create the MLS group.** A member device initializes that fresh ID using
   the current key-package/commit-bundle path. Add current eligible devices
   through one staged commit; accept only the current epoch under D28.
   Do not export, clone or synthesize another channel's provider state.
   Private-group membership remains distinct; absent C3 policy, new private
   channel creation stays unavailable rather than pretending isolation.
3. **Authenticate routing.** Before activation, the coordinator supplies a
   detached credential signature over a canonical layout commitment, binding
   configured server origin, community ID, generation, live route IDs,
   original history-source IDs and the expected previous commitment. The
   record contains only clear IDs/routing metadata already permitted by D51;
   names and message content are absent. A dedicated native signing domain
   `veritra-community-layout-v1` must prevent cross-protocol reuse.
   Receivers verify the signer against their authenticated MLS credential
   roster and the applicable coordinator/role policy before exposing routes.
   This signature/role binding and canonical encoding need independent
   review before allocation; an unauthenticated server table is insufficient.
   Carrying this record separately avoids inventing a channel-less W7
   application payload in a shared group where `channel_id` is mandatory.
   Current built-in role metadata is server-recorded; a signature alone does
   not turn that metadata into C4's authenticated role state or solve L1's
   server-inserted-device limitation. Review must pin the allowed coordinator
   policy and state this residual trust rather than claiming operator-proof
   routing authorization.
4. **Activate atomically.** With preparation generation, accepted group
   creation evidence and metadata readiness checked, one server transaction
   assigns the active routes, records the cutover event boundary, retires old
   write paths and emits durable cutover events. Only a current generation
   may activate. Old conversation messages committed before that transaction
   remain old-source history; old writes after it are refused. No message is
   moved between groups or assigned a new identity.
5. **Client switch.** After the Welcome/control record/cutover event are
   verified and atomically stored, the client routes new sends to the shared
   conversation and selects a channel context. An outbox item already
   encrypted for an old group is not re-encrypted automatically; it remains
   visible as unsent and offers an explicit resend after the client can
   construct a new authenticated message.

Offline old devices may still hold history but cannot post to the retired
route. New devices get current shared-group access through their own
Welcome. Older channel history remains available only if they already held
it or receive it via K2/C7 policy; cutover never grants past MLS epochs to
newcomers. Existing channels retain normal history-source decryption with
their original payload rules, including absence of `channel_id` on old
payloads. The UI may aggregate these sources only after authenticating the
mapping; it must not rewrite their crypto context.

Preparation failure or a crash before activation leaves old routes live and
is resumable. After activation, do not roll back the layout generation or
reuse an old MLS group for new posts. A repair is a new generation with new
group IDs and an authenticated forward transition. Retired data remains;
no automated cleanup/retention override is authorized by this design.

## Names and plaintext legacy fields

New community/channel names, topics and icons use the reviewed C3 encrypted
metadata mechanism, with a reusable encrypted-record service if W11 provides
it. Names are never included in layout records' clear headers, route
responses, server search results or audits. Legacy metadata may still be
read by already authorized clients during a pending conversion; no new
plaintext update path is introduced.

An existing name can be copied into an encrypted record by an authorized
client. Removing its old plaintext database value is a distinct privacy
migration after the encrypted value is durably confirmed and recoverable;
do not erase it automatically during the routing migration. Preserve user
data and clearly record the legacy disclosure until that migration is
reviewed. C0/C1 cannot be called fully encrypted for names merely because
their new write path is encrypted while old values still remain.

## Parallel implementation slices and ownership

The first safe slice is new **inactive** layout sidecar schema, a pure
preflight report/service in `community_layout_store.go`, and migration/store
tests in disjoint files. It changes no current route or message write and
does not touch W8 payloads, local schema, `app_state.dart` or crypto ABI.
Coordinator assigns the migration number; independent review precedes it.

Second, implement server route validation/projection in that same new
service plus exact HTTP contract tests. Wiring shared handlers/message
admission is serialized with the coordinator; avoid parallel edits to the
central store/query files. The active shared-layout API remains disabled
until signed client context, encrypted metadata and scoped sync are ready.

Client integration then has one owner for W8/K2-shared models/state/database
and a second reviewer. Separate agents may own community UI or tests only
after those interfaces are fixed. Encrypted metadata and layout control
formats cannot be invented independently by different workers.

## Required migration/security evidence

- Pre/post row counts and hashes prove old ciphertext, attachment records,
  MLS messages/rosters, memberships, sessions and decrypted local history
  remain unchanged by the additive migration and a repeated run.
- Normal, empty, divergent-membership, orphan/duplicate-channel and pending
  commit fixtures produce the correct preflight outcome without access
  widening or deletions. Outsider access to history remains denied.
- Crash/race tests at prepare, bundle acceptance and activation boundaries:
  exactly one generation activates, old writes stop at one durable boundary,
  no accepted old message disappears, and later failures cannot roll back.
- Native integration: several open channels share one real MLS group;
  private channels have distinct groups; joins/removals produce the C0 set
  of commits and correct Welcomes, never one per open channel.
- Envelope/payload/channel/generation substitution, omitted context, old
  clients, forged layout controls and unready encrypted metadata fail closed.
- History aggregation keeps original identities/context and permissions;
  K2 fresh devices receive no old MLS state; cutover does not become C7
  history authorization. Per-channel retention, pins, unread and search
  stay correctly scoped.
- Names/posts/keys never enter server-visible data added by these changes;
  test HTTP fields, search, audit and diagnostics, not just UI labels.
- Required narrow/full checks or CI evidence pass before marking C0/C1
  implementation complete. Existing Windows verification limits remain
  recorded separately; they are not permission to waive security checks.
