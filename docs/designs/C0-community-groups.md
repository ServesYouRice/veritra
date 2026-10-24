# C0: how communities map to MLS groups

**Status: proposed, not yet built.** Decision for C1 to C8. Measurements
are in [`testing/evidence/C0-community-groups.md`](../../testing/evidence/C0-community-groups.md).
Written 2026-10-24 against `main` at `dbce0f2`.

## Decision

**A community has one shared MLS group for all its open channels, plus
one MLS group per private channel.** This is the gap study's layout.

- **The envelope names its channel.** Each message in the shared group
  carries its `channel_id` in clear in the envelope metadata. The same id
  is also inside the encrypted payload. A receiver drops a message whose
  two ids differ (the same pattern as sender binding, D25), so the server
  cannot move a post between channels.
- **Announcement channels are open channels in the shared group.** The
  server refuses a post to an announcement channel from a role that may
  not post there; it knows both the role and the `channel_id`. Members'
  apps drop such a post too (C2).
- **A private channel is its own group** whose members are the devices of
  the accounts allowed to see it (C3, C4).

## What exists today

- `CreateChannelWithConversation` (`server/internal/storage/community_store.go`)
  makes one conversation per channel and copies every community member
  into it.
- `ManageCommunityMember` adds a new member to every channel conversation.
- The app sets up one MLS group per conversation (`_setUpConversationGroup`,
  `_reconcileMlsMembership` in `mobile/lib/core/app_state.dart`).
- So joining a community means one commit and one Welcome per channel, and
  every device processes one commit per channel for every join and leave.
- Channel kinds are `private` and `announcement`. "Private" is only a
  label: every member is in every channel.

## Measured cost

Full tables are in the evidence file. Release build, shared 4-vCPU host;
leaves are devices.

| Leaves | Welcome per join | New device | Each member, per add | Remove commit (cold / warm) |
|---:|---:|---:|---:|---:|
| 100 | 21 KB | 4.8 ms | 0.9 ms | 9.3 KB / 1.6 KB |
| 200 | 42 KB | 9.5 ms | 1.5 ms | 17 KB / 1.6 KB |
| 1000 | 206 KB | 46 ms | 7.3 ms | 83 KB / not run |

- An add commit is 571 bytes at every size.
- Cost per group grows linearly with leaves. The number of groups
  multiplies it.

Two example communities, per join of one device:

| Example community | One group per channel | Shared + private |
|---|---|---|
| 200 leaves; 15 open, 3 private channels | 653 KB, 148 ms on the new device; 15 commits on every device | 69 KB, 16 ms; 1 commit |
| 1000 leaves; 30 open, 5 private | 6.4 MB, 1.4 s; 30 commits (220 ms) on every device | 414 KB, 93 ms; 1 commit (7 ms) |

## Options weighed

1. **One group per channel (today).**
   - **Cost:** every join, leave, kick and role change costs one commit
     per channel. For open channels each of those groups has the same
     members, so they rekey in step and gain nothing in isolation.
   - **Privacy:** the server already learns the channel from the
     conversation id, so this layout hides nothing more.
   - **What it does well:** each channel ratchets on its own. A device can
     leave a channel's traffic unfetched for a while, as long as the
     server keeps that group's commits.
2. **Shared group for open channels + one per private channel
   (chosen).**
   - **Cost:** at the sizes above, one join costs 1/C of option 1 in
     bytes and CPU for the open channels.
   - **Privacy:** the server knows the channel of each post, as in
     option 1.
3. **Shared group with the `channel_id` encrypted only.**
   - **Privacy gain:** the server no longer learns which open channel a
     post is in.
   - **Cost:** it cannot refuse non-admin posts in announcement channels,
     which breaks C2's done-line. It also cannot apply per-channel
     retention or page per-channel history. Rejected while C2 needs
     server refusal. This is the owner's call (question 1).
4. **One group per channel, joined lazily on first open.**
   - **Saving:** it skips the cost of channels never opened.
   - **Cost:** opening a channel needs a member device online to commit
     the add. The device also misses every post from before its join
     epoch (`joined_epoch`), and gets no notifications from unopened
     channels. Rejected.
5. **One group for everything, with private channels under sub-keys
   handed out inside it.**
   - **Problem:** it rebuilds MLS's member management by hand, with no
     forward secrecy or post-compromise security for private channels.
     Rejected.

## Why option 2

