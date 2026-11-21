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

## Apps (built; effective since C4's app wiring, verified 2026-11-21)

`mobile/lib/core/roles/posting_verdict.dart`: `shouldDropRestrictedPost` is
the whole rule. The receive path in `NativeCryptoService` calls it for text,
reply, attachment and poll payloads, live and in a C7 newcomer's import.
`AppState` is the `VerifiedRoleSource`: `governanceOf` reads the C4 record
from the group's own MLS state (a community channel: its shared group's),
and `serverRestrictsPosting` is the server's `posting_restricted` or an
announcement channel. Groups and shared groups carry the record from
creation (C4 genesis), and the posting switch and a new announcement
channel are role commits (`AppState.setPostingPolicy`,
`_recordAnnouncementChannel`), so a server that later reports posting as
open cannot let a member's post through. The composer is hidden by the
same test (`AppState.mayPost`).

Rules (pinned in `test/posting_verdict_test.dart`): no record means no drop
(a group without the record reads everyone as a member); the server can only
narrow; a dropped post leaves a hidden action row (the timeline hides the
server's copy, and an `edit` only ever changes a text row, so the author
cannot bring it back); the MLS state and cursor still commit; a leaf its
account's L1 list removed posts as a member (owner decision B).

End to end (`test/c2_admin_only_posting_native_test.dart`, real OpenMLS
devices and a real record): after the owner's role commit, a member's and a
moderator's post and reply are dropped by every other device (a second
device of the owner included) while the server says posting is open; the
member's edit of its dropped post shows nothing; the owner's post shows; a
member the record makes admin posts and is shown; in a community's shared
group a member's post to an announcement channel is dropped and the same
member's post to an open channel is shown.

Residuals: a post is judged by the record this device holds when it arrives,
not the one at the post's epoch (a post racing a demotion can be judged
differently on two devices; C4 accepted this).

Record write retry (2026-11-21, `mobile/lib/core/app_state_posting.dart`):
the record commit after the server switch (or after creating an
announcement channel) can fail (offline, another commit pending). The
device keeps what it meant to write in a local setting
(`c2.posting_record.<conv>`, `c2.announce_record.<shared conv>`) and tries
again on each sync pass until the record says so. The server's word only
stops a retry (another admin changed the setting since, or the channel is no
longer listed as an announcement channel, judged only once that
community's channel list has loaded); it never writes the record. The
entry is also dropped when the group has no record or this account is no
longer an admin under it. Pinned in `test/c2_posting_record_retry_test.dart`
(each guard fails a test when removed). Until the retry lands, the setting
holds only on the server, which can narrow but can later report it open.

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
