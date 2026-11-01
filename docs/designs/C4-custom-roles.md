# C4: custom roles, permission switches, channel overrides

**Status: design plus a pure rules engine; no wiring.** Written 2026-11-01
against `main` at `f1b4a36`. Code: `mobile/lib/core/roles/governance.dart`,
tests `mobile/test/governance_test.dart`. Wire record: `docs/crypto.md`,
"Group governance record (C4)". C2, C3 and C5 call
`GovernanceState.can(account, perm, channelId:)` and nothing else.

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

`validateTransition(prev, next, actor)` is deterministic. `rev` is exactly
`prev.rev + 1`; shape and limits hold; role edits need `manage_roles`;
overrides need `manage_channels`; the actor may only touch roles ranked
strictly below its own top rank and may not grant a switch it does not hold;
assignments go only to current members and known roles; a role holder may
drop its own roles without permission. Rejections are stable codes
(`GovernanceReject`).

## Concurrency and ordering

Each record is a full snapshot with `rev`. Two concurrent edits from the
same `prev` both carry `prev.rev + 1`; the one processed first wins, the
other is stale (`badRev`) and its sender rebases and resends. "First" is
sync order. Devices that see different orders could fork (owner question 2,
an MLS ordering choice for second opinion).

## Membership interplay

- A leave, kick or ban leaves stale assignments; the next record by an
  allowed actor prunes them, and `rolesOf` already ignores unknown ids.
- New joiners need the current state. A Welcome carries no application
  data, so a joiner fails closed (member defaults, no admin action honoured)
  until it receives a snapshot. Who sends it is owner question 3.
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

Built: rules engine and 15 tests (evaluation order, hierarchy, no
escalation, stale rev, limits). Not built: the `governance` payload type in
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
