# C3: private channels and encrypted community info (design)

**Status: proposed, not built.** Written 2026-11-01 against `main` at
`f1b4a36`. Builds on [C0](C0-community-groups.md) (group layout) and
[W11](W11-profiles.md) (encrypted record mechanism). Neither is
implemented yet, so no C3 code is written; see [Build steps](#build-steps).
Security-sensitive: needs the second-opinion review before building.

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
| `PUT/GET /api/v1/channels/{id}/info` | open channel: `owner`/`admin`; private: `owner`/`admin` who is also in the channel's group | open: every member; **private: current members of that channel's conversation only** |

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

Nothing is built under C3 yet: steps 1-3 sit on C0's conversation model and
W11's table, and neither exists. Building C3's own tables or keys now would
invent those foundations a second time.

## Risks and residuals

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
