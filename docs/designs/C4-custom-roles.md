# C4: built-in roles, verified by every app

**Status: design, a pure rules engine and the record codec; no wiring, no ABI.** Rescoped
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
- Only the owner moves ownership, and only to a current admin (D80), or an
  election wins it (D81, D82, below). The
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
> question 1.** See "Owner handover (D81)" below.

A commit that removes an account's last device must also carry the pruned
state (`removeAccount`): the account loses its role, its elector flag, its
`joined` entry, and its votes and votes for it. The **owner is never pruned**
(D81): a removed owner stays owner, and nobody inherits. Pruning alone needs
no role, so any committer may carry it; a removal that does not prune is
refused (`notPruned`). An election with nobody from its snapshot left in the
roster is cleared in the same step (nobody could close it, and no new one
could open). `validateCommit` prunes first, then checks any further change
against the pruned state. No commit drops a `joined` entry of a member who
stays. Two things also rewrite the record at
`rev + 1`: an add stamps `joined`, and an owner commit clears an open
election. Neither moves `owner_rev` (below); a bare owner commit (the owner's
self-update, a reconcile, a revocation) carries no record at all. The check
refuses anything else.

`validateCommit` does not judge whether the removal itself was allowed.
That is C1/C5's receiver check (`mayActOn(committer, target)` for a kick). A
leave is committed by another member on the server's word today, so until a
leave is proven by the leaver, a malicious server can force a departure,
and with it a succession.

## Owner handover (D81)

**Status: design revision 2** (after an independent review); the rules
engine implements it (record fields `electors`, `election`, `joined`; the
codec, ABI and wiring are not built). Choices where this text was silent are
in the engine's tests and listed in the C4 package report.

The owner decided (D81): the owner cannot leave without transferring first.
If the owner is inactive for more than a month, the other admins vote, and
more than half must agree. With no admin left, the longest-serving member
becomes owner. Two problems follow: apps cannot prove the owner is absent
(the server can hold the owner's messages back, and can force removals,
crypto.md "Residual"), and a vote must not be fakeable by the server or
stuffable by one admin.

### Approach: challenge, wait, vote, all as commits

Absence is never proven. It is **challenged**: an admin opens an election,
and any commit from the owner afterwards cancels it. This mirrors K0's
recovery (D49, D78): a wait that the real owner can cancel.

| Step | Who | What every app checks (in `validateCommit`) |
|---|---|---|
| 1. Open | An elector in the roster (D82: an admin who was admin by `owner_rev`) | No election is open. The commit writes `election = {opened: rev, electorate: [electors in the roster now], votes: {}}`. The snapshot never grows |
| 2. Wait | Nobody | Nothing: the waits are local rules (below) |
| 3. Owner cancels | Any owner device | Every owner commit while an election is open must clear it (the cancel does not move `owner_rev`, below). The owner's app cancels by itself, after a random delay of up to 24 hours |
| 3b. Close | Any account in the snapshot | Clears the election (fail-safe: nobody gains anything) |
| 4. Vote | An account in the snapshot, in the roster | Has not voted; names an admin in the roster |
| 5. Win | The commit holding the deciding vote | When one candidate has votes from more than half of the **snapshot** (removals never lower this), that same commit must set `owner` to them, set `owner_rev` to its own rev, and clear `election`. The old owner, if still a member, becomes an admin (exempt from the usual hierarchy check for this one commit) |

Votes are **ordinary governance commits**. MLS already proves who sent each
commit (sender credential bound to the envelope, D25) and the server holds
no member's signing key, so a vote cannot be forged. Nothing new is signed,
no signatures are collected, and the ABI pieces above suffice.

### Who may vote: electors

