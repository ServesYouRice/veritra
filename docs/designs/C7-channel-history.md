# C7: history for new members

**Status: proposed, not built. Needs an independent review before any code**
(key handover, MLS ordering, a migration and a signing ABI are all in it).
Written 2026-11-01 against `main` at `f1b4a36`, on K0 and C0. Revision 2
(2026-11-01): the history setting may change after creation (owner decision
below); decisions 1, 4, 6 and 8 are reworked and 10 to 14 are new.

## Problem

A new member of an MLS group cannot decrypt posts from before their join
epoch (`joined_epoch` withholding, D-series). Communities want some channels
where newcomers read the past (rules, announcements, FAQ) and others where
they must not. MLS gives neither, so C7 adds a second layer that is keyed per
channel, not per group (C0: "C7 keys history per channel").

## Invariants (check these first)

- **I1. Never retroactive.** A post is readable by later newcomers only if
  its sender's device believed the channel was `full` when it sent the post.
  Switching `members_from_join` to `full` exposes nothing posted before the
  switch: no history copy exists for those posts, and no device makes one
  later.
- **I2. Fresh key per period.** Every switch to `full` makes a new random
  key. No key from an earlier period is ever reused.
- **I3. Drop when unsure.** A reader that cannot prove a history copy falls
  inside a `full` window drops it. Gaps are acceptable; leaks are not.
- **I4. Fail closed toward no history.** Any disagreement about the setting
  (a fork, a rejected record, an unknown record) means: upload no history
  copies and hand over no keys for that channel.

## Decisions

1. **Per-channel setting `history`, changeable by admins.**
   `members_from_join` (default; newcomers read nothing older) or `full`
   (newcomers read posts from the current `full` period). Set at creation
   and changed later only through a signed record (decision 10). It lives in
   the channel's encrypted state and is mirrored as a clear flag on the
   channel row, because the server must know whether to accept and serve
   history copies. Before the first post under a new setting, the channel
   shows a system line ("New posts can be read by people who join later" or
   the reverse), so senders know the rule they post under.
2. **Channel history key (CHK).** For a `full` period, 32 random bytes per
   *generation* `g`, made by the device that starts the generation.
   Generations are numbered per channel, strictly increasing, never reused.
   Independent of MLS epochs and of any account's recovery key (K0).
3. **History blob.** For each post sent while the sender's device holds the
   channel as `full`, the device uploads, next to the normal MLS message, one
   extra object:
   `blob = AEAD(key = HKDF(CHK_g, "veritra-c7-post-v1" | channel_id | post_id), nonce, W7 payload, aad = channel_id | post_id | g | sender_device_id)`.
   The server stores it as ciphertext with `channel_id`, `post_id`, `g`. No
   plaintext, no new content-search path. If the server refuses the blob
   (flag off, old generation), the post itself still goes; the device does
   not retry the blob.
4. **Signed posts, bound to the epoch.** The sender's device signs, with its
   MLS credential signing key,
   `"veritra-c7-post-sig-v1" | lp(community_id) | lp(channel_id) | lp(post_id) | u32(g) | lp(group_id) | u64(epoch) | lp(sender_device_id) | sha256(blob)`,
   where `(group_id, epoch)` is the MLS group and epoch the post was sent in.
   The signature ships in the blob header. A newcomer verifies it, that the
   device belongs to the claimed account, and the window rule (decision 11)
   before showing a post. Until L1 (signed approved-device list) exists, the
   device-to-account binding is what the group's credentials give, so a
   server that adds a hidden device could forge history from it: the same
   limit as live groups today, stated to users by L1, not solved here.
5. **Handover.** After a join commit applies, one existing member (the
   committer, so no election) sends the newcomer, inside the group as a W7
   control payload `history_keys`, for every channel the newcomer can see:
   the signed records (decision 10) from the one that started the current
   period, or only the latest record if the setting is `members_from_join`;
   and, only for `full` channels, the keys of the current period's
   generations (decision 12). The first record's `prev` is an anchor the
   newcomer does not verify back to `seq` 0, so the handover stays bounded
   by the current period. A period with many rekeys is split across several
   `history_keys` messages, each under the W7 size limit. C4/C3 visibility applies; a private
   channel's keys go only through that channel's group. The receiver accepts
   it only from a current member of that group and only for channels of this
   community; a key whose hash does not match its record's `chk_commit` is
   rejected and logged without the key. If the committer is offline, any
   other member may answer a `history_keys_request` (also an MLS payload).
   After a restore (K0), keys that arrived since the last backup come from
   this same request.
