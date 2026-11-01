# C2: admin-only posting

## Rule
Posting is restricted in (a) community channels of kind `announcement`, and
(b) groups whose `conversations.posting_policy = 'admins'`. Only roles for
which `domain.CanPostRestricted` holds (owner, admin) may post there.
Moderators and members may not.

## Server (built)
- Migration 0046 adds `conversations.posting_policy` (`everyone` default,
  `admins`). Announcement restriction is derived from `channels.kind` at send
  time, so no backfill.
- `saveMessageEnvelope` refuses with `ErrPostingRestricted` (HTTP 403,
  `posting_restricted`) after the idempotent replay check, so a retry of an
  already stored post still answers.
- `PUT|PATCH /v1/conversations/{id}/posting-policy {"policy": "everyone"|"admins"}`:
  owner/admin of a `group` only; emits sync event
  `conversation.posting_policy.updated` and an audit record.
- `Conversation.posting_restricted` is returned on list and by-id reads.

## Apps (not built: blocked on the C4 role state)
Rule: a receiver drops a post (text, reply, attachment) when posting is
restricted there and `GovernanceState.mayPost(sender, channelId:)` is false
(`mobile/lib/core/roles/governance.dart`, tested). Posting is restricted
where the C4 record **or** the server (`posting_restricted`) says so; the
server can only narrow. The composer is hidden on the same test for the
local account.

Why it is not wired (checked 2026-11-01): receivers cannot verify a role
from today's MLS data. Leaves carry account and device ids only, the group
context has no Veritra extension, the creator cannot be proven to a
joiner, and no FFI call lists the roster. The owner ruled out trusting the
server-reported role meanwhile (D80). Missing, all in C4: the role-state
GroupContext extension and its ABI (genesis at creation, a proposal in
staged commits, two-phase incoming commits checked by `validateCommit`, a
read of the record and roster), then the codec. The restriction itself
(`admins_only_posting`, announcement channels) is in that record too, so a
lying server cannot switch it off. Changing the setting then means the
server route plus a commit carrying the new record.

## Owner questions
1. Should moderators post in announcement channels (currently no)?

Answered (D80): no interim trust in the server-reported role; the drop
waits for C4's signed role state (was question 2).