- **Joins and leaves cost one group instead of C.** In community L above,
  50 joins a day cost every device about 11 s of CPU and 0.9 MB under
  option 1. Under option 2 they cost 0.4 s and 29 KB.
- **No less privacy than today.** The server already sees channel ids, and
  C3 keeps it seeing ids only.
- **Epoch churn per group is the same as today.** Each open-channel group
  in option 1 already takes every membership change. Option 2 just sends
  those changes as one commit instead of C.
- **Existing groups need no crypto change.** Today's per-channel groups,
  which hold every member, are exactly option 2's private-channel groups
  with "everyone" as the allowed set.

## What would make another option better

- **One group per channel, or a busy channel split into its own group,**
  wins if many members want to skip a busy open channel's traffic.
  - In the shared group every device must fetch and decrypt all
    open-channel messages in order.
  - It must do so before the epoch moves on by more than the two kept
    past epochs (`max_past_epochs(2)`); OpenMLS's default out-of-order
    window also limits how far behind it can fall.
  - If C8 measures that this costs too much, a channel can move to its
    own group, using the same "private channel" machinery with an
    "everyone" allowed set.
- **Encrypted-only channel ids (option 3)** win if the owner decides the
  server must not learn which open channel a post is in. Then C2's
  admin-only posting is enforced only by the apps, not the server.

## Rules for the builders (C1 to C8)

- **Server model.**
  - Add one conversation per community of kind `community_shared`.
  - Each channel row gets a `conversation_id`: the shared one for open
    and announcement channels, its own for private ones.
  - Message envelopes in a `community_shared` conversation must carry a
    `channel_id` of an open channel of that community. The server refuses
    any other.
- **Payload.** The app payload gains `channel_id` in the W7 design, with
  a payload version bump. Receivers compare it with the envelope and drop
  a mismatch. When it lands, it gets an entry in the `docs/crypto.md`
  change log.
- **Per-channel server features** key off `(conversation_id, channel_id)`
  instead of `conversation_id`:
  - retention;
  - history paging (with an index on `channel_id`);
  - announcement-post refusal.

  `joined_epoch` withholding stays per group.
- **Unread state, mute and drafts** stay on the device, keyed by channel.
- **Membership.**
  - A community join is **one** staged commit in the shared group, plus
    one in each private group the member is allowed in.
  - A leave, kick or ban is the same set of removals.
  - The reconcile coordinator should batch the pending adds of one group
    into one commit (`stage_membership_commit` already takes many adds).
    That keeps the shared group's epoch rate down under D28's
    current-epoch-only rule.
- **Role changes.** A role change that changes what a member may see
  (C4 overrides) adds or removes them only in the affected private
  groups. It never touches the shared group.
- **Moving a channel between kinds.**
  - Open to private: the channel moves to a new group. Its old posts stay
    readable through C7's channel history key, not through the shared
    group.
  - Private to open: the channel's group is closed and new posts go to
    the shared group.
- **Keep removals cheap.** Removals right after bulk adds are O(N) (83 KB
  at 1,000 leaves). A device that joins a group with more than about 100
  leaves should commit one self-update soon after joining. That costs
  one more commit per join, and it keeps later removals near 1.6 KB. C8
  should measure this once real communities exist.
- **History.** C7 keys history per channel, not per group, so a channel's
  history key and its rotation on leave do not depend on this layout.
- **Limits.** The D38 member limit (100) applies to the shared group as
  for any conversation. C8 raises it in steps, measured with
  `crypto/rust/tests/c0_join_cost.rs`.

## Migration

There is no release yet, so only demo data exists. A server migration
creates the shared conversation for each community and turns each
existing channel conversation into a private channel whose allowed set is
everyone. No MLS state changes. New open channels go into the shared
group.

## Open questions for the owner

1. **May the server know which channel a post is in?** It does today.
   Option 2 keeps that, and it is what lets the server refuse non-admin
   posts (C2) and apply per-channel retention. Hiding it (option 3)
   moves C2 enforcement into the apps only. Note that once C4 keeps
   custom roles inside each group's encrypted state, the server can
   enforce posting rights only for its own coarse roles (owner, admin,
   moderator, member), never for custom ones. That weakens the case for a clear
   `channel_id`, though retention and history paging still use it.
2. **Should a busy open channel be able to opt into its own group** (see
   above)? Or should that wait for a C8 measurement?
