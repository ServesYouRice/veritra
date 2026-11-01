# C7: history for new members

**Status: proposed, not built. Needs an independent review before any code**
(key handover, MLS ordering, a migration and a signing ABI are all in it).
Written 2026-11-01 against `main` at `f1b4a36`, on K0 and C0.

## Problem

A new member of an MLS group cannot decrypt posts from before their join
epoch (`joined_epoch` withholding, D-series). Communities want some channels
where newcomers read the past (rules, announcements, FAQ) and others where
they must not. MLS gives neither, so C7 adds a second layer that is keyed per
channel, not per group (C0: "C7 keys history per channel").

## Decisions

1. **Per-channel setting `history`, fixed at channel creation.**
   `members_from_join` (default; newcomers read nothing older) or
   `full` (newcomers read all posts). It lives in the channel's encrypted
   metadata (C3) and is also a clear flag on the channel row, because the
   server needs it to decide whether to keep and serve history blobs. The
   server already knows `channel_id`, so this adds one bit of metadata.
   It cannot be changed afterwards: switching `members_from_join` to `full`
   would hand out posts members were told were private. A new channel must
   be created instead (owner question 1).
2. **Channel history key (CHK).** For a `full` channel, 32 random bytes per
   *generation* `g` (starting at 0), made by the channel creator's device.
   It is independent of MLS epochs and of any account's recovery key (K0).
3. **History blob.** For each post in a `full` channel the sending device
   uploads, next to the normal MLS message, one extra object:
   `blob = AEAD(key = HKDF(CHK_g, "veritra-c7-post-v1" | channel_id | post_id), nonce, W7 payload, aad = channel_id | post_id | g | sender_device_id)`.
   The server stores it as ciphertext, with the post's `channel_id`,
   `post_id` and `g`. No plaintext, no new content-search path.
4. **Signed posts.** The sender's device signs, with its existing MLS
   credential signing key,
   `"veritra-c7-post-sig-v1" | lp(community_id) | lp(channel_id) | lp(post_id) | u32(g) | lp(sender_device_id) | sha256(blob)`
   and ships the signature inside the blob header. Live posts are already
   authenticated by MLS; the signature is for history, where the reader has
   no MLS epoch to check. A newcomer verifies it, and that the device
   belongs to the claimed account, before showing a post. Until L1 (signed
   approved-device list) exists, the device-to-account binding is what the
   group's credentials give, so a server that adds a hidden device could
   forge history from it: the same limit as live groups today, stated to users
   by L1, not solved here.
5. **Handover.** After a join commit applies, one existing member (the
   committer, so no election) sends the newcomer, inside the group as a W7
   control payload `history_keys`, all `(channel_id, g, CHK_g)` the newcomer
   may read: every generation of every `full` channel they can see (C4/C3
   visibility applies; a private channel's keys go only through that
   channel's group). Rules: the receiver accepts it only from a current
   member of that group and only for channels of this community; an
   unknown or duplicate `(channel_id, g)` with a different key is rejected
   and logged without the key. If the committer is offline, any other member
   may answer a newcomer's `history_keys_request` (also an MLS payload).
   After a restore (K0), keys that arrived since the last backup come from
   this same request.
6. **New key on leave.** After a removal commit (leave, kick, ban) in a group
   that carries `full` channels, the remover (the committer) makes
   `CHK_{g+1}` per affected channel and sends it to the remaining members
   inside the post-removal epoch. New posts use `g+1`. The removed member
   keeps old generations (they were entitled to those posts) and cannot
   derive new ones. The server refuses to serve a blob of a generation to an
   account that was not a member when that generation began *only as
   defence in depth*: the real boundary is the key.
   A member who cannot yet decrypt `g+1` (offline during the commit) gets it
   by the next MLS epoch's `history_keys_request`.
7. **Reading history.** A newcomer with the keys fetches blobs for a channel
   page by page, decrypts and verifies locally, and stores the posts in the
   local database like any other. Paging, unread state and search stay local
   (C0). A device that joined later via K2 gets the keys in the K2 bundle's
   explicit versioned field (K2 design) and in K1 backups.
8. **Moving a channel** (C0): the CHK and blobs follow `channel_id`, not the
   group, so open-to-private keeps old history readable to those who had it.
9. **`members_from_join` channels** upload no blob and hold no CHK.

## What it does not give

- Not forward secrecy for history: anyone holding a CHK reads every post of
  that generation. That is the product choice of a `full` channel.
- A member who leaves still reads what they already could; C7 cannot recall it.
- Per-channel retention (server deletes old blobs) removes history for
  newcomers, and gaps are fine because each blob is independent (no ratchet).
- Message deletion by moderators (C5) must also delete the blob.

## Protocol changes (all additive, none made yet)

- W7: two control payload types, `history_keys` and `history_keys_request`;
  the existing `channel_id` context key applies. Belongs to the W7 section
  of `docs/crypto.md`, so C7 build adds them there.
- Rust ABI: one new function to sign with the credential key over a
  caller-built, domain-separated message (ABI 12, next free), plus HKDF/AEAD
  for blobs; or reuse of existing exports if the review prefers.
- Server: migration for `channel_history_blobs(channel_id, post_id,
  generation, sender_device_id, blob)` and a paged fetch route, both gated
  on the channel's `history` flag and group membership; blob size capped at
  the W7 message limit plus header.
- Local DB: table for `(channel_id, generation, key)` inside the sealed
  database; included in K1 backups and K2 bundles.

## Build order

1. Review of this design (owner questions below).
2. Rust: signing export and blob AEAD with test vectors
   (`testing/vectors/c7-*.json`, checked by Rust, Go and Dart).
3. Dart: payload types, key store (schema bump), handover and rekey logic.
4. Server: migration, upload with the message, paged fetch, deletion hook.
5. Flows: create-channel switch, newcomer history view, two-device and
   leave tests.

Depends on: C0 layout (done), C3 for the encrypted channel setting, C4 for
visibility, C1 for per-conversation sync halting, and C5 for blob deletion.

## Open questions for the owner

1. May a channel's `history` setting change later (only `full` to
   `members_from_join`, for future posts)? Proposed: no.
2. May the server see which channels keep history (one bit per channel)?
   Needed to store blobs; proposed yes, as it knows `channel_id` already.
3. Cost choice: history blobs double the stored bytes of `full` channels.
   Acceptable, or limit `full` to announcement-style channels?
4. If every member who had a key is gone, history is lost to newcomers.
   Accept, or hold a key with the instance owner (rejected here: it breaks
   end-to-end)?
5. New ABI function for credential-key signing: acceptable, or require
   L1's account-level signing key first?
