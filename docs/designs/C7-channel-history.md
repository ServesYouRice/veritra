# C7: history for new members

**Status: reviewed, ready for build step 2 (primitives may start).**
Proposed, not built. Revision 6 passed its independent review on
condition of the edits in revision 7 (no further design round). The
exporter use and every new ABI piece still need the independent crypto
review before they land. Written 2026-11-01 against `main` at `f1b4a36`,
on K0 and C0. Revision 2 (2026-11-01) made the setting changeable.
Revision 3 (2026-11-01) hid the setting from the server. Revisions 4 and 5
(2026-11-07) answered two reviews
([rev 3 review](../../testing/evidence/C7-rev3-review.md),
[rev 4 review](../../testing/evidence/C7-rev4-review.md)). Revision 6
(2026-11-07) applied the owner's round 3 decisions (exporter rekeys) and
answered the [rev 5 review](../../testing/evidence/C7-rev5-review.md).
**Revision 7 (2026-11-07)** applies the conditions of the
[rev 6 review](../../testing/evidence/C7-rev6-review.md): commit
processing itself reports removals and returns the exporter root, the
`history_sync` boundary is the state at merge, records are fresh only at
or above the latest membership commit, `history_sync` names its channels,
and the fallback, `unsure` and wording fixes. "Changes in revision 7" at
the end maps each finding to its fix; "Changes in revision 6" is kept
below it.

## Problem

A new member of an MLS group cannot decrypt posts from before their join
epoch (`joined_epoch` withholding). Communities want some channels where
newcomers read the past (rules, announcements, FAQ) and others where they
must not. MLS gives neither, so C7 adds a second layer keyed per channel
(C0: "C7 keys history per channel"). The server must not learn which
channels have it, or when that changes.

## Invariants (check these first)

- **I1. Never retroactive.** A post is readable by later newcomers only if
  its sender's device held the channel as `full`, with a current key,
  when it sent the post.
- **I2. Fresh key per generation.** Every generation starts with a key no
  earlier generation used: random for a record that opens one, exported
  from MLS for a rekey.
- **I3. Drop when unsure.** A reader that cannot prove a body falls inside
  a `full` window drops it. Gaps are acceptable; leaks are not.
- **I4. Fail closed toward no history.** Any disagreement about the setting
  (a fork, a missed record) means: seal new bodies under random keys and
  hand over no key for that channel.
- **I5. Uniform to the server.** Nothing the server stores, serves, counts
  or sees the timing of depends on a channel's setting, and nothing the
  server can provoke makes devices act differently by mode where it can
  see it. Residuals are listed under "What the server still learns".
- **I6. Removed members get nothing new.** No key that a removed member
  could have read is used to seal at or after the epoch its removal
  produced (decision 5). (Wraps deliberately hand earlier keys to
  newcomers, for posts from before that epoch.)

## Core idea: seal once, choose the key

Every application message in a community conversation (`community_shared`
and private-channel groups) is sent in two parts:

| Part | Content | Who reads it |
|---|---|---|
| **Reference** (the MLS ciphertext) | `"C7R1" \| body_key[32] \| sha256(sealed_body)[32]`: 68 bytes, the same for every message | Group members at that epoch, as today |
| **Body** (stored next to the envelope) | `kc[32] \| nonce[12] \| AES-256-GCM(K_enc, nonce, sig[64] \| padded VAP1, aad)` | Whoever holds `body_key` |

- **Primitives** (owner decision A): `HKDF(k, label, info)` is
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
  body, a hash or `kc` mismatch or a failed open is a P1 `invalid` row:
  the MLS state and cursor commit (otherwise a server that strips one body
  would stop the conversation under I33). It also makes the group
  "unsure" (decision 5).
- `aad = lp(conversation_id) | lp(channel_id or "") | lp(sender_device_id) | lp(action_id)`,
  the envelope's own fields, so the server cannot move a body. `lp(x)` is
  a u16 big-endian length then the bytes, and every `u32`/`u64` is
  big-endian, in every C7 encoding.
- **The key is the only difference.** While the sender's device holds the
  channel as `full` with status `ok`, in the generation current at the
  message's epoch (opened at epoch `E_g`, key `CHK_g`):
  `body_key = HKDF(CHK_g, "veritra-c7-post-v1", lp(community_id) | lp(channel_id) | lp(sender_device_id) | lp(action_id))`.
  Otherwise `body_key` is 32 random bytes that exist only inside the
  reference. The two cases are indistinguishable without `CHK_g`.
  Targeted actions follow their target's period instead (decision 7).
- **Live members** decrypt the reference, check the body hash and open the
  body with `body_key`. They never need `CHK` to read, and need no second
  signature check: MLS authenticates the reference, which fixes the body's
  hash (decision 8).
- **Newcomers** never see the reference. They fetch bodies, derive
  candidate `body_key`s from the `CHK`s they hold, open what `kc` matches,
  and verify `sig`.
- **Signature** (`sig`), always present, Ed25519 by the sender device's
  MLS credential key over
  `"veritra-c7-post-sig-v1" | lp(community_id) | lp(channel_id) | lp(action_id) | lp(group_id) | u64(epoch) | lp(sender_device_id) | u64(gen) | sha256(padded VAP1)`.
  `epoch` is the epoch the reference is encrypted in; `gen` is `E_g`, the
  opening epoch of the generation whose key sealed the body, or 0 outside
  `full`; the hash covers the whole padded VAP1 value, padding included.
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

2. **Generations and periods.** A *period* runs from a record that opens
   `full` (create as `full`, switch to `full`, a widening move) to the next
   record that leaves `full`. Inside a period, a *generation* is named by
   its group and opening epoch `E_g` and has one key `CHK_g`:
   - the record that opens the period (or a move) carries a random key;
   - every **removal commit** in the channel's group during the period
     opens the next generation at the epoch it produces, keyed by the MLS
     exporter (decision 5).
   Generation `g` is valid from `E_g` to the next generation's opening
   epoch, or to the closing record's `close_epoch`. Devices keep the
   current period's keys in the sealed local database and delete them when
   the period ends. Keys never go into K1 backups or K2 bundles: the C7
   tables are added to `mobile/lib/storage/backup_exclusion.dart` and left
   out of `mobile/lib/storage/history_snapshot.dart`, with a test for
   each. A restored (D73) or newly linked device is added to the groups
   and gets keys like any newcomer.

