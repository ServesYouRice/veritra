# C4: custom roles, permission switches, channel overrides

**Status: design plus a pure rules engine; no wiring.** Written 2026-11-01
against `main` at `f1b4a36`. Code: `mobile/lib/core/roles/governance.dart`,
tests `mobile/test/governance_test.dart`. Wire record: `docs/crypto.md`,
"Group governance record (C4)". C2, C3 and C5 call
`GovernanceState.can(account, perm, channelId:)`, and `mayActOn` for
actions on another account; membership wiring calls `removeAccount` at a
removing commit.

## Decision

A group's roles live in one **governance state**, carried as MLS
application messages inside that group. The server never sees it, so it can
enforce only the built-in `owner/admin/moderator/member` roles it already
knows (owner question 1). Every device holds the state locally, applies
each record through `validateTransition`, and checks every action with `can`.

## Model

- **Owner**: one account, the creator. Holds every switch, ignores
  overrides, cannot be touched by anyone. Only the owner changes `owner`.
- **Role**: `id` (`[a-z0-9_]{1,32}`), `name` (at most 32 UTF-16 units),
  unique `rank` (lower is stronger; 0..1000), a set of switches. At most 32.
- **`member`**: always present, rank 1000, held by everyone implicitly.
  Genesis gives it the open defaults of D58/D59 (view, post, react, attach,
  pin, edit group info). `admin` (rank 10, `administrator`) and `moderator`
  (rank 20) exist at genesis as ordinary editable roles.
- **Assignment**: account to extra role ids (never `member`, never the
  owner). Effective rank is the lowest held.
- **Override**: `(channel, role-or-account)` to `allow` and `deny` sets of
  channel-scoped switches; at most 256.
- **Switches** (unknown strings are kept, never given meaning):
  group-wide `administrator, manage_channels, manage_roles, manage_members,
  kick, ban, timeout, edit_group_info, view_audit_log, manage_invites`;
  per-channel `view_channel, post, react, attach, mention_all, pin,
  manage_messages`.
- **Evaluation** (Discord order): union of role switches; `member` override;
  union of the other role overrides (denies, then allows); the account's own
  override. Owner and `administrator` skip overrides. Without
  `view_channel` no channel-scoped switch is granted.

## Who may change what

`validateTransition(prev, next, actor, members:)` is deterministic when
`members` is the MLS roster at the record's sync position. `rev` is exactly
`prev.rev + 1`; shape and limits hold; role edits need `manage_roles`;
overrides need `manage_channels`; the actor may only touch roles and
accounts (itself included, for overrides) ranked strictly below its own top
rank and may not grant a switch it does not hold, checked on effective
switches in every scope; assignments go only to current members and known
roles; a role holder may drop its own roles without permission if that
gains it nothing. Rejections are stable codes (`GovernanceReject`).

## Concurrency and ordering

Each record is a full snapshot with `rev`. Two concurrent edits from the
same `prev` both carry `prev.rev + 1`; the one processed first wins, the
other is stale (`badRev`) and its sender rebases and resends. "First" is
sync order. Devices that see different orders could fork (owner question 2,
an MLS ordering choice for second opinion).

## Membership interplay

- A leave, kick or ban: every device applies `removeAccount` at the
  removing commit (see Review, finding 3). `rolesOf` ignores unknown ids.
- New joiners need the current state. A Welcome carries no application
  data, so a joiner holds governed effects until it has a verified state
  (Review, finding 5). Who sends it is owner question 3.
- Private channels (C3) use `can(a, view_channel, channelId:)` to decide who
  is in that channel's MLS group; C0's reconcile applies the diff.

## What other packages do

- **C2**: post allowed iff `can(sender, post, channelId:)`; an announcement
  channel denies `post` to `member` by an override.
- **C5**: `kick/ban/timeout/manage_messages`; admin delete uses
  `manage_messages`. The audit log is C5's.
- **W8 pins, D58, D59**: replace `ConversationAuthority.roleOf` with
  `can(..., Perm.pin)` and `Perm.editGroupInfo`.

## Built and not built