An **elector** is an admin the owner chose: the owner promoted it, or later
confirmed it with an owner commit. A per-admin flag in the record holds
this. Admins promoted by other admins are not electors, and nothing else
(an owner's automatic cancel, D68 reconcile, an Update commit) sets the
flag. Without this, a rogue admin could promote stand-ins and outvote the
others; an automatic cancel would even make them electors. The flag is
cleared when an account stops being admin.

### The owner is never pruned

`owner` may name an account that is no longer in the roster. Being out of
the roster counts as inactivity, nothing more: the same 30 days and vote
apply. This closes two holes: the server forcing the owner out to skip the
wait, and K0 recovery (which revokes old devices before the new one joins)
costing a recovered owner its groups. A recovered owner who is added back
is still the owner. The owner's leave is refused by the app until it
transfers (D81).

Pruning at a removal drops the departed account's admin or moderator role,
its votes and votes for it. Because the threshold comes from the snapshot,
pruning can never decide a win.

### Clocks stay local

The 30 days and the 7 days are **not** in `validateCommit`. Receivers
check only order and roles, so devices with different clocks never disagree
about the group state. An honest app refuses:

- to open an election before it has seen 30 days with no owner activity;
- to vote unless it has seen 7 days since the opening **and** 30 days with
  no owner activity.

Owner activity is any owner commit **or application message** the app has
received in the group, so an owner who chats but rarely commits is not
challenged. A transfer or a win restarts every app's clock.

Receivers cannot refuse a commit for its timing, so **the waits bind honest
committers only**. When most of the snapshot is honest, their apps enforce
the timing: one rogue elector can open early but cannot win. When most of
the snapshot is not (a snapshot of one elector or a claim; a rogue admin's
stand-ins are kept out by `owner_rev`, below), the open, the votes and the
win can follow each other within minutes, and the owner may get no chance to
cancel. An honest app that sees a win its own clock would have refused
should say so to the user.

### No admin left

Only when **no admin is in the roster**: the longest-serving member (the
smallest `joined`, then the smallest account id; never the owner) may open a
claim. After the 7-day wait and 30 days of owner inactivity (local rules)
it commits `owner = itself`. An owner commit cancels the claim. If that
member is also inactive, nobody inherits. `owner_rev` does not gate claims:
an owner who only adds members must not lose its group's claim path (the
reviewed attempt to gate it was dropped, owner decision 2026-11-07).

### New record fields (record codec v2)

`docs/crypto.md`'s v1 record format gains:

