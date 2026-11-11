# C3: private channels and encrypted community info (design)

**Status: steps 1-2 and a tested sender/fetch slice of step 3 built
(2026-11-09); C3 remains partial.** See [local port evidence](../../testing/evidence/C3-rest-2026-11-09.md).
Written 2026-11-01 against `main`
at `f1b4a36`. Builds on [C0](C0-community-groups.md) (group layout) and
[W11](W11-profiles.md) (encrypted record mechanism).

## Summary

- **Private channel = its own MLS group** (C0). Who can see it is exactly
  who is in that group. C3 adds the rules for listing, naming and key
  delivery. Admins pick the members; there are no per-channel role
  overrides (C4 is built-in roles only, D80).
- **Names, topics and icons** of the community, each category and each
  channel live in **encrypted info records**, one per subject. This is
  W11's record mechanism with three more subject kinds. The server stores
  ciphertext, version, key ID and size, and sees only IDs.
- **Keys travel only inside MLS.** A community key (community, categories,
  open channels) goes through the shared group. A private channel's key goes
  through that channel's own group, so a member who is not in it never holds
  it.

## What the server sees

| Seen | Not seen |
|---|---|
| Community, category and channel IDs; which channels belong to which community | Names, topics, icons, keys |
| Channel kind: open/announcement (shared conversation) or private (own conversation) | Why a channel is private |
| **Who is in each private channel** (its group's device list). Same as every conversation today; C3 tells users so | |
| Record size bucket (4 KiB, or 256 KiB with an icon: **icon presence is visible**), version, key ID | The icon |

Category structure (which channel sits in which category, and order) is
inside the encrypted records, so the server sees no tree.

## Subjects

W11 `subject_kind` gains three values. `subject_id` is the community,
category or channel ID; the AEAD context uses the same literal.

| Kind | Fields | Key | Delivered in |
|---|---|---|---|
| `community` | name, icon, ordered category IDs, ordered `{channel_id, category_id}` for **open** channels | community key | shared group |
| `category` | name | community key | shared group |
| `channel` (open/announcement) | name, topic, icon | community key | shared group |
| `channel` (private) | name, topic, icon, `category_id`, `position` | channel key | the private channel's group |

Limits: name 1-100 characters, topic 0-1,024 (NFC, no control characters,
W11's checks), at most 50 categories and 500 channels, 256x256 PNG icon.
Records are padded to W11's buckets.

Private channels are **not** listed in the community record, which every
member can read. A private channel's own record names its category and
position. A category holding only private channels shows, to non-members,
as an empty category.

## Keys

- 32-byte random keys; `key_id` as in W11 (S7).
- **Community key:** created by the creating device at community creation,
  replaced at the first write after a rotation is due.
- **Channel key (private only):** created at channel creation.
- Receivers keep up to 4 keys per subject; a key that does not open the
  record the server serves is dropped at once (W11 anti-flood rule).

## Record format

W11's `VPR1` record and `VPE1` encryption, with these changes:

- JSON `kind` is `community`, `category` or `channel`.
- Extra fields: `topic`; for `community`, the ordered lists above.
- `revision` equals the server version this upload becomes (W11 rule).
- AEAD context: `"veritra-profile-v1\0" + kind + "\0" + subject_id + "\0" + key_id`.
  Subject IDs are globally unique, so the community ID is not needed.
- A tombstone (all content fields `null`, `revision` + 1) removes a category
  or channel from clients' view. There is no client DELETE.

Test vectors for the three kinds are computed when the code is built, the
way W11's were.

## Server storage and routes

Reuse W11's `encrypted_profiles` table, size rules and read/write plumbing
by adding the three kinds: no second table, no second mechanism.

| Route | Who may write | Who may read |
|---|---|---|
| `PUT/GET /api/v1/communities/{id}/info` | built-in role `owner` or `admin` | every community member |
| `PUT/GET /api/v1/communities/{id}/categories/{cid}` | same | every community member |
| `PUT/GET /api/v1/channels/{id}/info` | any member who can read it (D80; built 2026-11-08, replacing "owner/admin") | open: every member; **private: current members of that channel's conversation only** |

- Unreadable or missing gives 404, never 403 (no existence oracle).
- The channel list returns open channels to all members and a private
  channel only to members of its conversation, with IDs, kind and
  `conversation_id` but no name. Sync does the same.
- The server checks built-in roles from its own table. Apps check the same
  roles from C4's signed role state, never the server's word (D80); see
  [Authorship](#authorship).
- New sync event `info.updated` `{subject_kind, subject_id, version, key_id}`
  to the read audience; it ships only after W7 step 0 (P5).

## Authorship

A record is encrypted under a key every member holds, and apps do not trust
the server's role check. So each accepted change is **announced in MLS**:

- New W7 payload `info_update`: `{subject_kind, subject_id, revision,
  key_id, record_sha256}`, sent by the editing device into the group that
  holds the key.
- A receiver accepts a fetched record only if its SHA-256 matches an
  `info_update` from a sender allowed to edit that subject under the C4
  role state of the community's shared group. MLS sender binding (D25)
  makes the announcement authentic. Per the owner decision below, channel
  names and topics are open to any member unless admins restrict them; that
  restrict flag must be added to the C4 record when C3 is built, or it is
  trusted to the server (C4 keeps the record to what C2 needs today).
- Otherwise the record is ignored and the last good one stays shown. A
  server-substituted or member-forged record is never displayed.
- Receivers accept only a `revision` above the one they hold (rollback).

## Key delivery

New W7 payloads `info_key` `{subject_kind, subject_id, key_id, key}` and
`info_key_request`.

- The device that **commits an add** sends the group's current key(s) right
  after the commit is applied. For a private channel the adding admin sends
  that channel's key.
- Until a key arrives the joiner shows placeholders ("Community", "Private
  channel"). A device may send `info_key_request` in the group (answered by
  any member holding the key; one request per subject per hour).
- A key is only ever sent in the group that owns it: the community key never
  goes through a private channel's group, nor the reverse.

## Private channel lifecycle

- **Create:** an admin device makes the conversation and group (C0), creates
  the channel key and record, then adds the members the admin picks. The legacy
  `channels.name` and `conversations.title` are sent empty.
- **Add a member:** add commit in the private group, then `info_key`.
- **Remove a member:** remove commit, then an **immediate channel key
  rotation**: the removing admin writes a new record under a new key and
  sends `info_key` to the remaining members. The removed member keeps what
  they already saw and cannot read later edits.
- **Open to private, private to open** (C0 "Moving a channel"): the record
  is re-encrypted under the target key and the new `info_key` delivered.
- **Who can see it changes:** an admin adds or removes members of the
  private group; the server sees an add or remove of devices.

## Migration from today

`communities.name`, `channels.name` and `conversations.title` are server
plaintext today. There is no release, so C0's rule applies: demo communities
are recreated. After C3 the server refuses non-empty names for new
communities and channels (`400 plaintext_name_refused`) and a later
migration drops the columns once no client sends them. This is W11's
"community and channel names wait for C3" step.

## Build steps

1. **After C0 and W11 are built:** add the three kinds to W11's store,
   routes and read rules (Go tests: 404 for non-members, writer role,
   `If-Match`, size buckets).
2. Register W7 payloads `info_key`, `info_key_request`, `info_update` (W7
   owns that section of `docs/crypto.md`; this design is the dependency).
3. Flutter: info repository, key store (reuse W11's), announcement check,
   key delivery on add, rotation on removal, UI.
4. Remove the plaintext server names and drop the columns.

Steps 1-3 reuse C0's conversation model and W11's table and record codec.

## Risks and residuals

- Cached records cannot be implicitly moved between key homes by changing
  server topology. Publication and announcement recovery require the accepted
  record's key to have arrived in the target home. Explicit channel conversion
  remains unimplemented. This guard does not authenticate initial topology.
- Membership of each private channel is visible to the server (tell users).
- Icon presence and size bucket are visible.
- A removed member keeps what they already saw.
- With a lazy community-key rotation, an ex-member who can still reach the
  server could read the next community-level edit. Same trade as W11.

## Open questions for the owner

1. **Community key on a kick or ban:** rotate at once, or lazily at the next
   edit (the written default)? Private channel keys rotate at once either way.
2. **May non-members see that a private channel exists** (a locked entry)?
   This design says no.
3. **Who edits community, category and channel names and topics?** Written
   default: admins only. The D59 pattern (any member unless admins restrict)
   is the alternative.

## Owner decisions (2026-11-01)

- Community key rotates immediately on a kick or ban.
- Any member may edit channel names and topics unless admins restrict it.

## Build status (2026-11-08)

Built (branch `agent/c3`):

- **Server (step 1).** Kinds `community`, `category`, `channel` in W11's
  `encrypted_profiles` (`community_info_store.go`), routes above, `info.updated`
  sync event (IDs, version, key id) to the read audience, and three more
  bounded lists (`community_ids`, `category_ids`, `channel_ids`) on
  `POST /api/v1/profiles/versions`. Read rule: community and category, the
  community's members; channel, the members of the conversation that carries
  it (route in the shared-group layout, else the legacy channel conversation).
  Write rule: community and category, owner or admin (not moderators);
  channel, anyone who can read it (D80). The server cannot see the admins'
  "restrict channel info" switch; apps enforce it. Non-readers get 404, a
  reader who may not write gets 403.
- **Category IDs** are chosen by the app (`cat_` + 32 hex). Migration 0063's
  `community_categories` binds one to its community at the first
  `If-None-Match: *` write by an owner or admin; through another community's
  route it is 404. At most 200 IDs per community (an abuse bound; the 50
  live categories are the apps' to keep, since the server cannot tell a
  tombstone). Triggers delete a record with its community, category or
  channel.
- **Record codec** (`community_info_codec.dart`): W11 framing, AEAD and
  context. JSON per kind: community `name`, `icon`, `categories`,
  `channels` (`{channel_id, category_id}`); category `name`; channel `name`,
  `topic`, `icon`, and for a private channel `private: {category_id,
  position}`. Unknown keys are ignored (as W11); another kind's keys are
  refused. Icons 256x256 at most.
- **Payloads and storage** (step 2 and the receive half of step 3): see
  `docs/crypto.md`, change log "C3" and §4. Local schema 31.
- **Receive rule** (`community_info_book.dart`, pure Dart): the
  [Authorship](#authorship) and [Keys](#keys) rules, with the C4 role check
  behind `InfoEditPolicy`.

**Deviation: bucket by fit.** A community record lists up to 500 open
channels (about 80 bytes each), so it cannot fit 4 KiB. A record now takes
the smallest bucket it fits. The large bucket therefore shows "an icon or a
big community", not "an icon"; a tiny icon may stay in the small one.

**Built 2026-11-09 (branch `agent/c3-2`):**

- Only owners and admins create channels (owner decision 2026-11-09; the
  server refused moderators from then on).
- Senders (`community_info_service.dart`, wired in
  `app_state_community_info.dart`):
  - Info payloads go through the app's ordinary send path, so removal holds
    (D68) and per-conversation order apply. They are never franked, never
    expire, and leave a hidden action row. In a shared group they ride on an
    open channel (C0).
  - The sender keeps its own copy of what it sends (MLS never decrypts a
    device's own message), and its own new keys locally.
  - Publish: seal under the current key, `PUT` with `If-Match` (a stale
    version is retried), keep the record as accepted, then send
    `info_update` in the group that owns the key.
  - Keys: a community key is made when its first record is written (at
    creation), a private channel's key when its record is. The current key
    is the newest one in the owning group from this account or from an
    owner or admin under the verified role state.
  - Delivery is request and answer: a device missing a key asks at once,
    then at most once an hour; an owner or admin (server role, only to pick
    who speaks) holding the key answers after a short random wait, only in
    the owning group, and not when another answer already came after the
    request. A push right after an add commit is not built (the request
    covers it).
  - A device that answers a key request also announces again, as itself,
    every record under that key it accepted: a joiner never saw the
    announcements made before it came.
  - A device makes a new key only when the keyed subject is created, or in
    a rotation; otherwise it asks. The current key is the one whose id
    first arrived last, so an old key delivered again never wins.
  - Rotation (D80): every removal, kick or ban marks the key the
    conversation carries as due, kept across restarts (a setting with a
    token per mark, changed under a lock, so a mark made during a pass
    survives it). Only owners and admins (server's word) rotate. A pass
    skips a group still holding sends for the removal (D68), makes a new key
    (a retry reuses it), sends it into the owning group, and seals every
    record under it again. A mark is kept while its group cannot be placed
    and dropped only when its community is known gone; failures back off
    from one minute to an hour.
  - Publishing never runs inside the app's session queue (it sends, and a
    send queues behind it). An own record whose announcement could not be
    queued (no open channel yet, a pause) is announced by a later pass.
  - Background info sends report under their own op, never as the
    composer's send error.
- Fetch loop: on `info.updated`, after the communities load, and after a
  catch-up at most once a minute, never before the communities have loaded.
  One versions call per community; only records above what was accepted
  are fetched and judged; a 404 never clears what is shown.
- Screens: names shown as the accepted record, else the legacy server
  name, else a placeholder; a channel's topic under its name; an edit
  button for channel name and topic only where the verified role state
  allows it.

**Remaining removal integration:** moderators may kick, but only owners and admins
rotate, so a moderator's kick leaves the community key unrotated until an
admin removes someone. Options: (a) an admin's device rotates when it sees
a removal it did not make; (b) trust moderator-made keys; (c) only admins
kick. Recommended: (a). This is the selected follow-up; remote-removal
rotation is not implemented by this slice.

### Local port and verification (2026-11-09)

Ported the six C3 commits from `origin/agent/c3-2` onto `ai/c3-rest`, whose
base already includes `origin/agent/c3`. No C4 or other package commits
were copied. Existing unfinished worktree edits are preserved in the local
stash named `c3-rest-preexisting-preserved`.

Additional fixes: retry a request or answer immediately when its send was
not queued; coalesce overlapping answer passes; query all 500 channels in
batches of 200; keep a newer displayed record when an older cache read
finishes; require a cached record's key to come from its current owning
group; cancel uploads and sends when their app session ends. Focused tests include actual native MLS send/receive, record
encryption, both local stores, failed sends and fetch batching.

The actual app still has no implementation of `VerifiedRoleSource`:
`debugInfoRoleSource` is test-only. Receiver acceptance therefore stays
closed. This prevents calling the whole package complete or removing the
legacy-name fallback yet. See the remaining work below. No new schema,
server migration, crypto ABI or dependency is needed by this slice; reserved
local schema 35 and server migration 0067 remain unused.

**Creation UI follow-up (2026-11-10):** shared-layout communities now offer an
open/private switch and a picker of existing community members (excluding the
creator). The modal checks the server roster for owner/admin creation rights;
this is only UI availability, never authority for accepting info records.
Private creation uses its own conversation and info key. Member additions use
the existing MLS reconciliation path. After a partial add failure, Retry keeps
the created channel and retries only failed additions. Session changes stop
further additions. English and both Serbian scripts include the private
membership disclosure. Legacy communities retain their existing form, since
their server layout adds every community member to each new channel.

This is a UI slice: names still take the existing plaintext creation route
until step 4, and peer info still fails closed without C4's verified role
source. Creation/member-selection is covered by widget tests and a native
record-codec integration test in `c3_app_community_info_test.dart`. Neither
reserved counter is consumed by this slice.

**Review hardening (2026-11-10):** rotation refreshes and authenticates each
record before taking its content snapshot, then requires that same revision
at upload (including conflict retries). Unreadable existing records keep the
rotation pending. Non-admin devices retain their marks for a later promotion;
admin availability is refreshed every pass. Key replies announce only records
under the key actually delivered. These fixes do not complete the missing C3
integration below. Evidence: `testing/evidence/C3-review-2026-11-10.md`.

**Creation-entry follow-up (2026-11-11):** community refresh loads the viewer's
roster role and shows "New channel" only to owners and admins, including in
legacy communities. Unknown or failed reads hide the entry. Refresh clears
old availability before fetching, and stale session or overlapping-refresh
replies cannot restore it. New community creation triggers this refresh too.
This is a server permission hint for UI availability only; encrypted info
acceptance still requires the verified C4 role source. See
[`creation-entry evidence`](../../testing/evidence/C3-creation-access-2026-11-11.md).

**Add-key delivery follow-up (2026-11-11):** the committing device now pushes
the current info key after its accepted add bundle is merged locally, in the
key's owning group. Foreground sync resolving an own commit after a lost
response does the same. Accepted records under that key are re-announced only
where the verified role policy allows this account to author them. Delivery
never mints a replacement key, defers to pending rotations, and uses the
ordinary ordered send path outside the session queue. Missing keys, interrupted
delivery, missing topology and inbound-only background wakes retain the
request/answer recovery path. This hook is best effort, not a durable second
outbox. Native-backed app tests exercise both accepted-response and
lost-response paths; production peer acceptance still waits for C4 wiring.

Overlapping removals now invalidate the older rotation's token before further
re-sealing, even if its new key was already delivered. The newer mark retains
its own fresh key and is not delayed by the abandoned pass's backoff.

**Still left:** channel conversion UI;
icons and the category screens; and step
4 (`400 plaintext_name_refused`, dropping the plaintext columns). Step 4
waits for C4's client role wiring: until the app holds a verified role
record, nothing another account wrote is shown, so new names come only from
the legacy server name. Rules from the first review that still bind:

- Reuse a tombstoned category ID before minting a new one: the server's
  200-binding bound is for the community's whole life.

**Seams and residuals.**

- The C4 role record (format 2) has no "admins restrict channel info" flag.
  `GovernanceInfoEditPolicy.channelInfoRestricted` is the seam; until C4's
  client wiring adds the flag, channel info follows D80's default (any
  member). Without a verified role record nothing is shown.
- Which conversation is a community's shared group (`shared_conversation_id`)
  and which carries which channel come from the server. A hostile server
  with any account's help could pass off a group the attacker owns as a
  community's shared group (then both the key home and the C4 role state are
  the attacker's), or swap a private channel's conversation, and show forged
  names. Binding the community and channel IDs inside the group's own state
  (C4 record or group context), or pinning them at join, closes this later.
- Keys are never dropped because a record fails to open (a change from
  W11's anti-flood rule): the key id is a hash of the key, checked on
  receipt, so a failure means a bad blob, and any member could otherwise
  wipe everyone's community key by announcing garbage.
- Rows of received keys and announcements are per sender and per group, so
  a replayed copy cannot hide an editor's own one and a flood cannot push
  out another sender's key. Info payloads are kept only from community
  conversations.
- The server accepts a channel write from any reader, even when admins have
  restricted channel info, and from a timed-out member (C5). Apps will not
  show such a record, but a device with nothing cached (a joiner, a restore)
  shows placeholders until an admin writes again.
- Backups and new-device transfers carry no info keys; a restored device
  asks again.
- Info envelopes carry no `frank_commit` while every other message does, so
  the server can tell these control messages apart (as with C7's).
