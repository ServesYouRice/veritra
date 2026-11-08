# C2: admin-only posting

## Rule
Posting is restricted in (a) community channels of kind `announcement`, and
(b) groups whose `conversations.posting_policy = 'admins'`. Only roles for
which `domain.CanPostRestricted` holds (owner, admin) may post there.
Moderators and members may not.

## Server (built)
- C7's ask (channel-less envelopes exempt from the refusal) is **not done**:
  it concerns private-channel groups and needs C0's change so their posts
  carry `channel_id`. Done alone it would let any member post into a legacy
  announcement-channel conversation by leaving `channel_id` out. Left for
  C0 and C7. In the shared group no such envelope exists yet (the route
  check refuses a post without a channel).
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

## Apps (built as a seam; drops nothing until C4 can read the record)

Built (2026-11-07): `mobile/lib/core/roles/posting_verdict.dart`.
`shouldDropRestrictedPost` is the whole rule, and the receive path in
`NativeCryptoService` calls it for text, reply, attachment and poll payloads
when its `ConversationAuthority` also implements `VerifiedRoleSource`
(`governanceOf`, `serverRestrictsPosting`). **No build implements that
interface yet**, so no post is dropped: the source is C4's record read from
the group's MLS extension, which needs a crypto ABI number C4 does not have.
Rules pinned in `test/posting_verdict_test.dart`: no record means no drop (a
group without the record reads everyone as a member, and dropping would hide
real admins' announcements); the server can only narrow; dropped post leaves a hidden action row (so the timeline hides the server's copy), no notice; the MLS state and cursor still
commit. The composer is not hidden yet (the local account's role needs the
same record).

The text below is the original design and what remains.
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
