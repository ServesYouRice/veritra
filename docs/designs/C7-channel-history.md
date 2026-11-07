# C7: history for new members

**Status: proposed, not built. Needs an independent review before any code**
(key handover, MLS ordering, a migration, a new send format and new crypto
ABI are all in it). Written 2026-11-01 against `main` at `f1b4a36`, on K0
and C0. Revision 2 (2026-11-01) made the setting changeable. Revision 3
(2026-11-01, `main` at `63167ce`) hid the setting from the server.
**Revision 4 (2026-11-07, `main` at `f23e456`)** answers the independent
review of revision 3 ([evidence](../../testing/evidence/C7-rev3-review.md)):
a removal floor and a membership barrier close the removal-then-add race,
one ordering table replaces the contradicting rules, an "unsure" state
covers lost records, signatures get a verifiable key, targeted actions
follow their target's period, and authority follows D80's built-in roles.
"Changes in revision 4" at the end maps each review item to its fix.

## Problem

A new member of an MLS group cannot decrypt posts from before their join
epoch (`joined_epoch` withholding). Communities want some channels where
newcomers read the past (rules, announcements, FAQ) and others where they
must not. MLS gives neither, so C7 adds a second layer keyed per channel
(C0: "C7 keys history per channel"). The server must not learn which
channels have it, or when that changes.

## Invariants (check these first)

- **I1. Never retroactive.** A post is readable by later newcomers only if
  its sender's device held the channel as `full`, with a fresh generation,
  when it sent the post.
- **I2. Fresh key per generation.** Every generation starts with a new
  random key. No key is reused.
- **I3. Drop when unsure.** A reader that cannot prove a body falls inside
  a `full` window drops it. Gaps are acceptable; leaks are not.
- **I4. Fail closed toward no history.** Any disagreement about the setting
  (a fork, a missed record) means: seal new bodies under random keys and
  hand over no key for that channel.
- **I5. Uniform to the server.** Nothing the server stores, serves, counts
  or sees the timing of depends on a channel's setting: every community
  message, membership change, retry and newcomer fetch looks the same
  whichever mode each channel is in. Residuals are listed under "What the
  server still learns".
- **I6. Removed members get nothing new.** No key that a removed member
  could have read is used to seal, or handed over, at or after the epoch
  its removal produced (decision 5).

## Core idea: seal once, choose the key

Every application message in a community conversation (`community_shared`
and private-channel groups) is sent in two parts:

| Part | Content | Who reads it |
|---|---|---|
| **Reference** (the MLS ciphertext) | `"C7R1" \| body_key[32] \| sha256(sealed_body)[32]`: 68 bytes, the same for every message | Group members at that epoch, as today |
| **Body** (stored next to the envelope) | `kc[32] \| nonce[12] \| AES-256-GCM(K_enc, nonce, sig[64] \| padded VAP1, aad)` | Whoever holds `body_key` |

- **Primitives** (owner question A): `HKDF(k, label, info)` is
  HKDF-SHA256 with `salt = label`, `ikm = k`, 32 bytes of output, reached
  through the OpenMLS crypto provider as `crypto/rust/src/report.rs:97-100`
  does. AEAD is AES-256-GCM through the direct `aes-gcm =0.11.1`
  dependency. Every AEAD key is derived per message (it binds `action_id`)
  and used exactly once, so a random 96-bit nonce is safe. No new crate.
- `K_enc = HKDF(body_key, "veritra-c7-enc-v1", "")` and the key commitment
  `kc = HKDF(body_key, "veritra-c7-kc-v1", "")`, checked before decrypting,
  so no body opens to two plaintexts under two keys. Because `body_key` is
  per message, `kc` never repeats across messages in any mode.
- **The VAP1 payload** is today's W7 payload with its context keys, framed
  and padded by `app_payload.dart` to 256-byte buckets. The W7 receive
  policy runs on it unchanged once the body is opened.
- **A bad body never halts sync.** Once the reference decrypts, a missing
  body, a hash or `kc` mismatch, a failed open or a bad signature is a P1
  `invalid` row: the MLS state and cursor commit (otherwise a server that
  strips one body would stop the conversation under I33). It also makes
  the group "unsure" (decision 5).
- `aad = lp(conversation_id) | lp(channel_id or "") | lp(sender_device_id) | lp(action_id)`,
  the envelope's own fields, so the server cannot move a body. `lp(x)` is
  a u16 big-endian length then the bytes, in every C7 encoding.
- **The key is the only difference.** While the sender's device holds the
  channel as `full` in a fresh generation `g` (decision 5):
  `body_key = HKDF(CHK_g, "veritra-c7-post-v1", lp(community_id) | lp(channel_id) | lp(sender_device_id) | lp(action_id))`.
  Otherwise `body_key` is 32 random bytes that exist only inside the
  reference. The two cases are indistinguishable without `CHK_g`.
  Targeted actions follow their target's period instead (decision 7).
- **Live members** decrypt the reference, check the body hash, open the
  body with `body_key` and verify `sig`. They never need `CHK` to read.
- **Newcomers** never see the reference. They fetch bodies, derive
  candidate `body_key`s from the `CHK`s they hold, and open what `kc`
  matches.