3. **Records** (create, switch, move only; there is no rekey record). One
   chain per channel. A record is a hidden W7 v2 payload,
   `history_change`, proposed in a message of the channel itself. Signed
   fields (all ids at most 64 bytes; C7 refuses longer ones, server ids
   are 36):

   ```
   community_id, channel_id, u32 seq, prev[32], u8 mode, u8 reason,
   group_id, u64 epoch, close_group_id, u64 close_epoch, chk_commit[32],
   actor_device_id
   sig = Ed25519(actor credential key, "veritra-c7-history-v1"
         | lp(community_id) | lp(channel_id) | u32 seq | prev | u8 mode
         | u8 reason | lp(group_id) | u64 epoch | lp(close_group_id)
         | u64 close_epoch | chk_commit | lp(actor_device_id))
   ```

   - `seq`: 0 for `create`, +1 each record; a record with
     `seq = 2^32 - 1` is invalid, so `seq` never wraps. `prev`: zeros at 0,
     else `sha256(full form of the previous record)`.
   - `mode`: 0 `members_from_join`, 1 `full`. `reason`: 0 `create`,
     1 `switch`, 2 `move`.
   - `group_id`, `epoch`: the group and epoch of the message that carries
     it (for a compact proposal, taken from the MLS message itself).
   - `close_group_id`, `close_epoch`: where and when the previous
     generation stops being valid. For a create or switch: this group and
     `epoch`. For a move: decision 11.
   - `chk_commit`: `sha256("veritra-c7-chk-v1" | CHK)` for a record that
     opens a key, else zeros.
   - **Every record must be fresh** (review of revision 6, finding 2): its
     `epoch` must be at or above its group's **membership floor**, the
     epoch produced by the latest add or removal commit the receiving
     device merged (decision 5). Every member merges the same commits in
     MLS order, so all agree. A record sent before a membership commit and
     sequenced after it is invalid everywhere, and the actor's app
     re-proposes it at the current epoch. This covers two cases: a switch
     to `full` sent before a removal would carry a key the removed member
     read; and a switch off sent before an add would be missing from the
     newcomer's `history_sync` (decision 5, state at merge), leaving it
     with a switched-off key. Cost: a switch that races any membership
     commit (a join included) is refused once and re-sent automatically;
     in a busy group that can take a few tries. The looser rule (removals
     only) would avoid the retries but leave the newcomer gap, so the
     stricter rule is taken.
   - **Same-mode switches.** A switch to `full` while `full` starts a new
     period with a new key and no wrap (an admin's "start history over",
     also the recovery path of decision 4). A switch to
     `members_from_join` while already so changes nothing but the chain.
   - **Full form** (slots and hashing): `u8 version (=1) | lp(community_id)
     | lp(channel_id) | u32 seq | prev | u8 mode | u8 reason |
     lp(group_id) | u64 epoch | lp(close_group_id) | u64 close_epoch |
     chk_commit | lp(actor_device_id) | sig`, zero-padded to **512 bytes**
     (at most 481 used).
   - **Compact form** (the proposal in its channel message): `u8 version
     (=1) | u32 seq | prev | u8 mode | u8 reason | u64 close_epoch |
     key[32] | sig` = **143 bytes**; a `move` adds `lp(close_group_id) |
     wrap[128]` (decision 11). The receiver fills in `community_id` and
     `channel_id` (payload context), `group_id` and `epoch` (the MLS
     message, from the epoch-returning decrypt), `actor_device_id` (the
     MLS-authenticated sender), `close_group_id` (= `group_id` unless a
     move) and `chk_commit` (from `key` when the record opens one), then
     rebuilds the full form and checks `sig`. A compact proposal is so by
     construction sent by its actor, in the group and epoch it names.
   - `key` is the new `CHK` when the record opens a key, else 32 random
     bytes. A record that opens a key seals its message body under
     `HKDF(CHK, ...)` like any post of that generation; every other record
     message seals under a random key.
   - **Size, exactly.** The VAP1 inner JSON (Dart's compact `jsonEncode`;
     `conv_`/`dev_`/`chan_` plus 32 hex; a 48-hex `action_id`)
     `{"v":2,"type":"history_change","conversation_id":…,"sender_device_id":…,"action_id":…,"channel_id":…,"hidden":true,"body":{"r":"<base64 of 143 bytes>"}}`
     is 485 bytes, 493 with the 8-byte VAP1 header: a **512-byte VAP1**,
     the smallest bucket any community post has (an empty text post is 280
     bytes framed) and the bucket of every text up to about 230
     characters. A move is 713 bytes framed with server-length ids, a
     768-byte VAP1; the server sees moves anyway (a new group), and every
     move has the same fields in every mode.
   - **Franking** (review finding 4). C6 stores a server-visible
     `frank_commit` per envelope. A franked record would be about 554
     bytes framed and leave the 512 bucket, and an envelope without a
     commitment would stand out. So the C7 hidden types (`history_change`,
     `history_sync`, `history_sync_request`) carry no `frank` member and
     send 32 random bytes as `frank_commit`; C6's refusal of unfranked
     payloads, when it is turned on, exempts these types after decoding.
     Recorded in C6's open items too.
   - **Create.** Every channel creation sends a `create` record, in both
     modes. A channel for which a device holds no record is
     `members_from_join` with no head: the "implicit genesis" the vectors
     pin.

4. **Ordering: sync order plus the `prev` chain.** The server cannot
   sequence records it cannot see. Each device keeps per channel a *head*
   (the last applied record), the records (bytes and hashes) it has
   applied in the current period, the highest `seq` of any valid record it
   has seen, and a *status*: `ok`, `keyless`, `unsure` or `closed`. "The
   first seq this device holds" (row 6) is the lowest `seq` among those
   kept records, or the head's when it keeps only the head.

   A record is a **proposal** in the channel message that carries it in
   compact form, and a **report** in a `history_sync` slot (the sender
   repeating its head).

   **Validity** first: encoding, signature, `chk_commit` against the
   carried key, freshness (decision 3) and authority (below). Signatures
   are checked only against keys in the current MLS tree (owner decision
   B): a proposal's actor is its live sender; a report whose actor is no
   longer in the tree cannot be checked, so a member ignores it and a
   newcomer may adopt it only as its first head, on the word of its
   MLS-authenticated `history_sync` sender (trust limits). Only records
   that pass every check count toward the highest `seq` seen. An invalid
   record is ignored and leaves an `action` row. Then, for a valid record
   `X` against head `H` (`s = H.seq`), in sync order, the first matching
   row applies:

   | # | Condition | Result |
   |---|---|---|
   | 1 | No head (newcomer, or implicit genesis) | Adopt `X` as head; status `ok` if this message gives its key (or it opens none), else `keyless` |
   | 2 | `X` equals the record this device applied at `X.seq` | No-op |
   | 3 | `X.seq = s + 1` and `X.prev = hash(H)` | Apply: new head. If `X` opens a key that this message does not give (a report whose slot is random), status `keyless` |
   | 4 | Proposal, `X.seq <= s`, and `X.prev` equals the `prev` of the record applied at `X.seq` | Lost race: ignore; the actor's app tells the actor |
   | 5 | A `switch` or `move` proposal decrypted live (not from a slot or the history fetch), with `X.seq` above the highest valid `seq` seen | Adopt as head, status `ok` (recovery: it states the whole setting) |
   | 6 | `X.seq <` the first seq this device holds (a newcomer meeting an older record) | Ignore; take no key from it |
   | 7 | Anything else | Fork or missed record: status `closed` |

   - **Sequence cap** (owner answer 2026-11-08): a valid record has
     `seq <= 2^31` and, when the device has seen a valid record, at most 1024
     above the highest valid `seq` seen. A record that breaks either bound is
     invalid before the table (ignored, leaves an `action` row, never counts
     toward the highest `seq`), so no valid record can use up the `seq` room
     that a recovering switch (row 5) needs above it. A newcomer's first
     record may be at any `seq` up to the ceiling. Vector `seq_cap` and the
     ordering cases pin it in Dart, Go and Rust.
   - Recovery of a `closed` channel (owner answer 2026-11-08): only a live
     `switch` or `move` above the highest valid `seq` recovers it, whether
     it chains from the device's head (row 3) or not (row 5).
   - Under an honest server the stale-record refusal is exact. A server
     that shows one device a different order of a record and a commit can
     make that device alone refuse or accept it: the "server targets one
     device" class under trust limits.
   - Every two valid records that disagree are now admin proposals for the
     same `seq` (row 4) or a fork the server made between switch
     proposals (row 7). Rekeys cannot conflict, so a server can no longer
     close a channel by withholding a `history_sync`, and no row depends
     on anything only `full` channels have (review findings 1 and 2).
   - **Own proposals.** A device chains a proposal only from its applied
     head and keeps at most one pending per channel. Recovery exception:
     an admin's switch proposed while the channel is `closed` takes
     `seq` = highest valid `seq` seen + 1 and `prev` = hash of its own head,
     so row 5 accepts it on devices that have seen no more; a device that
     has seen a higher valid `seq` stays `closed` until a switch above it
     arrives (fail closed). A device applies its own proposal only when it
     comes back in sync order; until then it seals as before. If it loses
     (row 4), comes back invalid (stale included) or does not come back
     within a timeout, the app tells the actor.
   - A `keyless`, `unsure` or `closed` channel seals under random keys and
     hands over no key. `closed` shows an error until row 5 recovers it.
     Recovery by a switch to `full` starts a new period (decision 3), so
     the earlier period stays unreadable to later newcomers (round 2).
   - **Authority** (D80, checked against the device's C4 state for the
     shared group, `governance.dart` `roleOf`):
     - `switch` and `move`: the actor's role is admin or owner.
     - `create`: the actor holds C4's channel-creation right. The server
       today allows moderators (`CanManageMembers` in
       `community_store.go`); C3 says "an admin device". C3 and C4 align
       this before C7 wires it; C7 follows whichever rule C4 records.
   - Worked trace: Trace 2.

