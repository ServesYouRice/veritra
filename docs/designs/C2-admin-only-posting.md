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

## Apps (not built)
Receivers must drop restricted-conversation messages whose sender is not
owner/admin, because the server is not trusted for roles. This needs a
sender role the app can verify, which comes from the encrypted per-group
state (C4 roles / C1 membership). Until then the app can only trust the
server-reported role, which gives no protection against a malicious server.
The composer should also be hidden when `posting_restricted` and the local
role is not owner/admin.

## Owner questions
1. Should moderators post in announcement channels (currently no)?
2. Is the server-reported role acceptable as an interim receiver check, or
   must the drop wait for signed roles (C4)?