Built: rules engine and 24 tests (evaluation order, hierarchy, no
escalation, stale rev, limits, and the review's regressions). Not built: the `governance` payload type in
the W7 registry (specified in crypto.md only), local storage (a schema bump,
second-opinion area), snapshot hand-off, UI, server enforcement for
built-in roles.

## Owner questions

1. Server refusal of posts (C2) works only for built-in roles. Accept that
   custom-role limits are enforced by members' apps only?
2. Concurrent records: sync order only, or bind each record to its MLS epoch
   and drop it on a mismatch?
3. Snapshot hand-off to joiners: admin resend on join, or an MLS
   GroupContextExtension (needs a crypto ABI change)?
4. May ownership move only to a current admin?

## Review (2026-11-01)

Independent review of `9f059b7` (design, crypto.md record, engine, tests).
Fixes are on `agent/C4-review`; `flutter test test/governance_test.dart`
(24 pass) and `dart analyze` (no issues) were run on Windows.

### Findings fixed in the engine

1. **Escalation by dropping your own role** (high). The self-drop exemption
   skipped every check, so a member holding a "muted" role that carries a
   channel `deny post` could drop it and post again. **Escalation by taking
   a role** (medium): a `manage_roles` holder could assign itself (or
   others) a role carrying a channel `allow` it lacked, because only the
   role's group switches were compared. Fix: a final check on effective
   switches. For every member and every scope (group-wide plus each channel
   named in an override), any switch gained must already be held by the
   actor in that scope; the actor can never gain one. Owner and
   administrators are exempt (they hold everything).
2. **Self-targeted account overrides** (medium). A `manage_channels`
   holder could write an `allow` for its own account; account overrides
   apply last, so it would outlive a later restriction of its roles. Now
   refused (`hierarchy`), the same rule as for peers.
3. **Governance froze when an account left** (high, liveness). Every
   record had to name only current members, but pruning a departed
   account's entry needed rank over it: after an admin left only the owner
   could write records, and after the owner left nobody ever could. Simply
   tolerating stale entries would give a kicked admin its role back on
   rejoin. Fix: `removeAccount`, applied by every device at the removing
   commit's place in sync order (deterministic, no record, `rev` kept); it
   drops the account's assignments and own overrides and, for the owner,
   passes ownership to the strongest remaining account.
4. **Inputs that devices see differently** (high, fork). `channelIds` came
   from server metadata, so a device that had not fetched a new channel
   refused a record others accepted; their `rev`s then diverge for good. It
   is removed: an override for an unknown channel is kept and inert.
   `members` must be the MLS roster at the record's place in sync order.
   Unknown switches in overrides were `badShape`, so an older app refused
   a newer app's record (a version fork); now only known group-wide
   switches are refused.
5. Added `mayActOn(actor, target, perm)` for C1/C5 (holds the switch and
   strictly outranks the target).

### Findings for the wiring (not code yet)

- **Joiners failed open.** "Member defaults" include `post`, `pin` and
  `edit_group_info`, so a joiner without the state would accept a member's
  post in an announcement channel (C2) or a rename in a restricted group.
  A device without a verified state holds governed effects instead.
- **Own records** apply at their sync position, not at send; otherwise a
  sender whose record loses a race keeps a state no one else has.
- **Genesis** is protocol: freeze its roles, ranks and switches in
  crypto.md. The genesis owner must come from MLS (the group's creator),
  never the server roster, or the server names the owner.
- **Where the record lives (C0).** In a community, only in the shared
  group; private-channel groups carry none. A post in a private group is
  judged against the shared group's state at receipt; the two groups have
  no common order, so a post racing a role change can be judged
  differently on two devices. Accepted residual, as for S4 today.
- **C1/C3/C5 receivers** must check MLS remove commits with
  `mayActOn(committer, target, kick)` and private-group adds with
  `can(added, view_channel, channelId:)`, or the hierarchy means nothing.
- Deleting a role that has overrides also needs `manage_channels`.
- An `allow` on a lower role the actor also holds still outlives later
  restrictions (as in Discord); a stronger account sees and can remove it.
- The effective-switch check costs members x scopes evaluations (up to
  1,000 x 257 at C8 sizes). C8 should measure it, or limit it to the
  accounts a record can affect.

### Owner questions: recommendations

1. **Custom roles enforced by apps only: accept.** The server stays a
   coarse outer layer on its built-in roles, and apps apply server AND
   governance, never widening what the server allows. So a custom role
   cannot post in a channel the server marks announcement; such a channel
   should be client-enforced only. There is a split brain to decide: the
   server alone authorizes membership and invites (`CanManageMembers`,
   `CanManageInvites`) and allows several owners, while governance has one.
   Recommended: the app mirrors governance to the server's built-in role
   (`administrator` to admin, `kick`/`ban`/`manage_members` to moderator)
   and a server owner always equals the governance owner. That tells the
   server who holds power, as it knows today.
2. **Ordering: sync order plus a hash chain, not epoch drop.** Sync order
   is the server's per-conversation order, the same for every device, and
   is already the rule for pins and polls. `rev` alone cannot detect a fork
   (a record skipped under D54, or withheld by a hostile server): add
   `prev_hash`, the SHA-256 of the canonical state the record builds on. A
   mismatch stops governance on that device and asks for a resync; it never
   guesses. Dropping records whose epoch differs from the current one would
   discard good records whenever a join or self-update commit races them,
   and still cannot order two records in one epoch. This is moot if 3 picks
   the extension.
3. **Joiner hand-off: a GroupContext extension (recommended), needing a
   crypto ABI change and an Opus design.** An admin resend cannot be
   verified by the joiner: a forged snapshot can name its own sender as
   owner. Putting the state in a GroupContext extension makes every change a
   commit, so MLS itself orders it (epoch order, no hash chain), all members
   agree on it, and the Welcome carries it, which also fixes genesis.
   Costs: the extension type must be in every member's capabilities first;
   an invalid governance commit halts receivers under I33, the same class
   as any invalid commit today; size is tens of KB at 1,000 members, within
   D70's 4 MiB per value. If size bites at C8, keep only `(rev, hash)` in
   the extension and send the snapshot as an application message any member
   can deliver. Without an ABI change, the fallback is admin resend plus
   the hash chain, with joiners holding governed effects until a snapshot
   arrives from the member that committed their Add.
4. **Ownership transfer: to any current member in the protocol; restrict
   in the UI** (for example to admins, with a confirmation), so the policy
   can change without a protocol change. The server owner must move with
   it, and no server transfer exists today. The automatic succession in
   `removeAccount` (strongest remaining account, then smallest id) is also
   the owner's to confirm. One case to weigh: only the owner can create a
   role ranked 0 to 9; a cosmetic role there ("VIP" with just `post`)
   outranks every admin, so its holder would inherit. "Administrators
   first, then rank, then id" may be the better default.
