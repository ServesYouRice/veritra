# C5: moderation

**Status: proposed.** Written against `main` at `f1b4a36`. Builds on C0
(shared group, `channel_id`), C1 (membership) and C4 (roles, not yet
designed). Needs Opus review before the server parts land.

## Built now

`server/internal/domain/moderation.go`: pure rules over the built-in roles
(`CanModerate`, `CanDeleteOthersMessage`, timeout and slow-mode bounds and
checks), with tests. When C4 lands, the role arguments become permission
checks; the call sites stay.

Already exists: kick/leave of a group member (`RemoveConversationMember`,
rank-checked, queues the MLS removal). C1 extends it to communities.

## Design

Principle: the server enforces what it can see (account ids, times,
`channel_id`); every app enforces the same rules from the encrypted state
(C4), because the server may lie. No reasons or message text reach the
server.

| Action | Server | Apps (encrypted) |
|---|---|---|
| Kick | Remove membership, queue MLS removal (exists) | Commit removing the member's devices |
| Ban | Row in `member_bans(community_id, account_id, banned_by, created_at)`; refuses add, join, invite redemption and key-package claims for that account | Ban list in group state (C4); a banned account's Add proposal is rejected |
| Timeout | `timeout_until` on the membership; send refused until then (`TimedOut`) | Drop posts from a timed-out sender inside the period |
| Slow mode | `slow_mode_seconds` per channel; refuse a post within the gap of the sender's last one in `(conversation_id, channel_id)`; moderators exempt | Same check on receipt, with a small clock tolerance |
| Delete others' messages | Redact the envelope like `deleteMessageEnvelope`, when the actor outranks the sender | Moderator sends a `moderation_delete` application message naming the target message; receivers verify the actor's authority before hiding it |
| Audit log | Table `moderation_events(id, community_id, actor, target, action, created_at)`: ids and action kind only | Optional reason, encrypted as an application message to moderators |
| Pause invites | `invites_paused_until` on the community; refuses redemption (C1) | Shown in the UI |

Rules:
- Rank check on every action: actor outranks target, never self.
- Timeout max 28 days, slow mode max 6 hours; both bounded so a bad
  setting expires.
- A ban removes the member first (one MLS removal), then records the ban, in
  one server transaction.
- Unban deletes the row; it does not re-add.
- The audit log is append-only and visible to admins and above.

## Draft schema (do not number yet)

Parallel packages also add migrations, so the migration number is assigned at
merge. Tables: `member_bans`, `moderation_events`, columns
`memberships.timeout_until`, `channels.slow_mode_seconds`,
`communities.invites_paused_until`. Migrations are a second-opinion area.

## Protocol (for `docs/crypto.md` once approved)

New W7 payload types `moderation_delete` (target message id) and
`moderation_audit` (action, target, optional reason). Not added to
`docs/crypto.md` here: that file is shared and the W7 section is owned by W7.

## Not built, and why

- Server tables, handlers and the app UI: need C1 (communities membership),
  C4 (roles) and a migration number.
- Moderator delete on the server: the tombstone marker is today produced by
  the sender; a moderator marker needs the receive-side authority check.

## Owner questions

1. Is the server's refusal of timeout, ban and slow mode acceptable given it
   cannot see custom roles (C4)? Proposal: server enforces built-in roles
   only; apps enforce the rest.
2. May the server keep an audit log of ids and action kinds (it sees them
   anyway), or must the log be encrypted-only and stored in group state?
3. Should a ban follow the account across communities of one instance? Proposal:
   no, per community.
4. Slow mode clock: server time is authoritative; is drop-on-receipt in apps
   needed, or is server refusal enough?

## Owner decisions (2026-11-01)

- Bans are per community. Admins can escalate to the instance owner, who may issue an instance-wide ban (needs a design for the escalation path).
- No interim trust in the server-reported role: app-side drops wait for C4's signed roles.