5. **Exporter rekeys, membership floor and `history_sync`** (owner
   decision C).
   - **Epochs.** A message's epoch is the epoch it was encrypted in. A
     commit "produces" epoch `E` when merging it moves the group to `E`. A
     *removal commit* is any commit with at least one Remove (a device
     replacement included); a *membership commit* is any commit with an
     Add or a Remove. A device removed by the commit that produces `E_r`
     is in no epoch `>= E_r`.
   - **Commit processing reports what happened** (review of revision 6,
     finding 1). Today `MlsDevice::process_commit`
     (`crypto/rust/src/mls.rs:501`) returns nothing and
     `pm_crypto_group_process_commit` (`ffi.rs:1347`) a status only, so the
     app would have to trust the server's label to know a commit removed
     someone: a server could label a removal as an add to one device, which
     would then keep sealing under a key the removed member holds. So the
     calls that process another device's commit and merge this device's
     own pending commit gain C7 variants that return, from MLS itself,
     `{removed_any, added_any, new_epoch, root}`. For a removal commit,
     `root` is computed **inside the same call**, before the merge:
     `root = MLS-Exporter("veritra-c7-rekey-v1", lp(group_id) | u64(new_epoch), 32)`
     (RFC 9420 §8.5) from the new epoch's exporter secret, through
     `StagedCommit::export_secret` (OpenMLS 0.9.2,
     `src/group/mls_group/staged_commit.rs`, which exports from the epoch
     the staged commit moves to) for another device's commit, and through
     `group.pending_commit()` for this device's own. A commit that removes
     this device returns `removed_any` with no `root` (OpenMLS refuses the
     export with `UseAfterEviction`), not an error, and sync continues.
     Dart decides "removal", "membership commit" and "a `history_sync` is
     owed" from this result only, never from server labels. No other
     exporter output leaves the core, and there is no stand-alone exporter
     call.
   - **Rekey.** For each channel the group carries, the key of the
     generation opened at `E_r` is
     `CHK = c7_derive(root, "veritra-c7-rekey-chk-v1", lp(community_id) | lp(channel_id))`.
     For a channel whose period is open at `E_r`, the previous generation
     closes at `E_r`. Every member at `E_r` derives the same value with no
     message; the removed device is not in `E_r` and cannot. The device
     keeps `root` per group until its next removal merge, so a channel it
     learns of later (a late channel list, a row 3 catch-up showing the
     channel was `full` at `E_r`) still gets its key; per-channel values
     need not be stored. The three Dart merge sites
     (`mobile/lib/crypto/native_crypto_service.dart:606`
     `completeCommitBundle`, `:864` own commit seen in sync, `:955`
     another device's commit, on `main` `0d23d4c`) store `root` and the C7
     state in the same local transaction as the merged MLS state.
   - **Membership floor.** Every device keeps, per group, `floor` = the
     epoch produced by the latest membership commit it merged. It is used
     only for record freshness (decision 3): with exporter rekeys a
     generation is never stale.
   - **Newcomers.** A newcomer's floor is its join epoch (the Welcome's).
     It cannot check membership changes before its join and trusts its
     `history_sync` sender for keys of that time (trust limits).
   - **Re-added devices** (review finding 5). A device removed and later
     re-added keeps the group id (`join_group`, `crypto/rust/src/mls.rs`
     around line 630). When it applies its own removal, and before it
     applies any Welcome for a group, it deletes that group's C7 state
     (heads, hashes, keys, floor, statuses). After the Welcome it is a
     newcomer whose join epoch is the Welcome's epoch (Trace 4).
   - **`history_sync`: one message after every membership commit.** After
     every membership commit in any community group, whatever the modes,
     the committer sends one group-level message (no `channel_id`) naming
     the commit (`for_epoch`) and the channels it covers (body0, below).
     For each of those channels a slot holds:
     - `ok` `full` channel whose period key the sender still holds:
       `key_c` = the key of the generation current at `for_epoch`; the slot
       holds the head and a generation entry (below).
     - Any other channel (`members_from_join`, `keyless`, `unsure`,
       `closed`, no chain state, or a sender that no longer holds the
       key): `key_c` random; the slot holds the head (or 512 zero bytes)
       and a zero entry.
     **The state is the state at merge** of the commit that produced
     `for_epoch`: every device snapshots each channel's head and status
     when it merges a membership commit, and a `history_sync` for that
     commit, sent at any time by anyone, uses that snapshot. Because every
     record must be at or above the membership floor (decision 3), no
     record from before `for_epoch` can be applied after that merge, and a
     record at `for_epoch` or later reaches the newcomer live. So the
     snapshot is exact and every honest sender writes identical slot
     plaintexts (only nonces differ): there is nothing to race over.
     Devices keep a snapshot until the next membership commit's
     `history_sync` is settled.
   - **Missing `history_sync`.** If none follows a membership commit, C0's
     reconcile coordinator sends one; every other device waits a jittered
     delay that grows with group size. It cancels the delay only when it
     applies a `history_sync` for that commit whose body0 and slots open
     and parse and whose slot plaintexts equal its own snapshot for every
     channel where its own status is `ok` (members can open every slot:
     body0 carries all `key_c`). Otherwise it sends its own when the delay
     runs out (review of revision 6, finding 4): a member sending random
     slots cannot leave a newcomer keyless while honest members are
     online. A device with its own membership commit queued sends at once.
     Duplicates are byte-equal per slot (row 2). Nothing waits on a
     `history_sync`: the new key exists at merge.
   - **`history_sync_request`.** A newcomer that has applied no valid
     `history_sync` for the commit that added it within a fixed timeout
     sends one `history_sync_request` (group-level). Whether it sends
     depends only on whether that message arrived, never on modes.
     Answering follows the same jitter rule.
   - **Handover.** Newcomers added by the commit match slots to channels
     by the ids body0 lists (ids they do not know are ignored), read
     `key_c` and check it: against the head's `chk_commit` when the
     current generation opened with the period, or, after a rekey, the
     entry's `key_commit`. A match gives status `ok`; a mismatch (a random
     slot) gives the head with status `keyless`. A `keyless` channel
     becomes `ok` when a later valid slot gives a matching key, or a record
     with its key becomes the head. C3/C4 visibility holds because private
     channels are their own groups.
   - **Generation entry and backward walk.** The entry is `u64 E_cur |
     key_commit[32] | u64 E_prev | CHK_prev[32]` (80 bytes, zero-padded to
     128): the current generation's opening epoch and
     `sha256("veritra-c7-chk-v1" | key)`, and a wrap of the previous
     generation **in the same group** (it closes at `E_cur`). The wrap is
     zero at the period's first generation and when the previous
     generation lives in another group; then the walk continues through
     the move message (decision 11). A slot is sealed under `key_c`, so
     a newcomer holding `CHK_g` opens the slot of any stored
     `history_sync` whose `for_epoch` falls in generation `g` (at least
     the one that followed the removal opening `g`) and learns `g - 1`.
     Within its fetch depth (decision 10) it so reaches every generation
     of the current period. Key use stops at the period start (no wrap
     there, owner round 2); the fetch never stops early there, or its
     depth would show when the period began.
   - **Unsure.** A device marks every `full` channel of a group `unsure`
     when, in that group, it meets a message it could not fully apply (a
     P1 `invalid` body, a D54 undecryptable message, a message refused as
     `SENDER_REMOVED`, or one passed over as expired or beyond the
     past-epoch window, I33). While a channel is `ok`, it also marks it
     `unsure` when a live post in it carries a signed `gen` that is not
     the generation it holds as current at the post's epoch, unless that
     `gen` is below the start of its current period (a sender still in an
     older period: I1 holds for it, nothing to do) or 0. A `keyless`
     channel is not moved to `unsure` by this, so its path to `ok` stays
     open. `unsure` clears by row 3 or row 5 with a record whose `epoch`
     is above the triggering message's epoch, **or** by a valid slot in a
     `history_sync` whose `for_epoch` is above that epoch and that reports
     this device's own head (row 2) with, for a `full` channel, its own
     current key (review of revision 6, finding 5). So `unsure` normally
     ends at the next membership commit.
   - **One local transaction.** Every C7 change one message causes (rekey
     root, head, records, keys, status, floor, snapshot, a row's
     generation)
     commits in the same local transaction as that message's MLS state and
     cursor (D22, D23). A crash can never apply the MLS step and lose the
     record or the exported key.

   **`history_sync` body layout.** One sealed body, then `N` slots:

   ```
   sealed_body = body0 | slot_1 | ... | slot_N
   body0  = the normal body framing (core idea), whose VAP1 payload is the
            hidden W7 type history_sync:
            {for_epoch: u64, channels: [[channel_id_1, base64(key_1)], ...,
                                        [channel_id_N, base64(key_N)]]}
            ids sorted bytewise, slot i belongs to entry i;
            padded to exactly P(N) = 256 * ceil((512 + 128 * N) / 256) bytes
   slot_i = kc_i[32] | nonce_i[12] | AES-256-GCM(K_i, nonce_i, slot_plain_i, aad)
   slot_key_i = HKDF(key_i, "veritra-c7-slot-v1",
                     lp(community_id) | lp(channel_id_i) | lp(sender_device_id) | lp(action_id))
   K_i  = HKDF(slot_key_i, "veritra-c7-enc-v1", "")
   kc_i = HKDF(slot_key_i, "veritra-c7-kc-v1", "")
   slot_plain_i = full-form head record (512) | generation entry (128) = 640 bytes
   ```

   - `for_epoch` is the epoch produced by the membership commit it
     follows. `sig` in body0 covers the padded VAP1 as for any message;
     each head record keeps its actor's signature.
   - **Channels named, not assumed** (review of revision 6, finding 3).
     The channel list is server-supplied (C3), not ordered by MLS, so two
     devices can disagree about it (a channel created concurrently). The
     sender lists the channels it covers; receivers read `N` from body0
     and match slots by id, never by position. A channel missing from one
     `history_sync` gets its key from a later one, or, for members, from
     the kept `root`.
   - Size: `P(N) + 124 + 700 × N` (each body0 entry is at most 115 bytes
     with 64-byte ids, budgeted at 128). The server checks that the length
     equals this for some `N` from 1 to C3's limit. At 500 channels
     `P = 64,512` (inside the 65,536-byte VAP1 cap) and the body is
     414,636 bytes, about 553 KB in base64, inside the 1 MiB request read
     limit. At 30 channels it is 25,476 bytes. VAP1's decoder accepts
     padding beyond the smallest bucket; receivers refuse any other length.
   - `kc_i` comes from the per-message `slot_key_i`, so a slot never
     repeats a value across messages.
   - A reader of a stored `history_sync` (newcomer, backward walk) has no
     `body_key`; it tries its key on each slot, opens the one whose `kc`
     matches, then checks the record's `channel_id`.

