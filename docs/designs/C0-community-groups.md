# C0: how communities map to MLS groups

**Status: proposed, not yet built.** Revision 2 (2026-10-24), after an
independent review, against `main` at `dbce0f2`. Measurements are in
[`testing/evidence/C0-community-groups.md`](../../testing/evidence/C0-community-groups.md).

## Decision

**A community has one shared MLS group for all its open channels, plus
one MLS group per private channel.** This is the gap study's layout.

- **Open channels share a group.** Each message in the shared group
  carries its `channel_id` twice: in clear in the envelope metadata, and
  inside the encrypted payload. Receivers treat a mismatch as invalid (the
  same pattern as sender binding, D25), so the server cannot move a post
  between channels.
- **Announcement channels are open channels** in the shared group. The
  server refuses a post there from a role that may not post; it knows the
  role and the `channel_id`. Members' apps drop such a post too (C2).
- **A private channel is its own group**, whose members are the devices of
  the accounts allowed to see it (C3, C4). The server sees that group's
  device list, and therefore **who is in each private channel**. That is
  no change from today, where every conversation's membership is
  server-side, but C3 should say so to users.
- **Every member device self-updates.** Each one commits one self-update
  soon after joining a group, and again on a timer (C8 sets the period).
  The measurements show why
  ([Keep the tree warm](#keep-the-tree-warm)).

## Dependency on W7

`channel_id` must be a **reserved top-level context key** of the W7
payload, the 7th next to `v`, `type`, `conversation_id`,
`sender_device_id`, `action_id` and `body`:

- **Required** in a `community_shared` conversation, and **absent**
  everywhere else.
- **Invalid** when it is missing where required, present where it must be
  absent, or different from the envelope's `channel_id`.
- **Order:** it must land in W7's receive policy before any W8 sender.

The W7 section of `docs/crypto.md` belongs to the W7 package, so this is
recorded here as a W7 dependency, not edited there.

## What exists today

- `CreateChannelWithConversation` (`server/internal/storage/community_store.go`)
  makes one conversation per channel, with every community member in it.
- `ManageCommunityMember` adds a new member to every channel conversation.
- The app sets up one MLS group per conversation (`_setUpConversationGroup`
  and `_reconcileMlsMembership` in `mobile/lib/core/app_state.dart`).
- So a community join means one commit and one Welcome per channel, and
  every device processes one commit per channel for every join and leave.
- `private` and `announcement` are only labels: every member is in every
  channel.

## Measured cost

Release build, shared 4-vCPU host (times move by about 2x; bytes are
exact). Leaves are devices.

| Leaves | Welcome per join | New device | Each member, per add | Removal: cold / after 10 / 50 / 100 self-updates |
|---:|---:|---:|---:|---:|
| 200 | 42 KB | 9.5 ms | 1.5 ms | 17 KB / 2.6 KB / 2.1 KB / 1.6 KB |
| 1000 | 206 KB | 46 ms | 7.3 ms | 83 KB / 20 KB / 4.7 KB / 2.9 KB |

- **Add commits are cheap.** Each is 571 bytes at every size.
- **Removals start expensive.** Every join is an add-only commit with no
  update path, so a tree that only grows stays **cold**. That is the
  normal case, not the worst one. In a cold tree a removal (and the first
  self-update) costs about 83 bytes per leaf.
- **Egress is the bigger number.** The server sends every commit to every
  other device: one cold removal at 1,000 leaves is about **83 MB** of
  server egress. After 100 self-updates it is 2.9 MB.

Per join of one device:

| Example community | One group per channel | Shared + private |
|---|---|---|
| 200 leaves; 15 open, 3 private channels | 653 KB, 148 ms on the new device; 15 commits on every device | 69 KB, 16 ms; 1 commit |
| 1000 leaves; 30 open, 5 private | 6.4 MB, 1.4 s; 30 commits (220 ms) on every device | 414 KB, 93 ms; 1 commit (7 ms) |

## Options weighed

1. **One group per channel (today).**
   - **Cost:** every membership change costs one commit per channel. For
     open channels those groups have the same members, so they rekey in
     step and isolate nothing.
   - **Privacy:** the server already learns the channel from the
     conversation id.
   - **What it does well:** each channel ratchets on its own, so a device
     can fetch and page one channel without the others.
2. **Shared group for open channels + one per private channel
   (chosen).**
   - **Cost:** about 1/C of option 1 per join or leave.
   - **Privacy:** the same as option 1.
3. **Shared group with the `channel_id` encrypted only.**
   - **Privacy gain:** the server no longer learns which open channel a
     post is in.
   - **Cost:** the server cannot refuse non-admin posts in announcement
     channels (C2) or apply per-channel retention. Rejected while C2 needs
     server refusal (owner question 1).
4. **One group per channel, joined lazily on first open.**
   - **Cost:** opening a channel needs a member device online to add you.
     You miss posts from before your join epoch (`joined_epoch`), and get
     no notifications from unopened channels. Rejected.
5. **One group, with private channels under sub-keys handed out inside
   it.**
   - **Problem:** it rebuilds MLS member management by hand, without
     forward secrecy or post-compromise security for private channels.
     Rejected.

## Why option 2

- **One group per change instead of C.** In the 1,000-leaf example, 50
  joins a day cost every device about 11 s of CPU and 0.9 MB under option
  1, and 0.4 s and 29 KB under option 2. A cold removal costs about 2.5 MB
  per device under option 1 (30 groups) and 83 KB under option 2.
- **No less privacy than today.**
- **Epoch churn per group is the same as today.** Each open-channel group
  in option 1 already takes every membership change. Option 2 sends them
  as one commit instead of C.

## What would make another option better

- **A busy channel in its own group (option 1, or a split)** wins if
  members want to skip that channel's traffic. In the shared group, one
  sender's ratchet is shared by every open channel:
  - Every device must decrypt all open-channel messages in order, within
    two past epochs (`max_past_epochs(2)`).
  - **Per-channel paging is local only.** It comes from the local
    database, never from server-side fetches of one channel.
  - **Retention gaps.** Per-channel retention deletes leave gaps in a
    sender's generations. A device catching up across a gap of more than
    OpenMLS's maximum forward distance (1,000 generations in one epoch)
    cannot decrypt what follows.

  C8 measures both. If either bites, a channel can move to its own group.
- **Encrypted-only channel ids (option 3)** win if the owner decides the
  server must not learn which open channel a post is in.

## Rules for the builders (C1 to C8)

- **Server model.**
  - One conversation per community of kind `community_shared`.
  - Each channel row gets a `conversation_id`: the shared one for open and
    announcement channels, its own for private channels.
  - Envelopes in `community_shared` must carry the `channel_id` of an open
    channel of that community; the server refuses any other.
- **Per-channel server features** key off `(conversation_id, channel_id)`:
  announcement-post refusal and retention (with the gap caveat above).
  Paging and unread state stay on the device; `joined_epoch` withholding
  stays per group.
- **Membership.**
  - A community join is **one** staged commit in the shared group, plus one
    in each private group the member may see.
  - A leave, kick or ban is the same set of removals.
  - The reconcile coordinator batches the pending adds of one group into
    one commit (`stage_membership_commit` takes many), which keeps the
    shared group's epoch rate down under D28.
- **Role changes.** A change in what a member may see (C4 overrides) adds
  or removes them only in the affected private groups.
- **Moving a channel.**
  - Open to private: the channel moves to a new group, and its old posts
    stay readable through C7's channel history key.
  - Private to open: the old group is closed, and new posts go to the
    shared group.
- **History.** C7 keys history per channel, not per group.
- **Limits.** The D38 member limit (100) applies to the shared group. C8
  raises it in steps, measured with `crypto/rust/tests/c0_join_cost.rs`.

### Keep the tree warm

- **Self-updates.** Each member device commits one self-update after
  joining a group (once it is past the welcome), and again on a timer.
- **Why.** In a 1,000-leaf cold tree, a removal is 83 KB. It falls to 20 KB
  after 10 such updates and to 2.9 KB after 100
  ([evidence](../../testing/evidence/C0-community-groups.md)).
- **Cost.** One extra commit per join. The first few updates in a cold
  tree are as large as a cold removal, so batched joins should stagger
  them.
- **C8's job.** Measure the timer period, and removal bytes and egress at
  each size step.

### C1 waits for a sync change

**C1 open invite links cannot ship until the I33 sync halt changes.**
Sync stops, without advancing its single global cursor, at any message
that cannot be applied or decrypted (`docs/crypto.md`, I33). In an open
community anyone can join and send one bad message, and that stops every
member's sync for every conversation. C1 needs per-conversation halting
(or a quarantine for undecryptable messages) first.

## Migration

There is no release yet, so only demo data exists. **Demo communities are
recreated** in the new layout, rather than keeping today's per-channel
groups as "private channels open to everyone". This keeps one code path
and avoids a permanent special case.

## Open questions for the owner

1. **May the server know which channel a post is in?** It does today.
   Option 2 keeps that, which is what lets the server refuse non-admin
   posts (C2) and apply per-channel retention.
   - Once C4 keeps custom roles inside each group's encrypted state, the
     server can enforce posting rights only for its built-in roles
     (owner, admin, moderator, member), never for custom ones.
   - That weakens the case for a clear `channel_id`, though retention still
     uses it.
2. **Should a busy open channel be able to opt into its own group** now,
   or should that wait for C8's measurement?