- **Signature** (`sig`), always present, Ed25519 by the sender device's
  MLS credential key over
  `"veritra-c7-post-sig-v1" | lp(community_id) | lp(channel_id) | lp(action_id) | lp(group_id) | u64(epoch) | lp(sender_device_id) | u32(g) | sha256(padded VAP1)`.
  `epoch` is the epoch the reference is encrypted in, `g` is 0 outside a
  fresh `full` generation, and the hash covers the whole padded VAP1
  value, random padding included. Who checks it with which key is
  decision 8.
- **Retries are byte-identical.** The sender seals once, keeps the sealed
  body in the outbox record next to the MLS ciphertext, and resends both
  unchanged. An `action_id` is never sealed twice. The server's replay
  check compares the body too (server section).
- **Cost.** 124 bytes of body framing (commitment 32, nonce 12, tag 16,
  signature 64) plus the 68-byte reference, whatever the message size.
  History is stored once: no second copy, in any mode.

## Decisions

1. **Setting.** Per channel, `members_from_join` (default) or `full`, kept
   only in signed records inside MLS (decision 3). The creator picks it at
   creation; afterwards admins and the owner change it (D80). Before the
   first post under a new setting the channel shows a system line ("New
   posts can be read by people who join later", or the reverse).

2. **Generations and periods.** A *generation* `g` (u32 per channel,
   strictly increasing, from 1) has one key `CHK_g` (32 random bytes) and
   lives in one MLS group. It starts at a switch to `full`, a create as
   `full`, a rekey or a move. A *period* runs from a switch to `full` (or
   a create as `full`, or a widening move) to the next record that leaves
   `full`; it holds one or more generations. Devices keep the current
   period's keys in the sealed local database and delete them when the
   period ends. Keys never go into K1 backups or K2 bundles: the C7 tables
   are added to `mobile/lib/storage/backup_exclusion.dart` and left out of
   `mobile/lib/storage/history_snapshot.dart`, with a test for each. A
   restored (D73) or newly linked device is added to the groups and gets
   keys like any newcomer.

3. **Records.** One chain per channel. A record is a hidden W7 v2 payload,
   `history_change`, proposed either in a message of the channel itself
   (create, switch, move) or in a slot of a `history_sync` (rekey). Fields
   and their fixed encoding (all ids at most 64 bytes; C7 refuses longer
   ones, server ids are 36):

   ```
   u8 version (=1) | lp(community_id) | lp(channel_id) | u32 seq | prev[32]
   | u8 mode | u8 reason | u32 g | lp(group_id) | u64 epoch
   | lp(close_group_id) | u64 close_epoch | chk_commit[32]
   | lp(actor_device_id) | sig[64]
   ```

   - `seq`: 0 for `create`, +1 each record. `prev`: zeros at 0, else
     `sha256(previous record's encoded bytes, sig included)`.
   - `mode`: 0 `members_from_join`, 1 `full`. `reason`: 0 `create`,
     1 `switch`, 2 `rekey`, 3 `move`.
   - `g`: the generation this record opens; for a record that leaves
     `full`, the last generation + 1 (no key), so `g` rises on every record
     that opens or closes.
   - `group_id`, `epoch`: the group and epoch of the message that carries
     the proposal. A receiver checks both against the MLS message.
   - `close_group_id`, `close_epoch`: where and when the previous
     generation stops being valid (window end, decision 6). For a switch
     or create: this group and `epoch`. For a rekey: this group and the
     generation's `stale_since` (decision 5). For a move: the old group
     and the old group's epoch when the actor sent the move.
   - `chk_commit`: `sha256("veritra-c7-chk-v1" | CHK_g)`, or zeros when the
     record opens no key.
   - `sig`: Ed25519 by the actor's credential key over
     `"veritra-c7-history-v1"` followed by every field above except `sig`.
   - The encoding is zero-padded to **512 bytes** (the maximum is 485).
   - **Always the same shape.** A record message always carries a 32-byte
     key field: `CHK_g` when it opens a key, 32 random bytes otherwise, so
     a switch on and a switch off fall in the same VAP1 bucket. A switch
     to `full` seals its body under `HKDF(CHK_g, ...)` like any post of
     `g`, so a later newcomer holding `CHK_g` reads it; any other record
     message seals under a random key.
   - **Create.** Every channel creation sends a `create` record, in both
     modes. A channel for which a device holds no record is
     `members_from_join` with no head: the "implicit genesis" the vectors
     pin. The next record it sees is handled by row 1 of the ordering
     table.

4. **Ordering: sync order plus the `prev` chain.** The server cannot
   sequence records it cannot see. Each device keeps per channel a *head*
   (the last applied record), the hashes of the records it has applied in
   the current period, and a *status*: `ok`, `unsure` or `closed`.

   A record is a **proposal** in the one message whose MLS-authenticated
   sender is the record's `actor_device_id` and whose epoch and group equal
   the record's `epoch` and `group_id`. Anywhere else (a `history_sync`
   slot repeating the sender's head) it is a **report**.

   Validity first: encoding, signature, `chk_commit` against the carried
   key, `g` above every earlier `g`, and authority (below). An invalid
   record is ignored and leaves an `action` row. If the device's own
   proposal comes back invalid, or not at all within a timeout, the app
   tells the actor the change did not go through.
   Then, for a valid record `X` against head `H` (`s` = `H.seq`), in sync
   order, exactly one row applies:

   | # | Condition | Result |
   |---|---|---|
   | 1 | No head (newcomer, or implicit genesis) | Adopt `X` as head |
   | 2 | `X` equals (byte for byte) the record applied at `X.seq` | No-op |
   | 3 | `X.seq = s + 1` and `X.prev = hash(H)` | Apply: new head |
   | 4 | Proposal, `X.seq <= s`, and `X.prev` equals the `prev` of the record applied at `X.seq` | Lost race: stale, ignore. Its sender discards its key and re-decides on the new state |
   | 5 | A `switch` or `move` proposal received live (not from a slot or the history fetch), authority checked, and either `X.seq > s` or status `closed` | Adopt `X` as head, status `ok` (recovery: the record states the whole setting) |
   | 6 | `X.seq <` the first seq this device holds (a newcomer meeting an older proposal or report) | Ignore; take no key from it |
   | 7 | Anything else: a report differing at `X.seq <= s`, `X.prev != hash(H)` at `s + 1`, or `X.seq > s + 1` | Fork or missed record: status `closed` |

   Rows are checked in order; row 5 comes before row 7, so an authorized
   live switch always recovers a closed or forked channel. It cannot be
   replayed: MLS refuses a replayed message, and a key opened before the
   removal floor is never used (decision 5).
   - A sender applies its own proposal only when it comes back in sync
     order, never at send time. Until then it seals as before the change.
   - A `closed` channel seals under random keys, hands over no key, and
     shows an error until row 5 recovers it.
   - Newcomers use the same table; their first record comes from the
     add-time `history_sync` (row 1).
   - **Authority** (D80, checked against the device's C4 state for the
     shared group, `governance.dart` `roleOf`):
     - `switch` and `move`: the actor's role is admin or owner.
     - `create`: the actor holds C4's channel-creation right. The server
       today allows moderators (`CanManageMembers` in
       `community_store.go`); C3 says "an admin device". C3 and C4 align
       this before C7 wires it; C7 follows whichever rule C4 records.
     - `rekey`: the actor is a current member of the group, and the
       record it chains from (`prev`) opened a `full` generation that is
       stale on this device with `stale_since = close_epoch` (decision 5).
       Judged against `prev`, not the current head, so a duplicate rekey
       is valid and loses by row 4.
   - Worked trace: "Trace 2" below.

5. **Removal floor, `history_sync` and the membership barrier.**
   - **Epochs.** A message's epoch is the epoch it was encrypted in. A
     membership commit "produces" epoch `E` when merging it moves the group
     to `E`. A device removed by the commit that produces `E_r` is in no
     epoch `>= E_r`.
   - **Removal floor.** Every device keeps, per group, `floor` = the epoch
     produced by the latest removal commit it applied, and per channel
     generation `stale_since` = the smallest epoch produced by a removal
     that is above the generation's opening epoch (unset if none; devices
     keep the group's removal epochs since the oldest open generation, so
     a record applied late still gets the right value). A generation is
     **fresh** when its opening record's `epoch >= floor` of the group it
     lives in, and **stale** otherwise. Every member computes the same,
     because removal commits are ordered by MLS. A newcomer applied no
     earlier removal, so it relies on its `history_sync` sender for those
     (trust limits).
   - **Stale or unsure means no key use.** While a channel's generation is
     stale, or its status is `unsure` or `closed`, the device seals posts
     under random keys, hands over a random `key_c`, and holds edits
     (decision 7). This replaces revision 3's per-device "rekey due" note:
     every device knows a rekey is due.
   - **`history_sync`: one message after every membership commit.** After
     every add or remove commit in any community group, whatever the
     modes, the committer sends one group-level message (no `channel_id`).
     Its body (layout below) carries, for each of the `N` channels the
     group carries, in byte order of channel id:
     - `ok`, fresh `full` channel: `key_c = CHK_g`, slot = head (report).
     - `ok`, stale `full` channel: **a rekey proposal**. `key_c` is a new
       `CHK_{g+1}`; the slot holds the rekey record (`close_epoch =
       stale_since`) and a wrap of generation `g`.
     - Any other channel (`members_from_join`, `unsure`, `closed`, or a
       device without chain state): `key_c` random, slot = head (or 64
       zero bytes for no head). A random key never counts as a rekey.
   - **Barrier** (mode-independent): a device does not stage a membership
     commit in a group until it has applied a valid `history_sync` naming
     that group's latest membership commit (`for_epoch`, below). Every
     membership commit gets one in every mode, so this shows the server
     nothing. It guarantees that add-time slots are computed after the
     removal's rekey, so a newcomer is never handed a key a removed member
     holds (Trace 1). It applies to removals too: a second removal waits
     for the first one's rekey, so each rekey closes at the right epoch.
   - **Missing or racing `history_sync`.** If none follows a membership
     commit, C0's reconcile coordinator sends one; every other device
     waits a jittered delay that grows with group size and cancels when it
     applies a **valid** one for that commit (`for_epoch` is inside the
     body, so a stripped body cancels nothing); a device whose delay runs
     out sends its own.
     So every device either applies one or sends one, and the barrier
     always clears. Duplicates resolve per slot by the ordering table
     (row 2 or row 4). No device ever sends a second `history_sync` for a
     reason that depends on a mode.
   - **`history_sync_request`.** A newcomer that has applied no
     `history_sync` for the commit that added it within a fixed timeout
     sends one `history_sync_request` (group-level). Whether it sends
     depends only on whether the committer's message arrived, never on
     modes. Answering follows the same jitter rule.
   - **Handover.** Newcomers added by the commit read `key_c` for each
     channel, check it against the slot record's `chk_commit` (a mismatch
     means no key: the slot was random), and so hold the current key and
     setting of each channel from one fixed-size message. C3/C4 visibility
     holds because private channels are their own groups.
   - **Backward wrap.** A rekey slot is sealed under the new key and wraps
     the previous generation (`g`, `CHK_g`, its group and opening epoch;
     its end is the record's `close_group_id`/`close_epoch`). A newcomer
     holding the current `CHK` walks back through stored `history_sync`
     bodies, within its fetch depth (decision 10), to every generation of
     the current period. Key use stops at the period start (a switch
     record wraps no earlier key, owner round 2); the fetch never stops
     early there, or its depth would show when the period began.
   - **Unsure.** A device marks every `full` channel of a group `unsure`
     when, in that group, it meets any message it could not fully apply: a
     P1 `invalid` body, a D54 undecryptable message, a message refused as
     `SENDER_REMOVED`, or a message passed over as expired or beyond the
     past-epoch window (I33). Any of them could have been a record. It
     clears only by row 3 (a valid record chaining from the head) or row 5
     (a live admin switch). A quiet channel may stay `unsure` until its
     next record, usually the rekey after the next removal: that is a gap
     (I3), never a leak. A newcomer whose slots disagree uses the table
     too: a difference that is not a direct successor is row 7.

   **`history_sync` body layout.** One sealed body, then `N` slots:

   ```
   sealed_body = body0 | slot_1 | ... | slot_N
   body0  = the normal body framing (core idea), whose VAP1 payload is the
            hidden W7 type history_sync:
            {for_epoch: u64, keys: base64(key_1 | ... | key_N)}
            padded to exactly P(N) = 256 * ceil((512 + 44 * N) / 256) bytes
   slot_i = kc_i[32] | nonce_i[12] | AES-256-GCM(K_i, nonce_i, slot_plain_i, aad)
   slot_key_i = HKDF(key_i, "veritra-c7-slot-v1",
                     lp(community_id) | lp(channel_id_i) | lp(sender_device_id) | lp(action_id))
   K_i  = HKDF(slot_key_i, "veritra-c7-enc-v1", "")
   kc_i = HKDF(slot_key_i, "veritra-c7-kc-v1", "")
   slot_plain_i = record (512) | wrap (128) = 640 bytes
   wrap = u32 g_prev | CHK_prev[32] | lp(group_id_prev) | u64 E_open_prev,
          zero-padded to 128; all zeros when unused
   ```

   - `for_epoch` is the epoch produced by the membership commit it
     follows. `sig` in body0 covers the padded VAP1 as for any message;
     each slot record carries its own signature.
   - Size: `P(N) + 124 + 700 × N`, a function of `N` only (the server
     knows `N`). At C3's limit of 500 channels that is 372,652 bytes, about
     497 KB in base64, inside the 1 MiB request read limit. VAP1's decoder accepts padding beyond the smallest
     bucket; receivers refuse any other length.
   - `kc_i` comes from the per-message `slot_key_i`, so a `full` channel's
     slot never repeats a value across messages.
   - A reader of a stored `history_sync` (newcomer, backward walk) has no
     `body_key`; it tries its key on each slot and opens the one whose
     `kc` matches, then checks the record's `channel_id`.

6. **Windows.** Generation `g` is valid in its group from its opening
   record's (or wrap's) `epoch` (`E_open`) to the closing record's
   `close_epoch` (`E_close`), exclusive. A newcomer accepts a body sealed
   under `g` only if the signed `group_id` is `g`'s group, the signed
   epoch equals the epoch the history route reports, and
   `E_open <= epoch < E_close`. Bodies in the closing epoch are dropped (a
   gap, I3). A rekey's `E_close` is `stale_since`, the first epoch the
   removed device is not in; honest devices sealed nothing under `g` at or
   after it (they stop at the removal), and the window drops anything
   that was.