6. **Windows.** A newcomer accepts a body only if it opened under a key
   of the current period, its signed `gen` is that generation's `E_g`,
   its signed `group_id` is that generation's group, its signed epoch
   equals the epoch the history route reports, and
   `E_g <= epoch < E_close`, where `E_close` is the next generation's
   opening epoch (from the entry that wraps `g`) or the closing record's
   `close_epoch`. Bodies in the closing epoch are dropped (a gap, I3). A
   rekey's `E_close` is the removal's epoch, the first epoch the removed
   device is not in; honest devices sealed nothing under `g` at or after
   it, and the window drops anything that was.

7. **Targeted actions follow their target.** Every local row stores the
   period and generation its body was sealed under (live members learn it
   by matching `body_key` against their current-period keys; the sender
   knows it). An action that names a target (`edit`, `delete`, `reaction`,
   `pin`, `poll_vote`, `poll_close`, `admin_delete`) is sealed under the
   current generation only if its target was sealed in the current period
   and the channel is `ok`, and under a random key otherwise. So an
   edit's new text never reaches a newcomer who could not read the post.
   A `reply` carries only `reply_to_id` (the quote is resolved locally,
   `docs/crypto.md` W7 §4), so it is a post. Nothing is held: an edit in
   a channel that is not `ok` is sealed under a random key at once
   (newcomers see the earlier text, a gap).
   - **Deletes reach the history route.** In a community conversation a
     delete is the W7 `delete` (author) or `admin_delete` (moderator, C5)
     payload **plus** a server call that marks the target
     `history_hidden`. The server allows it for the target's sender
     account, or for a moderator role it holds for that conversation (the
     server enforces built-in roles, D80). The history route never serves
     a hidden body; sync keeps serving envelope and body until retention
     removes them, so no member meets a missing body. The same in every
     mode, so newcomers never fetch a deleted post. C5's planned server
     redaction becomes this call in community conversations, where C7
     refuses in-place redaction (server section).

8. **Signatures** (owner decision B).
   - **Live members** need no signature check (core idea). They read the
     signed `gen` only for the `unsure` trigger.
   - **Newcomers** verify `sig` and that its `gen` names the generation
     whose key opened the body. For a sender in the current tree, the key
     comes from a new read of a member's signature key. For a sender no
     longer in the group, the app uses the server's device list until L1
     and marks the post "from a former member". The server keeps a revoked
     device's `signing_key` (`identity_store.go:649` only sets
     `revoked_at`) and nulls it when an account is deleted
     (`account_store.go:170`), so a deleted account's posts drop. The
     newcomer fetches these keys in one bulk call at join, in every mode
     (server section), so the fetch shows nothing about modes.
   - **Records** are verified only against keys in the current tree
     (decision 4); the server's list is never used for them.
   - **Credential keys never change in place.** `inspect_commit`
     (`crypto/rust/src/mls.rs:1114-1129`) checks only that an Update or
     path keeps the identity; the C7 ABI step adds the signature-key
     comparison, with a test that an Update changing the key is refused.
     A device *replacement* (remove and re-add of the same identity with a
     new key package in one commit, tested near `mls.rs:1413`) does change
     the key: the member-key read then returns the new key, so the
     replaced device's earlier posts are verified like a former member's
     (server list, marked), and a removal it is, so it rekeys.

9. **What each side reads.**

   | Change | Existing members | Later newcomers |
   |---|---|---|
   | to `full` | Read live, as before; get the key in the record body | Posts from the switch on |
   | to `members_from_join` | Read live, as before; delete the period's keys | Nothing older than their join |
   | off and on again | As above | Only the newest period (round 2) |
   | removal during a `full` period | Derive the new key at merge | The whole current period, by the backward walk |

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

11. **Moves** (C0/C3) are `move` records, proposed in the **new** group;
    a generation lives in one group, so a move of a `full` channel opens a
    new generation there with the record's random key.
    - The compact form adds `lp(close_group_id)` (the old group) and a
      128-byte wrap field, always present: for a narrowing move (open to
      private) of a `full` channel it wraps the old group's current
      generation as `u64 E_prev | CHK_prev[32] | lp(prev_group_id) |
      u64 E_prev_close` (at most 114 bytes, zero-padded), and the move message's body is
      sealed under the new key, so a newcomer walking back opens it;
      otherwise it is 128 random bytes. A widening move (private to open)
      starts a new period with no wrap. Same size in every mode.
    - `close_epoch` is the old group's epoch when the actor sent the move.
      Freshness of the new key is judged by the new group's floor.

## Trace 1: removal, then an add

Shared group `G`; channel `C` is `full`; the period opened with record
seq 5 at epoch 10 (key `K10`). Members A, B, R and others hold `K10`.

