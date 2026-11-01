# C4: built-in roles, verified by every app

**Status: design plus a pure rules engine; no wiring, no ABI.** Rescoped
2026-11-01 after the owner chose built-in roles only (D80). The custom-role
design (switches, ranks, channel overrides) it replaces is in Git history at
`5304eac`. Code: `mobile/lib/core/roles/governance.dart`, tests
`mobile/test/governance_test.dart`. Wire record: `docs/crypto.md`, "Group
role state (C4)". The file name is kept because other designs link to it.

## Decision

The only roles are the server's four: `owner`, `admin`, `moderator`,
`member` (`domain.RoleRank` 4 to 1). The server keeps enforcing them as it
does today. Apps enforce the same roles, without trusting the
server-reported role (D80).

That still needs a **signed role state**, because nothing in today's MLS
data names a role:

- A leaf carries a Basic credential with the account and device id only
  (`inspect_commit`, `crypto/rust/src/mls.rs`). No role.
- The group context has no Veritra extension (only the ratchet-tree
  extension is used), and receivers refuse any proposal other than Add,
  Remove and Update.
- The creator cannot be proven to a joiner: leaf 0 is reused after a
  removal, and a Welcome does not say who created the group.
- No FFI call lists a group's members (`docs/crypto.md`, D68 residual), so
  the app cannot even read the roster MLS holds.

So the C2 receiver drop is **not buildable on today's data**. It needs the
role state below.

## The role state (minimal)

One small record per MLS group. Content (Dart: `GovernanceState`):

- `rev`: +1 on every written change.
- `owner`: one account, or none (see owner question 1).
- `admins`: account to the `rev` at which it became admin. The smallest
  value is the oldest admin.
- `moderators`: accounts. Everyone else is a member.
- `admins_only_posting` (C2 group setting) and `announcement_channels`
  (C2 channel kind, by channel id).

The two posting fields are here because C2's drop has two inputs: the
sender's role and whether posting is restricted. If the restriction came
from the server, a lying server could switch it off and members' posts in
an announcement channel would show. Apps restrict where **either** this
state or the server says so (the server can only narrow). Nothing else is
in the record: C3's "admins restrict info edits" flag and C5's ban list and
timeouts join it only when those packages build them (see their designs);
until then they are trusted to the server, and their designs say so.

## Where it lives: a GroupContext extension

The record is a Veritra GroupContext extension of the group's MLS group.

- Every change is a commit, so MLS orders it (epoch order) and every member
  holds the same state. No `rev` race, no hash chain, no snapshot
  hand-off: the custom-role design's ordering and joiner questions are moot.
- A joiner receives it in its Welcome, with the same trust it gives the
  roster: the group's members accepted it at every step. A joiner cannot
  check history before it joined.
- The creator writes the genesis state (`owner` = creator, nothing else) at
  group creation, so the owner comes from MLS, never from the server.
- In a community (C0) the record lives in the shared group only. A
  private channel's group carries none, and actions there are judged
  against the shared group's record as the device holds it. The two groups
  have no common order, so a post racing a role change can be judged
  differently on two devices (a residual the custom-role review accepted).
