# C7: history for new members

**Status: proposed, not built. Needs an independent review before any code**
(key handover, MLS ordering, a migration, a new send format and a signing
ABI are all in it). Written 2026-11-01 against `main` at `f1b4a36`, on K0
and C0. Revision 2 (2026-11-01) made the setting changeable. **Revision 3
(2026-11-01, `main` at `63167ce`) hides the setting from the server** (owner
decisions, round 2): every community message now has the same two-part
shape, history is a property of the key a message body is sealed under, and
the server keeps no flag, sequence or history table.

## Problem

A new member of an MLS group cannot decrypt posts from before their join
epoch (`joined_epoch` withholding). Communities want some channels where
newcomers read the past (rules, announcements, FAQ) and others where they
must not. MLS gives neither, so C7 adds a second layer keyed per channel
(C0: "C7 keys history per channel"). The server must not learn which
channels have it, or when that changes.

## Invariants (check these first)

- **I1. Never retroactive.** A post is readable by later newcomers only if
  its sender's device held the channel as `full` when it sent the post.
- **I2. Fresh key per generation.** Every switch to `full` and every rekey
  makes a new random key. No key is reused.
- **I3. Drop when unsure.** A reader that cannot prove a body falls inside
  a `full` window drops it. Gaps are acceptable; leaks are not.
- **I4. Fail closed toward no history.** Any disagreement about the setting
  (a fork, a rejected record) means: seal new bodies under random keys and
  hand over no key for that channel.
- **I5. Uniform to the server.** Nothing the server stores, serves or
  counts depends on a channel's setting: every community message, every
  membership change and every newcomer's fetch looks the same whichever
  mode each channel is in. The residuals are listed under "What the server
  still learns".

## Core idea: seal once, choose the key

Every application message in a community conversation (`community_shared`
and private-channel groups; posts, actions, records, governance, all of
them) is sent in two parts:

| Part | Content | Who reads it |
|---|---|---|
| **Reference** (the MLS ciphertext) | `"C7R1" \| body_key[32] \| sha256(body)[32]`: 68 bytes, the same for every message | Group members at that epoch, as today |
| **Body** (stored next to the envelope) | `kc[32] \| ChaCha20-Poly1305(K_enc, nonce 0, sig[64] \| VAP1 payload, aad)` | Whoever holds `body_key` |

- The VAP1 payload is today's W7 payload, padded to 256-byte buckets, with
  its context keys; the W7 receive policy runs on it unchanged once the
  body is opened.
- `K_enc = HKDF(body_key, "veritra-c7-enc-v1")`, and the key commitment
  `kc = HKDF(body_key, "veritra-c7-kc-v1")` is checked before decrypting,
  so no body opens to two plaintexts under two keys. Each key seals one
  body, so the nonce is fixed.
- `aad = lp(conversation_id) | lp(channel_id or "") | lp(sender_device_id) | lp(action_id)`,
  the envelope's own fields, so the server cannot move a body.
- **The key is the only difference.** While the sender's device holds the
  channel as `full` in generation `g`:
  `body_key = HKDF(CHK_g, "veritra-c7-post-v1", lp(community_id) | lp(channel_id) | lp(sender_device_id) | lp(action_id))`.
  Otherwise `body_key` is 32 random bytes that exist only inside the
  reference, so the body is readable only by those who could read the MLS
  message. The two cases are indistinguishable without `CHK_g`.
- **Live members** decrypt the reference, check the body hash and open the
  body with `body_key`. They never need `CHK` to read.
- **Newcomers** never see the reference. They fetch bodies, derive
  `body_key` from the `CHK`s they were handed, and open what `kc` matches.
- **Signature** (`sig`), always present, by the sender device's MLS
  credential key over
  `"veritra-c7-post-sig-v1" | lp(community_id) | lp(channel_id) | lp(action_id) | lp(group_id) | u64(epoch) | lp(sender_device_id) | u32(g) | sha256(VAP1 payload)`
  (`g` = 0 outside `full`). Newcomers verify it and the window (decision
  6); live members verify it too, so both see the same signed content. It
  sits inside the encryption, so it adds nothing a member could not
  already prove from the MLS framing signature.
- **Cost.** About 180 bytes more per message (reference plus body header,
  tag and signature), whatever the message size. History is stored once:
  there is no second copy, for `full` channels or any other.

## Decisions