7. **Targeted actions follow their target.** Every local row stores the
   period and generation its body was sealed under (live members learn it
   by matching `body_key` against their current-period keys; the sender
   knows it). An action that names a target (`edit`, `delete`, `reaction`,
   `pin`, `poll_vote`, `poll_close`, `admin_delete`) is sealed under the
   current fresh generation only if its target was sealed in the current
   period, and under a random key otherwise. So an edit's new text never
   reaches a newcomer who could not read the post. A `reply` carries only
   `reply_to_id` (the quote is resolved locally, `docs/crypto.md` W7 §4),
   so it is a post.
   - **Edits after a removal or while unsure.** From applying a removal
     until applying that removal's `history_sync`, a device holds its
     edits in **every** channel of the group (the D68 pattern; holding only
     in `full` channels would show which are `full`). After that, an edit
     whose channel is still stale or `unsure` stays held until it is fresh
     and `ok`, for at most 24 hours; then it is sealed under a random key
     (newcomers see the earlier text: a gap). The UI shows a held edit as
     pending.
   - **Deletes reach the history route.** In a community conversation an
     author's delete is the W7 `delete` payload **plus** a server call that
     marks the target `history_hidden` (target's author only). The history
     route never serves a hidden body; sync keeps serving envelope and body
     until retention removes them, so no member meets a missing body (which
     would make its group `unsure`). The same in every mode, so newcomers
     never fetch a deleted post, whatever key sealed it. Deletes are not
     held. (The review called this optional; it is adopted because a
     delete sealed under a random key during a stale or `unsure` spell
     would otherwise leave the post readable to newcomers.)

8. **Who verifies a signature with which key.**
   - **Live members** need the key OpenMLS authenticated the sender with.
     Today `pm_crypto_group_decrypt` (`crypto/rust/src/ffi.rs:1521`)
     returns only the plaintext, and `Device::decrypt` in `mls.rs` notes
     that past-epoch signature keys are not exposed. C7 adds a new decrypt
     call (ABI below) returning the plaintext, the message epoch and the
     signature key of the current-tree leaf whose credential matches the
     sender. A past-epoch message is accepted only while its sender is
     still in the roster (D80 Q-003), so that leaf exists. This rests on
     one invariant: a device's credential key never changes. `self_update`
     reuses the device's signer with default leaf parameters, and a
     device's own leaf is checked against `signing_public_key()`; the
     build adds a receive-side check that an Update keeps the leaf's
     signature key, or C7 cannot rely on it.
   - Live members check `sig` with that key, and that the signed epoch and
     `group_id` equal the message's. A mismatch is a P1 `invalid` row.
   - **Newcomers**, for a sender still in the group: a new read of a
     member's signature key from the current tree. For a sender no longer
     in the group, the only source is the server's device directory:
     owner question B.

9. **What each side reads.**

   | Change | Existing members | Later newcomers |
   |---|---|---|
   | to `full` | Read live, as before; get the key in the record body | Posts from the switch on |
   | to `members_from_join` | Read live, as before; delete the period's keys | Nothing older than their join |
   | off and on again | As above | Only the newest period (round 2) |
   | rekey on removal | Get the new key in `history_sync` | The whole current period, by the backward wrap |

10. **Reading history.** A newcomer prefetches, for **every** channel it
    can see and for the group-level stream, the same fixed depth (owner
    question 1), whatever the mode, and discards what no key opens.
    `history_sync` bodies beyond that depth are lost to the backward walk
    (a gap). Import is two passes per channel: collect every opened body
    in the fetched range, then apply in server order, with every `delete`
    applied as a set first (a deleted target is never inserted) and edits
    after their targets. Opened posts go into the local database like any
    other; unread state and search stay local (C0). There is **no** server
    paging in community conversations (server section).

11. **Moves** (C0/C3) are `move` records. A generation lives in one
    group, so a move of a `full` channel starts a new generation in the
    new group. The move record is proposed in the new group and names the
    old group in `close_group_id`, with that group's epoch in
    `close_epoch`. A move to a narrower audience (open to private)
    continues the period and wraps the previous key; a wider one (private
    to open) starts a new period with no wrap. Freshness of the new
    generation is judged by the new group's floor.

## Trace 1: removal, then an add

Shared group `G`; channel `C` is `full`, generation 3 opened by record
seq 5 at epoch 10. Members A, B, R and others hold `CHK_3`.

| Step | What happens | Keys | R |
|---|---|---|---|
| 1 | A commits the removal of R, producing epoch 20 | Every device applying it: `floor = 20`, `stale_since(g3) = 20`. `C` is stale: posts sealed under random keys, no handover, edits held in every channel | Holds `CHK_3`; in no epoch `>= 20` |
| 2 | B wants to add N | Barrier: B has not applied a `history_sync` with `for_epoch = 20`, so B waits. (Revision 3 let B commit epoch 21 and hand `CHK_3` to N: blocker 1) | |
| 3 | A sends `HS20` at epoch 20 | Slot `C`: rekey proposal seq 6, `g = 4`, epoch 20, `close_epoch = 20`, `key_c = CHK_4` (new); wrap of g3 (`CHK_3`, `G`, 10) | Cannot read epoch 20 |
| 4 | Everyone applies `HS20` (row 3) | Head seq 6; g4 opened at 20 `>= floor`: fresh. Posts seal under `CHK_4`; held edits go out | |
| 5 | B commits the add, producing 21, and sends `HS21` | Slot `C`: `key_c = CHK_4`, head seq 6 (report). N checks `chk_commit`, holds `CHK_4`, fetches `HS20`'s body (epoch 20 is before its join), opens slot `C` with `CHK_4`, learns g3 with window [10, 20) | |

Result: N reads g3 posts from epochs 10 to 19 and g4 posts from 20 on. R
holds only `CHK_3`; nothing at epoch 20 or later is sealed under it.

Variants:

- **A goes offline after step 1.** The coordinator K sends `HS20` with its
  own rekey. If D's jitter also fires, D's slot is a proposal with the same
  seq and `prev`: row 4, stale; D discards its key. Everyone holds K's key.
- **A switch sent before the removal lands after it.** Say `C` was
  `members_from_join` at seq 5. Admin X, not yet having applied the
  removal, switches it on at epoch 19 (seq 6, g4, new key in the body); R
  is in epoch 19 and reads that key. `HS20`, sent before the switch was
  applied, has a random slot for `C`. Applying the switch, every device
  finds g4 opened at 19 `< floor 20`: stale, so no use and no handover.
  The barrier is satisfied (`HS20` was applied), B adds N at 21, and B's
  `HS21` slot is a **rekey proposal** (seq 7, g5, `close_epoch = 20`,
  wraps g4). N gets `CHK_5`; R holds `CHK_4` only. Posts between 20 and
  21 were sealed under random keys (a gap). The same happens when a rekey
  loses a race to any record that opened a key before the floor.
- **The server withholds `HS20` from B only.** B cannot add; its delay runs
  out and it sends `HS20'` with its own rekey (seq 6). Everyone else saw
  A's first, so B's is row 4 for them, while B, never shown A's, applies
  its own. B's next `history_sync` reports B's seq 6: row 7 on every other
  device, `C` closes. N may hold B's key, which R never held. A forking
  server gets a closed channel and a gap, not a leak.

## Trace 2: record ordering

Channel `C`, admins P and Q, member M. Hashes: `h_k = hash(record seq k)`.

| Step | Record received (sync order) | Row | Head after |
|---|---|---|---|
| 1 | seq 0 `create` mfj by P, prev zeros (proposal) | 1 | 0 |
| 2 | seq 1 `switch` full g1 by P, prev `h0` | 3 | 1 (full, g1) |
| 3 | seq 2 `switch` mfj g2 by P, prev `h1` | 3 | 2 (mfj) |
| 4 | seq 2 `switch` full g2 by Q, prev `h1` (sent concurrently) | 4: Q's lost race; Q discards its key and re-decides | 2 |
| 5 | `history_sync` slot from M reporting seq 2 (P's bytes) | 2 | 2 |
| 6 | A rekey proposal seq 2 from M, prev `h1` | Invalid (no removal made g1 stale): ignored | 2 |
| 7 | A slot from a device reporting seq 2 with Q's bytes | 7: fork (that device applied Q's), status `closed` | 2, closed |
| 8 | seq 3 `switch` full g3 by Q, live, prev `h2(Q)` | 5: live admin switch on a closed channel, recovers | 3 (full, g3), ok |
| 9 | seq 5 rekey proposal (seq 4 never arrived) | 7: missed record, `closed` | 3, closed |

A newcomer starts at row 1 with the first slot it sees. A second add-time
slot is row 2 when it agrees, row 4 when it is a duplicate rekey
proposal, row 6 when it is older than what the newcomer holds, and row 7
otherwise.

## Server: wire, storage, routes

- **Send.** The envelope route (`POST /api/v1/messages/envelopes`) takes a
  `sealed_body` field, required on every envelope in a community
  conversation and refused elsewhere. A channel envelope's body is
  `124 + 256 × k` bytes, at most 65,660 (the 65,536-byte VAP1 cap plus
  framing). A group-level envelope's body is either that or exactly
  `P(N) + 124 + 700 × N` (`history_sync`). A community envelope carries no
  server-visible `reply_to_id` or `thread_root_id` (W7 keeps references
  inside the payload; check `mobile/lib/core/models.dart` before C7
  sends), or a newcomer's reply would show it read a pre-join post.
- **Idempotent replay.** The replay path in `saveMessageEnvelope` reads the
  stored body too, and `sameIdempotentMessage`
  (`server/internal/storage/message_store.go:229`) compares it, so a retry
  with a different body is a conflict.
- **Group-level messages.** C0's rule "every `community_shared` envelope
  names an open channel" gains one exception: `history_sync` and
  `history_sync_request` carry no `channel_id`. (C4 changes roles by
  commits, so it adds no group-level application message.) Apps accept
  only those two types there.
- **C2 refusal.** Today it is conversation-wide (`message_store.go:90`:
  the conversation's posting policy, or its `channel_id`'s announcement
  kind), which would refuse a non-admin's `history_sync` in a private
  announcement channel's group. In community conversations the refusal
  applies only to envelopes that carry a `channel_id`. A private channel's
  group therefore carries the `channel_id` on its posts too (the server
  already maps that group to its channel): an amendment of C0's "absent
  everywhere else", for C0 and C2 to take with C7.
- **Storage.** Migration (next free number): `envelope_bodies(message_id PK
  REFERENCES message_envelopes, conversation_id, channel_id NULL,
  created_at, expires_at, body BLOB)`, written in the send transaction.
  Sync serves the body with its envelope, read from this table, not copied
  into `sync_events`. Admission limits (D38) count body bytes. Revision 2's
  columns, table, side field and 409 were never built and stay dropped.
- **Pruning and deletes.** A body lives exactly as long as its envelope:
  the conversation's retention (and per-channel retention, D51) sets
  `expires_at` alike, and the sweeper removes both. `envelope_bodies`
  gains `history_hidden` (decision 7), set by
  `POST /api/v1/messages/{id}/history-hide` from the envelope's sender
  account only. C5's moderator delete redacts the envelope today
  (`docs/designs/C5-moderation.md`); if it ever removes the body, members
  who have not synced the target turn `unsure`, for C5 and C7 to settle.
  Switching to `members_from_join` deletes nothing on the server. The
  confirm dialog says: "People who join later won't see earlier posts.
  Members who already have them keep them."
- **Legacy edit and delete routes refused.** `UpdateMessageEnvelopeWithSyncEvent`
  and `DeleteMessageEnvelopeWithSyncEvent` (`message_store.go:309`, `:354`)
  rewrite an envelope in place; in community conversations they answer
  409. Edits are new envelopes.
- **No server paging in community conversations.** `ListMessages`
  (`message_store.go:529`, `GET /api/v1/conversations/{id}/messages`)
  serves every envelope with no join filter, and the chat screen pages
  through it (`chat_screen.dart:277,1142` → `loadOlderMessages` →
  `listMessagePage`, `app_state.dart:1969`). A newcomer paging deeper only
  where posts open would show which channels are `full`. In community
  conversations the app never calls it (older history is local), and the
  server answers it with 409 `history_route_only`.
- **History fetch.** `GET /api/v1/conversations/{id}/history?channel_id=&before=&limit=`,
  per calling device, the only route that serves pre-join bodies. It
  returns `{message_id, sender_device_id, action_id, channel_id,
  created_at, epoch, body}` for unexpired, undeleted, not `history_hidden` envelopes from
  unblocked senders that sync did not give this device: those before its
  `joined_after_event_id`, and those after it but in an epoch before its
  `joined_epoch` (the I51 withholding in `mls_group_store.go:779-783`).
  `channel_id` empty means the group-level stream. Current member devices
  only; the same for every channel and mode. References are never served
  there.
- **Authority.** The server cannot check records. Apps check them against
  C4's signed role state (built-in roles), never the server-reported role
  (D80). C7 switches cannot ship before that state exists.

## What the server still learns

| Signal | What it shows | Cost to remove |
|---|---|---|
| A newcomer fetching deeper than the fixed prefetch, in some channels only | Those channels are `full` | No paging (above) and a fixed depth. Owner question 1 |
| A newcomer downloading a pre-join attachment | That post's channel was `full` then | Owner question 2 |
| A newcomer reporting a pre-join post (C6 `POST /api/v1/reports` carries `envelope_id` in clear) | That post's channel was `full` then | C6 moves the envelope id inside the sealed report for community reports, or apps do not offer reports on pre-join posts. For C6 to decide |
| Message sizes | The W7 256-byte bucket, as today; records and `history_sync` have fixed shapes | Coarser padding (L2) |
| Per-channel retention (D51) | A long retention on one channel hints that it keeps history | The UI never couples the two settings |
| Edits sent in a burst once a stale channel is rekeyed | Only after a lost rekey race: that some channel in the group is `full` | Rare; accepted |
| Author deletes (`history-hide`) | Which post its author deleted, in every mode (as for other conversations today) | None needed |
| Membership commits waiting for a `history_sync` | Nothing about modes (every commit gets one) | None needed |
| A `history_sync` from a second sender | A committer went offline | None needed |

## Interaction with MLS and C4

- No extra commit for a switch; records are application messages. Removal
  commits lead to rekeys inside the next `history_sync`; adds never rekey
  unless a generation is stale.
- The barrier slows a membership commit that follows another by the time
  until the first one's `history_sync` lands (normally the committer's
  own, sent right after). Revocation removals wait too.