- Existing demo groups have no extension. They are recreated, not migrated
  (C0's rule; there is no release). A group without the extension has no
  verified roles: everyone is a member to the app, and posting is
  restricted where the server says so.

ABI work (approved by the owner as "role-state handover", D80; each piece
needs the independent review before it lands):

1. The extension type in every key package's leaf capabilities, then in the
   group's required capabilities at creation. `server/internal/mlswire`
   must accept the capability.
2. Group creation takes the genesis record.
3. A staged commit may carry one GroupContextExtensions proposal holding
   only this extension; `inspect_commit` allows exactly that and nothing
   else new.
4. Incoming commits become two-phase: stage, return to Dart the committer,
   the account roster before and after, and the extension before and after;
   Dart runs `validateCommit`; then merge or discard. Today
   `pm_crypto_group_process_commit` merges inside Rust with no hook.
5. A read of the current extension and account roster (after join, after
   restore).

A commit that `validateCommit` refuses is an invalid MLS control message:
sync stops on it under I33, as for any invalid commit today.

Every commit **producer** changes with it, not only receivers: D68
pending-changes reconcile, revocation removals, device replacement and any
other path that stages a commit. The committer computes the pruned record
for its own commit, adds it as the proposal when it differs, and runs
`validateCommit` on the result before staging. Otherwise the first kick of
an admin or moderator after receivers are wired stops every member's sync,
while the sender merges its own commit once the server accepts it. Wire the
producers before (or with) the receiver check.

## Rules

They mirror the server (`ManageConversationMember`,
`storage/community_store.go`; `CanManageMembers`, `CanPostRestricted`,
`CanModerate`, `domain`), so apps and server agree.

- Changing another account's role needs moderator or above; its current
  role must be strictly below the actor's and the new one at most the
  actor's. So a moderator may make a moderator and an admin an admin, as
  the server allows today.
- Anyone may step down (gains nothing). The owner must transfer first.
- Only the owner moves ownership, and only to a current admin (D80). The
  old owner becomes an admin (seniority restarts) or steps further down.
  Ownership cannot be vacated by a record.
- Posting restrictions need admin or above.
- A new admin's seniority is the record's `rev`; an admin keeps its value
  while it stays admin.
- Everything named must be in the MLS roster after the commit.

Checks for other packages: `mayPost(sender, channelId:)` (C2: owner and
admin only where restricted) and `mayActOn(actor, target)` (C1/C5 kick,
ban, timeout, delete-others: moderator or above, strictly outranking, never
itself). W8 pins, D58 and D59 use the server's cached role today
(`ConversationAuthority.roleOf`, `pinAllowed` in
`mobile/lib/crypto/native_crypto_service.dart`); once the record exists they
switch to `GovernanceState.roleOf`.

### Removal and succession

> **D81 (owner, 2026-11-01) supersedes the succession rule below and owner
> question 1.** The owner cannot leave without transferring first. If the owner
> is inactive for more than a month, the other admins vote and more than half
> must agree; with no admin left, the longest-serving member becomes owner.
> Not yet designed: how apps learn of inactivity without trusting the server,
> and how votes are signed and counted in the group state.

A commit that removes an account's last device must also carry the pruned
state (`removeAccount`): the account loses its role, so a kicked admin who
is invited back is a member. If the owner left, the **oldest admin still in
the group** (smallest `admins` value, then smallest account id) becomes
owner (D80). With no admin left, nobody inherits (owner question 1).
Pruning alone needs no role, so any committer may carry it; a removal that
does not prune is refused (`notPruned`). `validateCommit` prunes first, then
checks any further change against the pruned state.

`validateCommit` does not judge whether the removal itself was allowed.
That is C1/C5's receiver check (`mayActOn(committer, target)` for a kick). A
leave is committed by another member on the server's word today, so until a
leave is proven by the leaver, a malicious server can force a departure,
and with it a succession.

## Built and not built

Built: the rules engine and 21 tests (posting, hierarchy as on the server,
step-down, ownership transfer, seniority, pruning, succession, the
commit-level check). Not built: the ABI above, the record codec (format in
`docs/crypto.md`), wiring into commit processing, local storage (none is
needed beyond MLS state), UI, and the server half of the ownership rules
(below).

## Server differences to close

The server has no single owner: an owner may grant `owner` to anyone it
outranks or equals, and a group may have several. D80 says ownership moves
only to a current admin. Until the server refuses `role = owner` except as
a transfer to an admin, the two can disagree. They disagree safely: apps
act on this state only, so a server-made second owner is an admin or less
to every app. The server also has no self step-down and no succession;
each is a small follow-up in `ManageConversationMember` and in account
deletion.

## Owner questions

1. **No admin left when the owner leaves.** Written default: nobody
   inherits; moderators and the rest keep working, but owner-only acts
   (transfer, demoting admins) are gone for good. Alternative: the oldest
   moderator, then the smallest account id. The default never hands power
   to someone no admin chose.
2. **Moderators making moderators.** Allowed, as on the server today. If
   not wanted, change the server and this rule together.

## History

The custom-role design (`9f059b7`) and its review (`bef742c`, `77968d4`)
are superseded. What still applies, carried into the rules above: no
escalation by taking a role, pruning departed accounts so governance never
freezes and a kicked admin returns as a member, the roster from MLS and
never the server, no server metadata (channel lists) as an input, and
deterministic succession. What went: switches, custom ranks, channel
overrides, limits, the effective-switch check, `rev` races and `prev_hash`,
and the snapshot hand-off. Owner decisions (2026-11-01, D80): built-in roles
only; new crypto ABI functions approved with independent review; ownership
only to current admins, oldest admin inherits.