6. **New key on leave.** After a removal commit (leave, kick, ban) in a group
   that carries `full` channels, the committer sends a `rekey` record
   (decision 10) with `CHK_{g+1}` per affected channel, inside the
   post-removal epoch. The removed member keeps old generations (it was
   entitled to those posts) and cannot derive new ones. Until a device has
   applied a `rekey` newer than the removal commit, it uploads no blobs for
   that channel; if none has arrived by its next post, it sends the `rekey`
   itself (the server's sequence check, decision 13, lets exactly one win).
   A member offline during the commit gets `g+1` by `history_keys_request`.
7. **Reading history.** A newcomer with the keys fetches blobs for a channel
   page by page, decrypts and verifies locally, and stores the posts in the
   local database like any other. Paging, unread state and search stay local
   (C0). A device that joined later via K2 gets the keys and chains in the
   K2 bundle's explicit versioned field (K2 design) and in K1 backups.
8. **Moving a channel** (C0) is a `move` record. A generation lives in one
   MLS group only, so a move of a `full` channel starts a new generation in
   the new group. A move to a narrower audience (open to private) continues
   the current period; a move to a wider one (private to open) starts a new
   period, because senders of the private posts never agreed to every
   community newcomer reading them.
9. **`members_from_join` periods** upload no blob and hold no current CHK.

### Changing the setting

10. **One signed record chain per channel.** Every change is a W7 control
    payload `history_change`, sent inside the channel's group:

    | Field | Meaning |
    |---|---|
    | `seq` | u32; 0 is the record made with the channel; each next is +1 |
    | `prev` | `sha256(previous record's signed bytes | signature)`; 32 zero bytes at `seq` 0 |
    | `mode` | `members_from_join` or `full` |
    | `reason` | `create`, `switch`, `rekey` or `move` |
    | `g` | the new generation (only when `mode` is `full`) |
    | `group_id`, `epoch` | the actor's MLS group and epoch when sending |
    | `chk_commit` | `sha256("veritra-c7-chk-v1" | CHK_g)`, or zeros |
    | `actor_device_id` | the signing device |

    Signed bytes: `"veritra-c7-history-v1" | lp(community_id) | lp(channel_id) | u32(seq) | prev | u8(mode) | u8(reason) | u32(g) | lp(group_id) | u64(epoch) | chk_commit | lp(actor_device_id)`,
    signed with the actor device's credential key (same ABI as decision 4).
    The key `CHK_g` rides in the same MLS payload, outside the signed bytes;
    the commitment lets a newcomer check a key handed over later.
11. **Windows.** Generation `g` is open from the record that starts it, at
    `(group_id, E_open)`, until the next record of the chain, at `E_close`.
    A reader accepts a blob of generation `g` only if its signed `group_id`
    equals the generation's and `E_open <= epoch < E_close` (no upper bound
    while open). A post in the same epoch as the closing record is dropped
    even if it was sent before it: a small gap, by I3. This lets readers
    place posts against changes without trusting the server's order.
12. **Periods and what each side reads.** A *period* is the run of
    generations from one `create` or `switch` to `full` (or a widening
    `move`) up to the next record that leaves it.

    | Change | Existing members | Later newcomers |
    |---|---|---|
    | `members_from_join` to `full` | Read everything they read before (live MLS); get the new key in the record | Read posts from this switch on; nothing from before (I1) |
    | `full` to `members_from_join` | Read everything they read before; keep their keys | Read nothing older than their join; get no keys |
    | `full` to `members_from_join` to `full` | As above | Read only the newest period (owner question 1) |
    | `rekey` on leave | Get the new key | Read the whole current period (all its generations) |

    A member who joined during a `members_from_join` period gets, at a later
    switch to `full`, only the new period's keys, as a newcomer would.
    Switching to `members_from_join` also deletes the channel's stored blobs
    on the server, since no one will be handed their keys again; members'
    local copies stay. The confirm dialog says so and says that switching
    back does not bring them back.
13. **Server serializes the chain.** The record goes through the normal send
    route with a clear side field `history_change: {expected_seq, mode, g}`.
    In the transaction that stores the MLS message the server checks
    `expected_seq == channels.history_seq`, then sets the flag, `seq + 1` and
    the current `g`, and (on a switch to `members_from_join`) queues the
    channel's blobs for deletion. A mismatch answers 409
    `history_seq_conflict`; the sender re-reads the chain and re-decides
    (a remover whose `rekey` lost to a switch to `members_from_join` drops
    it). A mode change needs the server-visible role `owner` or `admin` in
    the community; a `rekey` (mode stays `full`, flag already on) is open to
    any member of the channel's group. Afterwards the server refuses blobs while the flag
    is off and blobs of a generation older than the current one. This closes
    C4 owner question 2 for history records only: governance records still
    rely on sync order.
14. **Validating a record (every receiving device).** Signature, `prev` and
    `seq` chain, `g` greater than every earlier `g`, `chk_commit` matches the
    carried key, and authority under the C4 state the device holds:
    `switch` and `move` need `can(actor, manage_channels, channelId:)`;
    `rekey` needs only current membership and an unchanged `full` mode. Two
    valid records with the same `seq` and different bytes are a fork: by I4
    the channel stays closed (no uploads, no handover) and shows an error
    until an admin sends a new `switch`, which devices accept chaining from
    either branch. A record a device rejects on authority puts that channel
    in the same closed state locally.