- Records and bodies from a past epoch are applied within OpenMLS's
  past-epoch window; outside it they are lost and the group turns
  `unsure`.
- A private-channel record is judged against the shared group's C4 state
  at receipt; the two groups have no common order (C4 review residual).
- A role change that adds or removes members of a private channel's group
  is a membership commit and so is followed by `history_sync`.

## Trust limits

- A newcomer verifies signatures, the chain from its first record, key
  commitments and windows, but cannot check C4 authority for records
  older than its join; it trusts the member who sent its `history_sync`,
  which could also withhold keys.
- A malicious member could stretch a window it describes; it can only
  expose posts real senders sealed under a `full` generation, which that
  member could already read and leak.
- Departed senders' keys: owner question B.
- Until L1, a server that adds a hidden device can read new live posts and
  forge history from that device: the same limit as live groups today.

## What it does not give

- No forward secrecy for history: a `CHK` holder reads its generation.
- A member who leaves keeps what it could read; switching off cannot
  recall copies on devices.
- History is lost if every key holder is gone (accepted, round 1), and is
  bounded by retention and the prefetch depth.

## Protocol changes (all additive, none made yet)

- **Send format.** Every community message is reference + body (core
  idea); `"C7R1"` replaces VAP1 as the MLS plaintext in community
  conversations, and the receive policy treats anything else there as
  `invalid`. An explicit **amendment** of the framing `docs/crypto.md` W7
  §1 marks frozen (VAP1 stays frozen, one layer down, inside the body).
  No release exists, so no compatibility path (C0 recreates demo
  communities).