1. **Setting.** Per channel, `members_from_join` (default) or `full`, kept
   only in signed records inside MLS (decision 3). Admins change it
   (`manage_channels`, checked by apps under C4). Before the first post
   under a new setting the channel shows a system line ("New posts can be
   read by people who join later", or the reverse).
2. **Channel history key (`CHK_g`).** 32 random bytes per generation `g`
   (u32, from 1, per channel, strictly increasing). A generation starts at
   a switch to `full`, a rekey, or a move. A *period* runs from a switch to
   `full` (or a widening move) to the next record that leaves `full`.
   Devices keep the current period's keys in the sealed local database and
   delete them when the period ends. Keys never go into K1 backups or K2
   bundles: a restored (D73) or newly linked device is added to the groups
   and gets them like any newcomer (decision 5).
3. **Record chain, carried inside MLS.** One chain per channel. A record is
   a hidden W7 v2 payload, `history_change`, in a message of the channel
   itself (switch, move) or in a slot of `history_sync` (rekey, decision
   5). Fields: `seq` (u32, 0 at creation, +1 each), `prev`
   (`sha256(previous signed bytes | signature)`, zeros at 0), `mode`,
   `reason` (`create`, `switch`, `rekey`, `move`), `g`, `group_id`,
   `epoch` (the actor's), `close_epoch` (for a rekey: the removal commit's
   epoch, else = `epoch`), `chk_commit` (`sha256("veritra-c7-chk-v1" | CHK_g)`
   or zeros), `actor_device_id`. Signed bytes:
   `"veritra-c7-history-v1" | lp(community_id) | lp(channel_id) | u32(seq) | prev | u8(mode) | u8(reason) | u32(g) | lp(group_id) | u64(epoch) | u64(close_epoch) | chk_commit | lp(actor_device_id)`,
   with the credential key (same ABI as the post signature), encoded into
   a fixed 320-byte slot. A switch to `full` puts `CHK_g` in the same body,
   which is sealed under `HKDF(CHK_g, ...)` as above; live members get it
   through `body_key`, and a later newcomer holding `CHK_g` can open it. A
   switch to `members_from_join` seals its body under a random key.
4. **Ordering: sync order plus the `prev` chain** (C4 review,
   recommendation 2). The server cannot sequence records it cannot see.
   - The first valid record with the next `seq`, in the conversation's sync
     order, wins. A later record with a used `seq` is stale and ignored;
     its sender drops it and re-decides on the new state.
   - A sender applies its own record only when it comes back in sync
     order, never at send time. Until then it seals under random keys.
   - Two valid records with the same `seq` and different bytes, or a `prev`
     that does not match, mean the server showed devices different orders:
     by I4 the channel closes (random keys, no handover) and shows an
     error until an admin's new `switch` chains from either branch.
   - A record failing authority under the device's C4 state closes the
     channel locally the same way.
   - Validation on every device: signature, `prev`/`seq`, `g` above every
     earlier `g`, `chk_commit` against the carried key, and authority:
     `switch`/`move` need `can(actor, manage_channels, channelId:)`;
     `rekey` needs only current membership and an unchanged `full` mode.
   - The server can no longer target records: they look like any post.
5. **`history_sync`: one message after every membership commit.** After
   every add or remove commit in any community group, whatever the modes,
   the committer sends one group-level message (no `channel_id`):
   - Reference as usual. Body: `seal(body_key, N × key_c)` followed by `N`
     fixed slots `kc_c | AEAD(HKDF(key_c, "veritra-c7-slot-v1", ids, action_id), slot_c)`,
     one per channel the group carries, in channel-id order. `N` is the
     server-known channel count, so the size is a function of `N` only.
   - For a `full` channel, `key_c` is its current `CHK` and `slot_c` holds
     the latest record. After a **removal**, `key_c` is a new
     `CHK_{g+1}` and `slot_c` holds the new `rekey` record plus
     `CHK_g` (the backward wrap, below). For any other channel, `key_c` is
     random and `slot_c` holds the latest record.
   - **Handover.** Newcomers added by the commit read `key_c` for every
     channel, check it against the slot's `chk_commit`, and so hold the
     current key and setting of each channel in one fixed-size message.
     C3/C4 visibility holds because private channels are their own groups.
   - **Backward wrap.** Each rekey slot is sealed under the new key and
     carries the previous one. A newcomer holding the current `CHK` walks
     back through stored `history_sync` bodies to every generation of the
     current period, and stops at its start: a switch record carries no
     earlier key, so earlier periods stay unreadable (owner, round 2). A
     removed member holds old keys only and learns nothing new.
   - **Removed members.** After applying a removal commit, a device seals
     under random keys until it applies the `rekey` that follows it. The
     window rule (decision 6) closes `g` at `close_epoch`.
   - **Missing or racing.** If no `history_sync` follows a membership
     commit within a minute (committer offline), any member sends one;
     duplicates resolve by sync order per slot. A rekey slot that lost to
     a concurrent switch is not retried on its own (a retry would show the
     server that some channel is `full`); the device keeps the "rekey due"
     note and does it in the next `history_sync`, sealing under random keys
     meanwhile (a gap, I3). A newcomer whose message never arrives sends a
     `history_sync_request` (always, after a timeout, whatever the modes);
     any member answers with a fresh `history_sync`.
6. **Windows.** Generation `g` is open from its starting record's
   `(group_id, epoch)` to the next record's `close_epoch`. A newcomer
   accepts a body sealed under `g` only if the signed `group_id` matches and
   `E_open <= epoch < E_close`. Bodies in the closing epoch are dropped
   (a gap, I3). One exception: a `delete` or `admin_delete` outside the
   window is applied if its author may delete the target, since it carries
   no content; senders seal a delete under the target's generation key
   when they still hold it, so newcomers do not see deleted posts.
7. **What each side reads.**

   | Change | Existing members | Later newcomers |
   |---|---|---|
   | to `full` | Read live, as before; get the key in the record body | Posts from the switch on |
   | to `members_from_join` | Read live, as before; delete the period's keys | Nothing older than their join |
   | off and on again | As above | Only the newest period (round 2) |
   | rekey on removal | Get the new key in `history_sync` | The whole current period, by the backward wrap |

8. **Moves** (C0/C3) are `move` records. A generation lives in one group,
   so a move of a `full` channel starts a new generation in the new group
   (its record wraps the previous key, like a rekey). A move to a narrower
   audience (open to private) continues the period; a wider one (private to
   open) starts a new period with no wrap.
9. **Reading history.** A newcomer prefetches, for **every** channel it can
   see and the group-level stream, the same depth (owner question 1),
   whatever the mode, and discards what no key opens. Opened posts go into
   the local database like any other; paging, unread state and search stay
   local (C0).

## Server: wire, storage, migration

- **Send.** The envelope route (`POST /api/v1/messages/envelopes`) takes a
  `sealed_body` field. It is required on every envelope in a community
  conversation and refused elsewhere; at most 64 KiB + 112 bytes, or
  exactly `48 + 432 × N` for a `history_sync` (outer seal of `N` keys,
  then `N` sealed 352-byte slots: record 320, wrap 32). A community envelope
  carries no server-visible `reply_to_id` or `thread_root_id` (W7 keeps
  references inside the payload; check `mobile/lib/core/models.dart`
  before C7 sends), or a newcomer's reply would show it read a pre-join
  post.
- **Group-level messages.** C0's rule "every `community_shared` envelope
  names an open channel" gains one exception: `history_sync`,
  `history_sync_request` and C4 `governance` carry no `channel_id`. They
  follow membership and governance events whatever the modes. C2's
  per-channel refusal does not apply to them; apps accept only those types
  there.
- **Storage.** Migration (next free number): `envelope_bodies(message_id PK
  REFERENCES message_envelopes, conversation_id, channel_id NULL,
  created_at, expires_at, body BLOB)`, written in the send transaction.
  Sync serves the body with its envelope, read from this table, not copied
  into `sync_events`. Admission limits (D38) count body bytes. Nothing is
  removed: the rev 2 columns (`channels.history*`), the
  `channel_history_blobs` table, the `history_change` side field and 409
  `history_seq_conflict` were never built and are dropped from the design.
- **Pruning.** A body lives exactly as long as its envelope: the
  conversation's retention (and per-channel retention, D51) sets
  `expires_at` for every message alike; the sweeper and the server delete
  route (C5 admin delete) remove both. Switching to `members_from_join` no
  longer deletes anything on the server, which would reveal the switch.
  Earlier periods stay unreadable because their keys are never handed over
  and members delete them; the confirm dialog says: "People who join later
  won't see earlier posts. Members who already have them keep them."
- **History fetch.** `GET /api/v1/conversations/{id}/history?channel_id=&before=&limit=`
  returns `{message_id, sender_device_id, action_id, channel_id,
  created_at, epoch, body}` for unexpired, undeleted envelopes the calling
  device was not a member for (before its `joined_after_event_id`), to
  current member devices only, the same for every channel and mode.
  References are never served there.
- **Authority.** The server cannot check mode changes. Apps check them
  under C4 (built-in roles, owner decision); old owner question 4 is moot.

## What the server still learns

| Signal | What it shows | Cost to remove |
|---|---|---|
| A newcomer fetching deeper than the fixed prefetch, in some channels only | Those channels are `full`, and roughly since when | Never page deeper than the fixed depth (newcomers see at most that much), or prefetch all retained history of every channel (download cost per join). Owner question 1 |
| A newcomer downloading a pre-join attachment | That post's channel was `full` then | Prefetch every pre-join attachment within the depth for every channel (large), or never offer pre-join attachments. Owner question 2 |
| Message sizes | The W7 256-byte bucket, as today; records, `history_sync` and handovers have fixed shapes | Coarser padding (L2) |
| A `history_sync` from a second sender | A committer went offline; no mode information | None needed |
| Timing of an admin's switch | A hidden message from an admin, like any short post | None needed |

The fetch pattern is the one real leak; the defaults below close it at the
cost of how much history a newcomer can see.

## Interaction with MLS and C4

- No extra commit for a switch; records are application messages. Removal
  commits trigger `rekey` (inside `history_sync`); adds never rekey.
- Records and bodies from a past epoch are applied within OpenMLS's
  past-epoch window; outside it they are lost (a gap, I3).
- A private-channel post is judged against the shared group's C4 state at
  receipt; the two groups have no common order (C4 review residual).
- A role change that adds or removes members of a private channel's group
  is a membership commit and so is followed by `history_sync`.

## Trust limits

- A newcomer verifies signatures, the chain, key commitments and windows,
  but cannot check C4 authority for records older than its join; it trusts
  the member who sent its `history_sync`, which could also withhold keys.
- A malicious member could stretch a window it describes; it can only
  expose posts real senders sealed under a `full` generation, which that
  member could already read and leak.
- Until L1, a server that adds a hidden device can read new live posts and
  forge history from that device: the same limit as live groups today.

## What it does not give

- No forward secrecy for history: a `CHK` holder reads its generation.
- A member who leaves keeps what it could read; switching off cannot
  recall copies on devices.
- History is lost if every key holder is gone (accepted, round 1), and is
  bounded by retention.

## Protocol changes (all additive, none made yet)

- **Send format.** Every community message is reference + body (core idea);
  `"C7R1"` replaces VAP1 as the MLS plaintext in community conversations,
  and the receive policy treats anything else there as `invalid`. No
  release exists, so no compatibility path (C0 recreates demo
  communities).
- **W7 types** (hidden): `history_change`, `history_sync`,
  `history_sync_request`. Belongs to the W7 section of `docs/crypto.md`.
- **Rust ABI 12** (approved, needs independent review): credential-key
  `sign`/`verify` over a domain-separated message with a fixed domain
  allowlist (C7's two prefixes; C4 takes the same export), and
  `c7_seal`/`c7_open` (HKDF-SHA256, key commitment, ChaCha20-Poly1305).
  The core exposes no MLS exporter today; C7 does not need one.
- **Server:** `sealed_body` on the envelope route, `envelope_bodies`, the
  history route, the group-level exception.
- **Local DB:** current-period keys, the record chain head and "rekey due"
  per channel, in the sealed database; not in backups or K2 bundles.

## Build order

1. Independent review of this revision.
2. Rust ABI 12 with vectors `testing/vectors/c7-*.json` (bodies, slots,
   records, windows), checked by Rust, Go and Dart.
3. Server: migration, `sealed_body`, history route, group-level exception.
4. Dart: two-part send/receive for all community messages, records and
   chain, `history_sync`, backward walk, prefetch.
5. Flows and tests: two devices, leave, switch both ways, off/on, racing
   switch and rekey, forked chain, lost committer, and a server-side test
   that a `full` and a `members_from_join` channel produce identical rows
   and requests.

Depends on: C0 layout, C1 per-conversation sync halting, C3 channel state
and moves, C4 `manage_channels`, C5 deletes.

## Open questions for the owner

Earlier questions: 1 (off/on) and 2 (server sees the flag) are answered in
round 2; 3 (ABI) is approved; 4 (server-checked admins) is moot.

1. **Newcomer history depth.** The same prefetch for every channel hides
   the setting. Proposed: the latest 1,000 posts or 8 MiB per channel,
   whichever comes first, and no deeper paging. Alternatives: deeper
   paging on demand (shows the server that the channel is `full`), or all
   retained history for every channel (no leak, more download per join).
2. **Pre-join attachments.** Downloading one shows the server the channel
   was `full`. Proposed: offer them on tap with that cost accepted.
   Alternatives: never offer them, or prefetch them all within the depth.
3. **`history_sync` cost.** One message of about 430 bytes per channel
   after every join and removal in every community group (about 13 MB of
   egress per membership commit at 1,000 devices and 30 open channels,
   against 0.6 MB for the add commit itself; C0 batches joins).
   Accept, or add targeted delivery of add-time messages to the new
   devices only (a server feature, C8)?

## Owner decisions (2026-11-01)

- The history setting may be changed later by admins (needs re-keying rules; revisit the design).
- Accepted: history copies double stored bytes for full-history channels, and history is lost if every key holder is gone.

## Owner decisions, round 2 (2026-11-01)

- Earlier `full` periods stay unreadable to newcomers after a switch off and on.
- The server must **not** see the history flag: hide it (needs a design change; the sequence/flag handling above assumes server visibility).
- Crypto ABI additions approved, with independent review.