| Step | What happens | Keys | R |
|---|---|---|---|
| 1 | A commits the removal of R, producing epoch 20 | Every device merging it gets `root20` from the commit call itself and derives `K20 = c7_derive(root20, …, C)` in the same transaction. Generation 10 closes at 20; posts at epoch 20 on seal under `K20` | Not in epoch 20: cannot derive `K20` |
| 2 | A sends `HS20` (`for_epoch = 20`) | Slot `C`: head seq 5, entry (`E_cur = 20`, commit of `K20`, wrap: `E_prev = 10`, `K10`), sealed under `K20` | Cannot read it |
| 3 | B commits the add of N, producing 21 (no waiting), and sends `HS21` | Slot `C`: `key_c = K20`, the same head and entry bytes as `HS20`'s. N: row 1, checks `key_commit`, `ok`; walks back: `HS20`'s slot (sealed under `K20`) gives `K10` with window [10, 20) | |

If B's add wins the epoch race instead (add produces 20, the removal is
re-staged and produces 21): N joins at 20 holding `K10`, which R also
holds, but R is still a member at 20; at 21 everyone, N included, derives
`K21`. In both orders R holds nothing used at or after its removal epoch.

A switch to `full` that admin X sent at epoch 19 and that is sequenced
after the removal is stale (epoch 19 below floor 20): invalid on every
device, and X's app re-proposes it at epoch 20 or later. In revision 4
this case needed a rekey proposal.

**Switch off racing an add** (review of revision 6, finding 2). `C` is
`full` at epoch 20 with `K20`. Admin X switches it off at epoch 20; B's
add of N produces 21 and is sequenced before X's switch. Every device
merging 21 snapshots `C` as `full` with `K20`, so `HS21` hands N `K20`.
X's switch (epoch 20) then arrives below the floor 21: invalid
everywhere, and X's app re-proposes it at epoch 21, which N reads live
(row 3) and applies: N drops `K20` from current use. Under revision 6's
looser rule, the epoch-20 switch would have applied on old members but
was missing from N's `history_sync`, so N would have kept sealing under
`K20` and handing it on.

**A removal the server labels as an add.** The commit call returns
`removed_any` and `root` from MLS, so every device rekeys whatever the
label says.

## Trace 2: record ordering

Channel `C`, admins P and Q, member M. `h_k = hash(record seq k)`.

| Step | Record received (sync order) | Row | Head after |
|---|---|---|---|
| 1 | seq 0 `create` mfj by P, prev zeros (proposal) | 1 | 0 |
| 2 | seq 1 `switch` full by P, prev `h0` | 3 | 1 (full) |
| 3 | seq 2 `switch` mfj by P, prev `h1` | 3 | 2 (mfj) |
| 4 | seq 2 `switch` full by Q, prev `h1` (sent concurrently) | 4: lost race; Q's app tells Q | 2 |
| 5 | `history_sync` slot from M reporting seq 2 (P's bytes) | 2 | 2 |
| 6 | A slot reporting seq 2 with Q's bytes (a device the server showed Q's first) | 7: fork, `closed` | 2, closed |
| 7 | seq 3 `switch` full by Q, live, prev `h2(Q)`, seq above highest valid seen (2) | 5: recovers; a new period | 3 (full), ok |
| 8 | seq 5 `switch` (seq 4 never arrived) from a slot | 7: missed record, `closed` | 3, closed |
| 9 | seq 6 `switch` mfj by P, live, above highest seen (5) | 5: recovers | 6 (mfj), ok |

The vectors pin every row, including row 4 against row 7 for equal `seq`
and row 5's "above highest valid seen". A newcomer starts at row 1 with
the first slot it sees; a later add-time slot is row 2 (same bytes), row
6 (older) or row 7.

## Trace 3: two removals in a row, either order of `history_sync`

`C` `full` from epoch 10 (`K10`). A removes R1 (produces 20); before
anyone sends `HS20`, D removes R2 (produces 21).

| Step | What happens | Keys |
|---|---|---|
| 1 | Merge 20 | All derive `K20`; R1 out |
| 2 | Merge 21 | All derive `K21`; R2 out. R2 holds `K10` and `K20`: it was a member at 20, and posts at epoch 20 were its to read |
| 3a | `HS20` arrives first, then `HS21` | `HS20`: slot under `K20`, entry `E_cur = 20`, wrap `K10`. `HS21`: slot under `K21`, entry `E_cur = 21`, wrap `K20` (window [20, 21)) |
| 3b | `HS21` arrives first, then `HS20` (sent late, at epoch 21) | Same two bodies: each slot is fixed by its `for_epoch`, not by when or by whom it is sent |
| 4 | The server hides `HS20` from B only | B's delay runs out; B sends its own `HS20'` with the same slot plaintexts. Nothing differs, nothing closes |

A newcomer at 22 holds `K21` and walks `HS21` → `K20` → `HS20` → `K10`.
Revision 5 closed `C` on B in this sequence (review finding 1).

## Trace 4: a device removed and re-added

Device D is removed by the commit that produces 20 and re-added by the
commit that produces 25.

| Step | D | Others |
|---|---|---|
| 1 | Applies its own removal: deletes `G`'s C7 state (heads, `K10`, floor) | Derive `K20` |
| 2 | — | A removal at 23: derive `K23` |
| 3 | Before applying the Welcome at 25: nothing left to delete. After it: a newcomer with join epoch 25, floor 25 | `HS25` |
| 4 | Row 1 from `HS25`'s slot: head, `key_c = K23`, `ok`; walks back to `K20` and `K10` | |

D reads the posts of the period it missed exactly as any newcomer would;
the channel is `full`, so that is intended. Without step 1 its old head
would meet `HS25`'s slot as row 7 (review finding 5).

## Server: wire, storage, routes

- **Send.** The envelope route (`POST /api/v1/messages/envelopes`) takes a
  `sealed_body` field, required on every envelope in a community
  conversation and refused elsewhere. A channel envelope's body is
  `124 + 256 × k` bytes, at most 65,660 (the 65,536-byte VAP1 cap plus
  framing). A group-level envelope's body is either that or exactly
  `P(N) + 124 + 700 × N` for some `N` (`history_sync`). A community envelope carries no
  server-visible `reply_to_id` or `thread_root_id` (W7 keeps references
  inside the payload; check `mobile/lib/core/models.dart` before C7
  sends), or a newcomer's reply would show it read a pre-join post. Once
  C6 franks, every community envelope carries a `frank_commit` (random
  for C7's hidden types, decision 3).
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
  created_at, expires_at, history_hidden INTEGER NOT NULL DEFAULT 0, body
  BLOB)`, written in the send transaction. Sync serves the body with its
  envelope, read from this table, not copied into `sync_events`.
  Admission limits (D38) count body bytes.
- **Pruning and deletes.** A body lives exactly as long as its envelope:
  the conversation's retention (and per-channel retention, D51) sets
  `expires_at` alike, and the sweeper removes both.
  `POST /api/v1/messages/{id}/history-hide` sets `history_hidden` for the
  envelope's sender account or a moderator role in that conversation
  (decision 7), with an id-and-kind audit entry as C5 keeps. Switching to
  `members_from_join` deletes nothing on the server. The confirm dialog
  says: "People who join later won't see earlier posts. Members who
  already have them keep them."
- **Legacy edit and delete routes refused.** `UpdateMessageEnvelopeWithSyncEvent`
  and `DeleteMessageEnvelopeWithSyncEvent` (`message_store.go:309`, `:354`)
  rewrite an envelope in place; in community conversations they answer
  409, for authors and moderators alike.
- **No server paging in community conversations.** `ListMessages`
  (`message_store.go:529`, `GET /api/v1/conversations/{id}/messages`)
  serves every envelope with no join filter, and the chat screen pages
  through it (`chat_screen.dart:277,1142` → `loadOlderMessages` →
  `listMessagePage`, `app_state.dart:1969`). In community conversations
  the app never calls it (older history is local), and the server answers
  it with 409 `history_route_only`.
- **History fetch.** `GET /api/v1/conversations/{id}/history?channel_id=&before=&limit=`,
  per calling device, the only route that serves pre-join bodies. It
  returns `{message_id, sender_device_id, action_id, channel_id,
  created_at, epoch, body}` for unexpired, undeleted, not
  `history_hidden` envelopes from unblocked senders that sync did not give
  this device: those before its `joined_after_event_id`, and those after
  it but in an epoch before its `joined_epoch` (the I51 withholding in
  `mls_group_store.go:779-783`). `channel_id` empty means the group-level
  stream. Current member devices only; the same for every channel and
  mode. References are never served there.