- `electors`: the per-admin "owner chose this admin" flag;
- `election`: none, or `{opened, electorate, votes}`;
- `joined`: account to the `rev` at which its first device was added. Every
  add commit writes it (this touches C1's add path); a removal drops it, so
  a re-added member starts again.
- `owner_rev`: the `rev` of the owner's last role decision (genesis 0); see
  below.

One shared function must compute what each kind of commit has to change
(add, remove, owner commit, open, close, vote, win), used by both the
committer and every receiver. Any mismatch is a refused commit and stops
the group's sync under I33.

### Admins but no electors (D82)

If no elector is in the roster when an election opens (the owner never
promoted or confirmed any admin still present), the snapshot holds **every
admin in the roster who was already admin at or before `owner_rev`**
(owner decision D82, narrowed 2026-11-07, below). The rest is unchanged:
same waits, the owner can cancel, more than half of the snapshot must agree.
If admins are in the roster but none was admin by then, nobody can open: the
group keeps its absent owner.

### The owner's last role decision (`owner_rev`, owner decision 2026-11-07)

Receivers cannot check the 30 and 7 days, so a rogue admin could promote
stand-ins under D82 (all admins vote when no elector is present), open an
election, have them vote and win in about five commits. The owner chose
option (b): the record keeps `owner_rev`, a `rev`, and a D82 snapshot may
hold only admins whose `since` is at or before it. Admins promoted after it
never vote. This is deterministic (no clock, no server timestamp), so every
app enforces it. The owner then refined which commits move it: a first
version moved it on every owner commit, but then the owner's own automatic
commits (the forced cancel, an Update, a reconcile) would move it for the
rogue.

- **What moves it.** An owner commit moves `owner_rev` to its own `rev`
  only when the owner itself changes `owner`, `admins`, `moderators`,
  `electors` or a posting field (`adminsOnlyPosting`, announcement
  channels). Pruning, the dead-election clear, an add's `joined` stamp and
  the forced cancel do **not** move it. `requiredRecord` never stamps it.
- **A bare owner commit carries no record.** A self-update, reconcile or
  revocation by the owner needs no record rewrite and is not refused.
- **Only that moves it.** A non-owner commit must keep `owner_rev`, an owner
  commit that decides nothing must keep it, and it can never exceed `rev`.
  Else the rogue would stamp it itself.
- **A win stamps its own rev** (a claim too), so the new owner's tenure
  starts there and every admin of the old one, the old owner included,
  still counts.
- **D82 snapshot** = admins in the roster with `since <= owner_rev`.
  `since == owner_rev` counts (the owner's own promotion). Electors are
  owner-chosen and need no check.
- **Claims are not gated.** The reviewed variant (a claimant must have
  joined by `owner_rev`) is dropped: it would have blocked a claim in any
  group whose owner only adds members.

Closed, each pinned as refused in the engine's tests: stand-ins promoted
after the owner's last role decision cannot open, vote or win, including
after the owner's forced cancel, add or removal; a non-owner cannot move
`owner_rev`, nor can an owner commit that decides nothing.

Cost: an admin promoted by another admin never votes under D82 until the
owner makes a role or posting decision after it. The roles screen should
list admins promoted by others since `owner_rev` and prompt the owner to
flag electors (which closes the D82 path for good).

### Residuals (accepted)

- A server that hides the owner for 37 days or more, while a majority of
  the electors goes along, gets a handover. The server alone cannot do it.
  K0's recovery accepts the same kind of risk.
- A deliberate owner role or posting decision made after a rogue admin's
  promotions (any admin or moderator change, an elector flag, a posting
  switch) makes those stand-ins old enough (pinned in a test). The owner's
  own automatic commits do not. Mitigation: the roles screen lists admins
  promoted by others since `owner_rev` and prompts the owner to flag
  electors; flagging even one admin closes the D82 path altogether.
- Server plus one owner-era admin: until C1 makes a leaver prove its own
  leave, the server can force out every elector (in the opening commit or
  before it), and the one remaining admin who was admin by `owner_rev` is a
  snapshot of one and wins at once (pinned in a test). The same holds for
  a server that forces out every admin and lets the longest-serving member
  claim. A peer admin cannot kick an admin (hierarchy), so only a forced
  removal gets there. C1's removal proofs are a prerequisite for wiring C4
  receivers. `owner_rev` cannot close this: it needs the elector set as of
  `owner_rev`, which changes D82's rule (owner's call).
- A snapshot of one elector, or a claim, has no honest majority to enforce
  the waits: that one account can win at once. An admin who was admin by
  `owner_rev` and is the whole snapshot is the same.
- A rogue elector can keep opening (or closing) elections. Each automatic
  cancel tells the server roughly when the owner was online; the random
  delay blurs this but does not hide it.
- If the electors themselves are inactive, no majority forms; the group
  keeps its absent owner.

## Built and not built

**ABI 20 (2026-11-08): items 1 to 5 above are built, not wired.** The
coordinator assigned ABI 20. Rust: `crypto/rust/src/mls/c4.rs`,
`ffi/c4_calls.rs`; Dart binding: `mobile/lib/crypto/c4_roles.dart`; rules
and formats: `docs/crypto.md`, "Group role state (C4)". The one-shot commit
calls refuse a record proposal, so producers and the two-phase receive path
must be wired together. The wiring check below still holds for C1's removal
proofs.

**Wiring check (2026-11-07, C4 wiring package).** The condition "C1 removal
proofs exist" is **not met**, and the receiver wiring cannot start under ABI
13 either:

- No code or doc builds a removal proof; only this design names one. A leave
  is still committed by another member on the server's word, and a kick is
  judged by nobody.
- ABI 13's commit processing (`CommitOutcome` in `crypto/rust/src/mls.rs`,
  reached through `pm_crypto_group_c7_process_commit`; the plain
  `pm_crypto_group_process_commit` Dart binds returns only a status) returns `removed_any`, `added_any`, `new_epoch`,
  `root` and `removed_self`. It merges inside Rust and gives Dart neither the
  committer, the removed accounts, nor a hook before the merge. The staged
  commit's committer and removed leaves are inside `inspect_commit` only.