## Interaction with C4 roles

- Changing the setting is a `manage_channels` action (C4 switch list). The
  owner and `administrator` holders pass; a channel override cannot grant it
  (it is group-wide).
- The server sees built-in roles only (C4 owner question 1), so a custom
  role with `manage_channels` but no built-in `admin` is refused by the
  server. Apps still check the full C4 rule.
- A role change that grants or removes `view_channel` on a private channel
  adds or removes members of that channel's group, which triggers the
  handover (decision 5) or a `rekey` (decision 6).
- A demotion racing a switch can make devices disagree about authority
  (C4 question 2). By I4 the disagreeing devices only stop history; nothing
  leaks, and the next valid `switch` realigns them.

## Interaction with MLS epochs

- No extra commit is needed for a switch; the record is an application
  message in the current epoch, and blobs and records carry `(group_id,
  epoch)` so readers order them (decision 11).
- Removal commits are what trigger `rekey`; adds never rekey.
- Records and blobs from a past epoch that arrive after a commit are still
  applied within OpenMLS's past-epoch window; outside it they are lost
  (a gap, I3).

## Trust limits

- A newcomer verifies signatures, the chain, key commitments and windows,
  but cannot check C4 authority for records older than its join: it trusts
  the member who hands over the chain for that, as it already trusts that
  member to hand over keys at all (it may also withhold them).
- A malicious hander could stretch a window it describes; it can only
  expose posts that real senders signed under a `full` generation, which
  that member could already read and leak.

## What it does not give

- Not forward secrecy for history: anyone holding a CHK reads every post of
  that generation. That is the product choice of a `full` channel.
- A member who leaves still reads what they already could; C7 cannot recall
  it. The same holds for switching to `members_from_join`: copies already on
  devices stay.
- Per-channel retention removes history for newcomers; gaps are fine because
  each blob is independent (no ratchet).
- Message deletion by moderators (C5) must also delete the blob.

## Protocol changes (all additive, none made yet)

- W7: three control payload types, `history_change`, `history_keys` and
  `history_keys_request`; the existing `channel_id` context key applies.
  Belongs to the W7 section of `docs/crypto.md`, so C7 build adds them there.
- Rust ABI: one function to sign and verify with the credential key over a
  caller-built, domain-separated message (ABI 12, next free), plus HKDF/AEAD
  for blobs; or reuse of existing exports if the review prefers.
- Server: migration for `channel_history_blobs(channel_id, post_id,
  generation, sender_device_id, blob)` and columns `channels.history`,
  `channels.history_seq`, `channels.history_generation`; the side field on
  the send route; a paged fetch route for current members of the channel's
  group, refused while the flag is off; blob size capped at the W7 message
  limit plus header.
- Local DB: tables for `(channel_id, generation, key)` and the record chain
  inside the sealed database; included in K1 backups and K2 bundles.

## Build order

1. Review of this design (owner questions below).
2. Rust: signing export and blob AEAD with test vectors
   (`testing/vectors/c7-*.json`, records, windows and blobs, checked by Rust,
   Go and Dart).
3. Dart: payload types, chain validation, key store (schema bump), handover,
   switch and rekey logic.
4. Server: migration, side field with the sequence check, blob upload,
   paged fetch, deletion hooks.
5. Flows: create-channel switch, change-setting dialog, newcomer history
   view; tests for two devices, leave, switch both ways, a racing switch and
   rekey, and a forked chain.

Depends on: C0 layout (done), C3 for the encrypted channel state and moves,
C4 for `manage_channels` and visibility, C1 for per-conversation sync
halting, and C5 for blob deletion.

## Open questions for the owner

1. After `full` to `members_from_join` and back to `full`, may newcomers
   read the earlier `full` periods too? Proposed: no; switching off deletes
   the server copies, so the earlier posts stay with the members who have
   them.
2. May the server see which channels keep history and when that changes
   (the flag and its sequence number)? Needed to store and stop blobs;
   proposed yes, as it knows `channel_id` already (D51).
3. New ABI function for credential-key signing: acceptable, or require
   L1's account-level signing key first?
4. Only built-in admins can change the setting through the server (custom
   roles with `manage_channels` are refused, C4 question 1). Accept?

## Owner decisions (2026-11-01)

- The history setting may be changed later by admins (needs re-keying rules; revisit the design).
- Accepted: history copies double stored bytes for full-history channels, and history is lost if every key holder is gone.

## Owner decisions, round 2 (2026-11-01)

- Earlier `full` periods stay unreadable to newcomers after a switch off and on.
- The server must **not** see the history flag: hide it (needs a design change; the sequence/flag handling above assumes server visibility).
- Crypto ABI additions approved, with independent review.