- **Former members' keys.** One bulk call at join returns the
  `signing_key` of every former member device that posted in the
  conversation (revoked devices included), to current members only, the
  same in every mode (decision 8).
- **Authority.** The server cannot check records. Apps check them against
  C4's signed role state (built-in roles), never the server-reported role
  (D80). C7 switches cannot ship before that state exists.

## What the server still learns

| Signal | What it shows | Cost to remove |
|---|---|---|
| A newcomer fetching deeper than the fixed prefetch, in some channels only | Those channels are `full` | No paging (above) and a fixed depth. Owner question 1 |
| A newcomer downloading a pre-join attachment | That post's channel was `full` then | Owner question 2 |
| A newcomer reporting a pre-join post (C6 `POST /api/v1/reports` carries `envelope_id` in clear) | That post's channel was `full` then | C6 moves the envelope id inside the sealed report for community reports, or apps do not offer reports on pre-join posts. For C6 to decide |
| A moderator hiding a post from before its own join | That post's channel was `full` then | Apps do not offer it on posts from before the moderator's join, or accept. For C5 to decide; default: accept |
| A newcomer fetching former members' signing keys | Nothing about modes: one bulk call at join, in every mode | None needed |
| A second `history_sync` for one commit | A committer went offline, or a member sent slots that disagree with others' snapshots | None needed |
| Message sizes | The W7 256-byte bucket, as today. Create and switch messages are in the 512-byte bucket like short posts; moves are 768 bytes, but the server sees moves anyway; `history_sync` has a fixed shape | Coarser padding (L2) |
| Per-channel retention (D51) | A long retention on one channel hints that it keeps history | The UI never couples the two settings |
| Author and moderator deletes (`history-hide`) | Which post was deleted, in every mode (as for other conversations today) | None needed |
| A `history_sync` from a second sender | A committer went offline, or the server hid one from it | None needed |

## Interaction with MLS and C4

- No extra commit for a switch; records are application messages.
  Removal commits rekey every `full` channel of their group at merge,
  with no message; adds never rekey.
- Records and bodies from a past epoch are applied within OpenMLS's
  past-epoch window; outside it they are lost and the group turns
  `unsure`.
- A private-channel record is judged against the shared group's C4 state
  at receipt; the two groups have no common order (C4 review residual).
- A role change that adds or removes members of a private channel's group
  is a membership commit and so is followed by `history_sync` (and, for a
  removal, rekeys that group's channel).

## Trust limits

- A newcomer verifies signatures (against the current tree, or for posts
  by former members the server's list, marked), the chain from its first
  record, key commitments and windows, but cannot check C4 authority for
  records older than its join, a head record whose actor has left, nor
  removals before its join; it trusts the member who sent its
  `history_sync`, which could also withhold keys or give wrong wraps.
- Until L1 (owner decision B), a server colluding with a removed member,
  who holds old keys, can insert backdated posts in a former member's
  name into a generation that member could read; they show "from a
  former member".
- **A device that never sees a record stays out of step.** If the server
  withholds a whole envelope (a switch off, say) from one device, nothing
  triggers `unsure`: no message failed. That device keeps sealing under
  the old period's keys (I1 still holds) and, if it commits an add, hands
  that period's key to its newcomer, who may then read the old period
  although the channel was switched off (I4 does not hold for that
  newcomer). Other devices' later reports bring both back by row 3; a
  live post with an unknown `gen` makes the device `unsure`. Accepted;
  the server must target the committing device.
- A malicious member could stretch a window it describes; it can only
  expose posts real senders sealed under a `full` generation, which that
  member could already read and leak.
- A server that strips bodies, or a member that sends bad bodies or a
  false `gen`, can make `full` channels `unsure` (history gaps); the server
  sees no difference, and it can already delete bodies.
- Until L1, a server that adds a hidden device can read new live posts and
  forge history from that device: the same limit as live groups today.

## What it does not give

- No forward secrecy for history: a `CHK` holder reads its generation.
- No post-compromise healing short of a removal: a stolen `CHK` stays
  valid until the next removal in that group; self-updates rotate MLS
  keys but not `CHK`.
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
- **W7 types** (hidden, never franked): `history_change` (body
  `{"r": base64(compact record)}`), `history_sync`,
  `history_sync_request`. Belongs to the W7 section of `docs/crypto.md`.
- **Rust ABI 13** (built in step 2, 2026-11-07, as `crypto/rust/src/c7.rs`
  and the C ABI; change log in `docs/crypto.md`; C4 takes the next number).
  Approved in principle (D80). **Each piece needs the independent crypto review
  before it lands; the exporter use in particular** (its label and
  context, the export from the staged or pending commit, and the
  guarantee that no other exporter output leaves the core):
  - C7 variants of `pm_crypto_group_process_commit` and
    `pm_crypto_group_merge_pending_commit` that return `{removed_any,
    added_any, new_epoch, root}`, with `root` exported inside the same
    call before the merge (`StagedCommit::export_secret` for another
    device's commit, `group.pending_commit()` for its own; OpenMLS 0.9.2),
    and "removed, no root" for a commit that removes this device (new;
    decision 5). Tests: the staged export before merge equals
    `MlsGroup::export_secret` after it; a removal the server labels as an
    add still rekeys; this device's own removal returns "removed" and sync
    continues;
  - a decrypt that also returns the message's epoch (a new export;
    `pm_crypto_group_decrypt` at `crypto/rust/src/ffi.rs:1521` stays);
  - a read of a member's signature key from the current tree, by account
    and device id;
  - `inspect_commit` refuses an Update or path that changes a leaf's
    signature key (decision 8);
  - credential-key sign and Ed25519 verify over a fixed domain allowlist
    (`veritra-c7-post-sig-v1`, `veritra-c7-history-v1`; the C1 invitation
    binding later added `veritra-invite-binding-v2` to the same allowlist,
    see `C1-invite-format.md`);
  - `c7_derive` (HKDF as above) and `c7_seal`/`c7_open` (key commitment,
    AES-256-GCM, random nonce), on existing dependencies (owner decision
    A).
  The crypto-only half (seal, open, derive, sign/verify, member-key read,
  epoch-returning decrypt, the `inspect_commit` check, the commit-result
  variants with `root`) does not depend on the ordering rules and can be
  built first.
- **Server:** `sealed_body`, `envelope_bodies` with `history_hidden`, the
  history route, the former-member key route, the group-level exception,
  the C2 change, the replay check, refusals of legacy edit/delete and
  paging in community conversations, the `history-hide` call.
- **Local DB:** per channel the head, the current period's records (bytes
  and hashes), highest valid `seq`, status, and the current period's generations (opening epoch,
  group, key, window); per group the membership floor, the last removal's
  `root` and the per-commit snapshots; per row its period and generation. In the sealed
  database, written in the MLS transaction; deleted on the device's own
  removal and before a Welcome; not in backups or K2 bundles.

## Build order

1. Independent review of this revision.
2. Rust ABI with the independent crypto review, and vectors
   `testing/vectors/c7-*.json` (bodies, slots, both record forms, the
   exporter rekey from a fixed group state, every ordering row, windows,
   the implicit genesis, `P(N)`, the compact record's 512-byte VAP1 with
   its 19 bytes of slack), checked by Rust, Go and Dart; the Update-key
   refusal test.
3. Server: migration, `sealed_body`, replay check, history route,
   former-member key route, `history-hide`, group-level and C2
   exceptions, legacy-route and paging refusals.
4. Dart: two-part send/receive, records and the ordering table, rekey at
   removal merge, `history_sync`, `keyless`/`unsure` states, re-add
   wipe, targeted-action sealing, backward walk, two-pass import,
   prefetch, all in the MLS transaction.