- So pieces 1-5 above (capability, genesis, extensions proposal, two-phase
  commit, read call) all need a crypto ABI number. ABI 14 is taken by L1
  (#142). **Needs an ABI counter (15 or later) before receivers can be wired;
  no counter was available to this package.**

Built in this slice instead (no ABI): the record codec v2
(`governance_codec.dart`, vector `testing/vectors/c4-governance-record-v2.json`,
format in `docs/crypto.md`), and the server's half of "Server differences to
close" (migration 0054: one owner per group and per community, ownership only by
the owner's transfer to an admin, anyone may step down). Local schema 22 is **not used**:
the design needs no local table, and the local owner-activity clock has
nothing to read until the record can be read from MLS.

**Sketch only, not reviewed protocol.** Removal proofs, once an ABI exists,
may need no new crypto: a kick is the
committer's own MLS-authenticated commit, judged by `mayActOn(committer,
target)` against the record; a leave is proven by the leaver's own
application message (MLS authenticates its sender) for that group, which
must be a typed message bound to the epoch or it can be replayed (the leaver's
own self-Remove proposal, sent by reference, is the more natural route:
`inspect_commit` already reads `update.sender()` that way), which a
receiver requires for each removed account it cannot attribute to a
permitted committer. That also closes the "server forces out every elector"
residual. It is not built; it needs the committer and removed accounts
before the merge.

Built (earlier): the rules engine and 62 tests (posting, hierarchy as on the server,
step-down, ownership transfer, seniority, pruning, the D81/D82 handover:
open, cancel, close, vote, win, claim, electors, `joined`, `owner_rev`; the
local waits as pure helpers; the commit-level check). Not built: the ABI
above, wiring into commit processing, local storage (none is
needed beyond MLS state), UI, and the server half of the ownership rules
(below).

## Server differences to close

**Closed by migration 0054 (2026-11-07):** a conversation has one owner (a
unique index; extra owners of older groups became admins, the oldest
membership stays owner), `ManageConversationMember` refuses `role = owner`
except as the owner's transfer to a current admin (the old owner becomes an
admin), and anyone may step down (the owner must transfer first). Community
membership rows follow the same rules (a second unique index; the community's
creator is kept when fixing up old data). Review finding: option (a) taken
because the community's role copies into channel conversations. Still open: no succession on the server, and
account deletion of an owner (a follow-up). Apps never read these rows for
roles, so the server and the signed record may still disagree safely.

## Owner questions

1. **No admin left when the owner leaves.** Written default: nobody
   inherits; moderators and the rest keep working, but owner-only acts
   (transfer, demoting admins) are gone for good. Alternative: the oldest
   moderator, then the smallest account id. The default never hands power
   to someone no admin chose.
2. **Moderators making moderators.** Allowed, as on the server today. If
   not wanted, change the server and this rule together.
3. **D82 stand-ins win without a wait: decided (2026-11-07).** The owner
   chose option (b): the record keeps `owner_rev`, the `rev` of the owner's
   last role decision, and the D82 snapshot holds only admins who were admin
   at or before it. Admins promoted after it never vote; an admin promoted
   while the owner was active still does. Refinement the same day: only an
   owner commit that itself changes `owner`, `admins`, `moderators`,
   `electors` or a posting field moves it; the forced cancel, pruning, an
   add and a bare owner commit do not, and claims are not gated. See "The
   owner's last role decision". What stays open is listed in the residuals.

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

## ABI 20 review notes (2026-11-08)

Independent review: the carrier is sound and fails closed. Two things for
the wiring: (1) sealing between stage and merge is now refused by the library;
(2) **committer identity is self-asserted**: a member can add a leaf under
another account's id with its own key, so a committer's role and the rosters
count only for devices the L1 approved-device list approves. Without that, a
member could act as the owner. Producers that carry a record must land with
the two-phase receiver, and the server must stop rate-limiting record-only
commits as self-updates (`mls_group_store.go`), and ABI 19 key packages must
be replenished before adds into record groups.