- **W7 types** (hidden): `history_change`, `history_sync`,
  `history_sync_request`. Belongs to the W7 section of `docs/crypto.md`.
- **Rust ABI 13 or later**, numbered when built and coordinated with C4's
  ABI work (whichever lands first takes 13; ABI 12 is C6's). Approved in
  principle (D80), needs independent review:
  - a decrypt that also returns the epoch and the sender leaf's signature
    key (a new export; `pm_crypto_group_decrypt` stays);
  - a read of a member's signature key from the current tree, by account
    and device id;
  - credential-key sign and Ed25519 verify over a fixed domain allowlist
    (`veritra-c7-post-sig-v1`, `veritra-c7-history-v1`);
  - `c7_derive` (HKDF as above) and `c7_seal`/`c7_open` (key commitment,
    AES-256-GCM, random nonce), on existing dependencies (owner question
    A).
  The core exposes no MLS exporter today; C7 does not need one.
- **Server:** `sealed_body`, `envelope_bodies`, the history route, the
  group-level exception, the C2 change, the replay check, refusals of
  legacy edit/delete and paging in community conversations, the
  `history-hide` call.
- **Local DB:** per channel the head, applied record hashes, status, and
  the current period's keys with their windows; per group the floor; per
  row its period and generation; held edits. In the sealed database; not
  in backups or K2 bundles.

## Build order

1. Independent review of this revision.
2. Rust ABI with vectors `testing/vectors/c7-*.json` (bodies, slots,
   records, the ordering table rows, windows, the implicit genesis,
   `P(N)`), checked by Rust, Go and Dart.
3. Server: migration, `sealed_body`, replay check, history route,
   group-level and C2 exceptions, legacy-route and paging refusals.
4. Dart: two-part send/receive, records and the ordering table, floor and
   barrier, `history_sync`, unsure state, targeted-action sealing,
   backward walk, two-pass import, prefetch.
5. Flows and tests: two devices, leave, switch both ways, off/on, Trace 1
   and its variants, Trace 2, lost committer, a stripped body (unsure),
   and server-side tests that a `full` and a `members_from_join` channel
   give identical rows, sizes and requests for posts, retries, record
   messages (both directions), add-time `history_sync`, and the
   removal-then-add sequence.

Depends on: C0 layout, C1 per-conversation sync halting, C3 channel state
and moves, C4 role state (and its channel-creation rule), C5 deletes, C6
for the report residual.

## Open questions for the owner

Earlier questions: 1 (off/on) and 2 (server sees the flag) are answered in
round 2; 3 (ABI) is approved; 4 (server-checked admins) is moot.

1. **Newcomer history depth.** The same prefetch for every channel (and
   the group-level stream) hides the setting. Proposed: the latest 1,000
   posts or 8 MiB per channel, whichever comes first, and no deeper
   paging. Alternatives: deeper paging on demand (shows the server that
   the channel is `full`), or all retained history for every channel (no
   leak, more download per join).
2. **Pre-join attachments.** Downloading one shows the server the channel
   was `full`. Proposed: offer them on tap with that cost accepted.
   Alternatives: never offer them, or prefetch them all within the depth.
3. **`history_sync` cost.** About `P(N) + 124 + 700 × N` bytes per
   membership commit: 23 KB at 30 channels, so about 23 MB of egress per
   membership commit at 1,000 devices (0.6 MB for the add commit itself;
   C0 batches joins). Accept, or add targeted delivery of add-time
   messages to the new devices only (a server feature, C8)?
4. **(A) Crypto dependencies.** Revision 3 named XChaCha20-Poly1305 and
   HKDF, neither a direct dependency. Options: (a) reuse the direct
   `aes-gcm` and the OpenMLS provider's HKDF, as C6 does, with a random
   96-bit nonce (safe: every key seals one message); (b) add
   `chacha20poly1305` and `hkdf` as direct crates (license review,
   `THIRD_PARTY_NOTICES.md`; the body grows 12 bytes). **Recommended: (a).**
   This revision is written for (a).
5. **(B) Senders who left.** A newcomer can read the signing key of a
   sender still in the group from MLS, but not of one who left; only the
   server's device list has it. Options: (a) trust the server's list for
   departed senders until L1, and mark those posts "from a former member";
   cost: a server colluding with any removed member (who holds old keys)
   can insert backdated posts in a departed member's name into a period
   that member could read. The server keeps a revoked device's
   `signing_key` (`identity_store.go:649` only sets `revoked_at`) but
   nulls it when an account is deleted (`account_store.go:170`), so a
   deleted account's posts drop anyway, and (a) needs a route serving a
   former member device's key to current members; (b) drop departed senders' posts for
   newcomers; cost: announcements by former admins disappear for every
   newcomer. **Recommended: (a) with the marker**, because (b) loses much
   of what `full` channels are for and the forgery needs a removed member
   plus the server; L1 removes the trust.

## Owner decisions (2026-11-01)

- The history setting may be changed later by admins (needs re-keying rules; revisit the design).
- Accepted: history copies double stored bytes for full-history channels, and history is lost if every key holder is gone.

## Owner decisions, round 2 (2026-11-01)

- Earlier `full` periods stay unreadable to newcomers after a switch off and on.
- The server must **not** see the history flag: hide it (needs a design change; the sequence/flag handling above assumes server visibility).
- Crypto ABI additions approved, with independent review.

## Changes in revision 4

| Review item | Fix |
|---|---|
| 1 Removed member reads new posts | Removal floor and fresh/stale generations (I6, decision 5); membership barrier; stale channels rekey in the next `history_sync`; random slots never count as a rekey; no mode-driven second `history_sync`. Trace 1 |
| 2 Ordering rules contradict | Proposal vs report, one ordering table with exclusive rows, recovery by a live admin switch. Trace 2 |
| 3 Lost record | `unsure` status with its triggers and what clears it; newcomers use the same table; admin told when its own proposal fails |
| 4 Signature unverifiable | New decrypt returning epoch and sender key, member-key read, credential-key invariant; departed senders are owner question B |
| 5 Edits reveal posts | Targeted actions follow the target's period; rows store their generation |
| 6 Authority undefined | D80 roles via `roleOf`; create follows C4's creation right (C3/C4 to align); implicit genesis |
| 7 ABI number, dependencies | ABI 13 or later with C4; AES-256-GCM and provider HKDF (owner question A); "C4 takes the same export" removed |
| 8 `history_sync` unparseable | One layout, `P(N)`, exact size |
| 9a-f Leaks | Per-message slot `kc`; byte-identical retries and body in the replay check; fixed-shape records; edits held in every channel; no server paging, history route defined; C6 report residual |
| 10 Deleted post reaches newcomers | Two-pass import; author deletes also hide the body from the history route |
| 11 Moves | `close_group_id` |
| 12 C2 refusal | Applies only to envelopes with a `channel_id` |
| 13 Smaller items | Legacy routes refused; history route serves I51-withheld envelopes and applies blocks; 512-byte record with a version byte; group-level depth; request rule; signature covers padded VAP1; `close_epoch` defined; no C4 governance messages; backup and snapshot exclusion |