5. Flows and tests: two devices, leave, switch both ways, off/on, Traces
   1 to 4, a stale switch refused, lost committer, a stripped body
   (unsure), a newcomer added by an `unsure` committer (keyless), a test
   that withholding one `history_sync` from one device changes nothing,
   and server-side tests that a `full` and a `members_from_join` channel
   give identical rows, sizes and requests for posts, retries, record
   messages (both directions), add-time `history_sync`, and removals.

Depends on: C0 layout, C1 per-conversation sync halting, C3 channel state
and moves, C4 role state (and its channel-creation rule), C5 deletes
(`history-hide` in place of redaction), C6 (random `frank_commit` for C7
types, the report residual).

### Build status (2026-11-11): step 3, first slice

Built behind `PRIVATE_MESSENGER_C7_HISTORY=1` (off by default, so today's
app, which sends no body, keeps working): the `sealed_body` field on
`POST /api/v1/messages/envelopes`, migration 0083 (`envelope_bodies`, the
body removed with its envelope by `ON DELETE CASCADE`), the size rule
(`server/internal/storage/c7_body_store.go`), the replay comparison, the
body served with its envelope on both sync routes only (read from
`envelope_bodies`, never stored in `sync_events`; the single-message GET
serves no body, so a newcomer cannot fetch a pre-join or hidden body by
id), and the 409
`history_route_only` answers for legacy edit, delete and paging in
community conversations. Off, a body is refused everywhere (400
`invalid_sealed_body`).

Second slice (same day, migration 0084): the history fetch
(`GET /api/v1/conversations/{id}/history?channel_id=&before=&limit=`,
newest first, `before` a message id, at most 100 rows; each body records
its sync event and named epoch so the fetch serves exactly what the I51
join filter withheld), the former-member key call
(`GET /api/v1/conversations/{id}/former-member-keys`, `{devices:
[{device_id, account_id, signing_key, revoked}]}`), `history-hide`
(`POST /api/v1/messages/{id}/history-hide`, sender or a role that may
delete the sender's messages; a moderator's hide adds a `message_hidden`
row to `moderation_events`), and the C0/C2 exceptions for conversations in
the C0 layout: no channel keys means group-level (allowed in the shared
group and in private groups, exempt from C2 and slow mode, still subject
to timeouts), and a private group's posts may name their own channel.
Admission already meters the request body, so body bytes count (D38).

**Deviation (2026-11-11, closes a gap the first build left):** the server
cannot read a message's type, so "group-level skips C2" would let any
member skip slow mode and admins-only posting by leaving out the channel
keys. The exemption is therefore narrowed to bodies the size rule
identifies as a `history_sync` and not also as a channel body
(`c7SyncOnlyBodySize`; in a private group, one channel, exactly 1,592
bytes). Every other envelope takes the normal posting checks, and a private
channel's group names its channel in the clear metadata on every post.
Cost: a `history_sync_request` (channel-sized) from a non-admin in an
admins-only private group is refused; the jittered `history_sync` senders
cover it. Receivers turn a group-level message of any other type into an
`invalid` row, so a post disguised at sync size never shows.
All in `server/internal/storage/c7_history_store.go`; every route is 404
while the flag is off. Bodies stored before 0084 are never served by the
history fetch. Server tests are still to be written (no suites were run
in this pass, owner instruction).

Step 4, first slice (same day): the two-part send and receive with a
random `body_key` for every message (the `members_from_join` behaviour of
the implicit genesis), the API client calls for the three routes, the
history-hide call after an own delete, and the switch that follows the
server's `c7_history`. See `docs/crypto.md`, change log. Not built: the
generation keys and records (create, switch, move), the ordering table in
the receive path, rekey at removal merge, `history_sync` and its request,
`keyless`/`unsure`, the re-add wipe, targeted-action sealing, the newcomer's
backward walk, two-pass import and prefetch, the private group's
`channel_id` on sends (until it is sent, with the flag on every honest
private-channel post is group-level on the server, so slow mode and an
admins-only posting policy are skipped for all of them; keep the flag off),
the receiver rule that a group-level message is one of the two
hidden types, local schema for C7 state, and every step-5 flow and test.

Step 4, second slice (same day): the server gap above is closed, private
groups name their channel, the three hidden types are registered with the
group-level receiver rule (docs/crypto.md W7 table), and each group's
membership floor and removal root are kept in one sealed setting
(`setting:c7.group.<conversation>`, `mobile/lib/crypto/c7_group_state.dart`)
written in the same transition as the merged MLS state at all three merge
sites, with the re-add wipe at removal and Welcome. A sealed setting, not a
new table, so no local schema change. Tests for the pure parts and the
switch are written (`mobile/test/c7_two_part_test.dart`,
`server/internal/httpapi/c7_history_test.go`) but were never run.

Still not built, and blocked on C4: records (create, switch, move) need
C4's verified role state for their authority check (section "Authority":
switches cannot ship before it), and without records no channel is ever
`full`, so `full` sealing under generation keys, `history_sync` slots that
hand keys over, `keyless`/`unsure`, targeted-action sealing and the
newcomer's import, backward walk and prefetch have nothing to carry. Also
left: sending `history_sync` (all slots random until then) and its request
with the jitter, the per-channel chain state and its storage.

### Build status (2026-11-12): step 4, full mode in the client

Built on `feat/c7-full`, client only, behind the same switch
(`c7SealedBodies`, which follows the server's `c7_history`; off by
default). No crypto ABI, local schema or server migration change: every C7
state is a sealed setting written in the same local transaction as the MLS
step that causes it (`setting:c7.group.<conversation>` and
`setting:c7.chan.<conversation>|<channel>`, through `c7Settings` on the
sync, merge, outgoing and import transitions). Settings never enter a
history snapshot, so no generation key reaches a K1 backup or a K2 bundle
(checked in `mobile/test/c7_full_native_test.dart`).

- **State** (`mobile/lib/crypto/c7_channel_book.dart`,
  `c7_group_state.dart` v2): per channel the chain of decision 4 (head,
  kept records with their full forms, highest `seq`, status, miss epoch),
  the current period's generations with their keys and closing epochs, the
  retired generation epochs, and this device's pending own proposal; per
  group the membership floor, the kept removal root, a slot snapshot and a
  `history_sync` duty per membership commit (the newest four), and a
  newcomer's join epoch and request time. Anything malformed reads as
  `closed` (a channel) or empty (a group): nothing is sealed under a
  history key and nothing is handed over.
- **Records** (create, switch): proposed by an owner or admin, applied by
  the sender only when its own message comes back in sync order (stale
  when a membership commit was sequenced first: kept, reported, proposed
  again by the app; lost when another record took the seq). A live record
  is checked before the table: the sender's leaf is `approved` (D119), its
  epoch is at or above the floor, the actor is owner or admin in the
  verified role record (`VerifiedRoleSource`; a private channel's group is
  judged by its shared group's), and the signature verifies against the
  actor's key in the current tree. A record that opens `full` seals its own
  message under its key, as the design says.
- **Rekey at merge**: a removal derives every `full` channel's next
  generation from the exporter root MLS returned, at all three merge
  sites; a record applied after a later removal catches up from the kept
  root. Every membership commit fixes the slot snapshot and the duty (the
  committer at once, others after 20 s plus up to 2 s per member, at most
  10 min, unless a `history_sync` carrying their own snapshot arrives).
  Own removal and a Welcome delete the group's C7 state (Trace 4).
- **Unsure**: an undecryptable message (D54, which includes one beyond
  the past-epoch window), an unapproved sender, a missing or damaged body,
  a ratchet-advanced message (`SENDER_REMOVED` included), an invalid
  payload, a misrouted C7 type, and a message or call signal sync passes
  over as expired (I33's tombstone, committed by
  `C7HistoryService.c7CommitExpiredSkip` in the same transaction) mark
  every `full` channel of the group with the group's current epoch. The `gen` trigger is below. `unsure` clears by a
  record above the miss epoch or by a `history_sync` slot, for a later
  membership epoch, with the device's own head and current key.
- **`history_sync`**: built from the snapshot fixed at merge, naming the
  channels with state plus the server's list (`C7ChannelListSource`) and a
  private group's channel, body0 padded to exactly `P(N)`; opened by
  members (check against the chain, a missing key taken, `unsure`
  cleared, the duty settled when the slots carry this device's own
  snapshot) and by newcomers (heads and generations adopted; a head whose
  actor has left on the word of the MLS-authenticated sender, trust
  limits). A newcomer that gets none asks once with
  `history_sync_request` after 60 s; members holding that snapshot send
  again after their delay.
- **Sealing**: text, reply, attachment manifest and poll seal under the
  current generation only while the channel is `full` and `ok` and the key
  is held; everything else, every targeted action included, seals under a
  random key.
- **Vector**: `testing/vectors/c7-sync-v1.json`, one whole `history_sync`
  as sent, made by an independent Python implementation
  (`testing/vectors/c7-sync-v1.py`). Dart opens it as sync does and
  verifies its signature; Go checks the sealed length against the
  server's size rule; Rust checks the layout, the AEAD of body0 and of
  every slot, and the signature over its production
  `post_signed_fields` (deviation 8).

**Deviations and interpretations (for the crypto review):**

1. Freshness (epoch at or above the floor) is checked for proposals only;
   a slot's head is older than its `for_epoch` by construction and is
   bounded instead by `head.epoch <= for_epoch`.
2. `for_epoch` counts only when it is a membership epoch this device
   merged or joined at (its snapshot, its floor or its join epoch) and is
   not above the epoch MLS authenticated for the message. Otherwise any
   member could clear `unsure` or settle a duty with no commit.
3. The `gen` trigger: a live member does not learn the signed `gen`
   directly. A post is in step when its body key equals the post key of
   the generation held at its epoch; otherwise its signature is checked
   with `gen` 0 and with each retired generation below the period start
   this device remembers; failing all, the channel turns `unsure`. A
   sender in an older period whose `gen` this device never held is so
   taken as out of step: a gap, never a leak.
4. A generation opened at MLS epoch 0 (a group no one has joined yet)
   seals nothing under its key: `gen` 0 means a random key.
5. Targeted actions stay under random keys until each local row records
   the period it was sealed in (decision 7 needs a row column: local
   schema 41, not taken). A gap for newcomers, never a leak.
6. A newcomer adopts a slot only for a channel it already knows: the
   server's list (`AppState` answers `C7ChannelListSource` with the
   shared group's open and announcement channels) or its private group's
   channel. A channel the server leaves out stays `members_from_join` for
   that newcomer (fails closed); one it adds gets a zero slot.
7. An own proposal that has not come back after 5 minutes
   (`c7ProposalTimeout`, owner 2026-11-12: timeout and retry) is reported
   `timeout` and the device may propose again. It is not forgotten: other
   devices may still apply it, so it is kept (the last four, `late`) and
   applied here when its echo arrives; a newer own proposal for the same
   seq is then `lost`, as for anyone else's record. The expiry is lazy (the
   channel view and the next proposal read it), so no write happens
   outside a proposal or a sync step.
8. A group-level message signs channel `""` (two zero length bytes),
   as its aad already binds it. Settled 2026-11-12 with the smallest
   change: Rust's `post_signed_fields` now takes an empty channel id (as
   its `body_aad` did), and Dart's `c7PostSignedFields` refuses what Rust
   refuses (an empty community, action, group or sender id, any id over
   64 bytes). No wire, ABI or vector change: `post_signed_fields` has no
   C ABI caller, the bytes Dart sent were already the bytes the vector
   pins, and the Rust vector test now uses the production function.

**Not built (left for the next slices):** the newcomer's import (backward
walk through stored `history_sync` slots, the per-channel and group-level
fetch, window and signature checks, former members, two-pass import),
the prefetch depth (owner question 1), the app wiring (a create record
from `createChannel`, a work pass
calling `c7DueWork` and `c7Send` after sync, the setting toggle and its
system line), C3 conversion (`move`, its wrap, the server route and
migrations 0088-0089), and targeted-action sealing under generation
keys.

## Open questions for the owner

Earlier questions: 1 (off/on) and 2 (server sees the flag) are answered in
round 2; 3 (ABI) is approved; 4 (server-checked admins) is moot; A, B and
C are answered in round 3.

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
   membership commit: 25 KB at 30 channels, so about 25 MB of egress per
   membership commit at 1,000 devices (0.6 MB for the add commit itself;
   C0 batches joins). Accept, or add targeted delivery of add-time
   messages to the new devices only (a server feature, C8)?

## Owner decisions (2026-11-01)

- The history setting may be changed later by admins (needs re-keying rules; revisit the design).
- Accepted: history copies double stored bytes for full-history channels, and history is lost if every key holder is gone.

## Owner decisions, round 2 (2026-11-01)

- Earlier `full` periods stay unreadable to newcomers after a switch off and on.
- The server must **not** see the history flag: hide it (needs a design change; the sequence/flag handling above assumes server visibility).
- Crypto ABI additions approved, with independent review.

## Owner decisions, round 3 (2026-11-07)

- **C:** rekeys come from the MLS exporter secret at the removal epoch. No member-chosen rekeys. Rekey data passed on in `history_sync` slots is identical bytes whoever sends it.
- **A:** reuse `aes-gcm` and the existing HKDF; no new crates.
- **B:** trust the server's device list for departed senders' keys until L1, and mark such posts "from a former member". Records are verified only against keys in the current tree.

## Changes in revision 7

| Review item (revision 6) | Fix |
|---|---|
| 1 No MLS-authenticated removal signal | Commit-processing and merge calls return `{removed_any, added_any, new_epoch, root}`; `root` exported inside the call from the staged or pending commit; per-channel keys from `c7_derive(root, …)`; own removal returns "removed, no root"; stand-alone exporter call dropped; the three Dart merge sites named |
| 2 `history_sync` boundary | State at merge of the commit producing `for_epoch`, snapshotted per membership commit; every record must be at or above the latest membership commit (stricter option, tradeoff stated); a sender without the key writes a random slot. Trace 1 adds a switch off racing an add |
| 3 Channel set not MLS-ordered | body0 lists sorted channel ids with keys; slots matched by id; `P(N)` recomputed (128 bytes per entry); `root` kept per group until the next removal |
| 4 Any parseable `history_sync` cancels fallbacks | Cancel only when slot plaintexts equal the device's own snapshot where it is `ok` |
| 5 `unsure` lasts until an admin record | Also cleared by a later `history_sync` slot that reports this device's own head and key |
| 6 Ordering table gaps | Row 3 gives `keyless` for an opening report without key; "first seq held" defined; per-device reordering listed as a server-targets-one-device case |
| 7 Wording | I6 says "used to seal"; `gen` trigger fires on any mismatch within the current period; post-compromise residual; big-endian integers; former-member keys in one bulk call at join |

## Changes in revision 6

| Review item (revision 5) | Fix |
|---|---|
| 1 Siblings close channels when the next commit is a removal | Gone: rekeys are exported at merge (owner C); no rekey record. Trace 3 runs both orders and a withheld `history_sync` |
| 2 Row 3 could undo a switch-off; member grinding | Gone with siblings; the table has no rekey rows |
| 3 Decide C before ABI | Decided (owner round 3); ABI list has the exporter export and the crypto-review requirement |
| 4 "Never franked" leaks via `frank_commit` | C7 types send a random `frank_commit`; C6 exemption; noted in C6's open items |
| 5 Re-added device | C7 state deleted on own removal and before a Welcome; rejoin as a newcomer. Trace 4. Replacement key change covered in decision 8 |
| 6 Keyless sibling knocks `ok` devices to keyless | Gone with siblings |
| 7 Highest `seq` inflatable; overflow; "no wrap" | Only fully valid records count; `seq = 2^32 - 1` invalid; rekey wraps are deterministic entries |
| 8 Wording | Newcomer floor unset; a valid `history_sync` means body0 and every slot open; same-mode switches defined; records only against the current tree (owner B) |
| Also removed | Stale generations, the membership barrier and the removal-time edit hold: the new key exists at merge |
