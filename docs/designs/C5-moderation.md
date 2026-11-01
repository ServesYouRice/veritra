# C5: moderation

**Status: proposed.** Written against `main` at `f1b4a36`. Builds on C0
(shared group, `channel_id`), C1 (membership), C4 (roles, design on
`agent/C4`) and C6 (sealed reports, design on `agent/C6`). Needs Opus review
before the server parts land. Revision 2 (2026-11-01) adds escalation to the
instance owner and the instance ban (owner decision below).

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

## Escalation to the instance owner

Bans stay per community (owner decision). A community admin who thinks an
account should leave the whole instance escalates it; only the instance
owner (`accounts.role = 'owner'`, rank 4) decides. The server routes and
records; it never reads the reason or the evidence.

### 1. Raising it (community admin's app)

- Offered to an account whose server-visible role in the community is
  `owner` or `admin` and who holds C4 `ban`, on a target that is a current
  member or is in `member_bans` for that community. Escalating does not
  require a community ban first.
- The app builds a sealed body, versioned JSON:
  `community_name` (the owner cannot read C3 names), `reason` (at most 2,000
  characters), `community_action` (`none`, `kicked`, `banned`), and up to 20
  C6 reveal tuples `(conversation_id, envelope_id, action_id, P, kf)` taken from reports
  the admin received or from messages its own device holds (every recipient
  stores `kf`, C6 step 2).
- Sealed with C6 transport A (the same HPKE seal call in the Rust ABI) to
  the C6 report key of **each** current instance owner, one copy per owner.
  Info `"veritra-c5-escalation-v1"`; AAD
  `lp(escalation_id) | lp(community_id) | lp(target_account_id) | lp(raised_by)`,
  so a body cannot be moved to another escalation. `escalation_id` is a
  random UUID made by the app.
- `POST /api/v1/communities/{id}/escalations` with
  `{escalation_id, target_account_id, envelope_ids[], sealed: {owner_account_id: bytes}}`.

### 2. Server intake

One transaction: check the caller's built-in community role (`owner` or
`admin`), the target as above, the target is not an instance owner and not
the caller, every `envelope_id` belongs to a conversation of this community,
each sealed copy is at most 256 KiB, and limits (10 open per community, 20 a
day per community, plus `admission`). Store the row with status `open`; pin
the named envelope rows' metadata (`frank_commit`, sender account and
device, conversation, `created_at`) until resolution plus 30 days, so C6
verification still works after acks (C6 open item 2). Write the audit rows
(section 5). Push to the owners' devices is generic (D53), no names.

### 3. What the owner sees

In the B9 admin screen, an Escalations list. From the server, in the clear:
escalation id, community id, target username and account status, raising
admin's username, time, status, number of attached messages. On the owner's
device, after opening its sealed copy: community name, reason, and each
attached message with a "verified" / "not verified" label (C6 step 6).

For that check the owner, who is not a member, reads
`GET /api/v1/admin/escalations/{id}/evidence`: for each envelope named in
that escalation only, `conversation_id`, sender account and device,
`created_at` and `frank_commit` (every `ctx` input of C6 step 3 the server
records). `action_id` is not stored on the server today, so it travels in
the reveal tuple unless C6 adds it to the envelope; C6 settles which. Never ciphertext, never other envelopes,
never membership lists. The owner sees exactly the messages the admin chose
to reveal and nothing else.

### 4. Owner actions and the instance ban

`POST /api/v1/admin/escalations/{id}/resolve` with `dismiss` or
`instance_ban`; an instance ban may also be issued from the account list
(`POST /api/v1/admin/accounts/{id}/ban`) and lifted with `DELETE` on the
same path. Owner only (instance admins are refused, owner question 1). The
owner cannot ban itself or another owner.

The ban is a new account status `banned` plus a row in
`instance_bans(account_id, banned_by, escalation_id, created_at)`. Every
sign-in, session, recovery and membership query already tests
`status = 'active'` (`identity_store.go`, `account_recovery_store.go`,
`content_store.go`, `admin_store.go`), and `accounts.status` has no CHECK
constraint (`migrations/0001_init.sql`), so the new value is refused
everywhere by default; no Go path compares against `"suspended"` except the
suspend route itself. `SetAccountStatus` (`storage/admin_store.go`) today
lets an instance admin set any lower-ranked account to `active`; it must
refuse a target whose status is `banned` (409 `account_banned`), so only the
owner's ban route lifts a ban and a suspend cannot downgrade one. The B9 app
reads `suspended` as `status == 'suspended'` (`mobile/lib/core/admin_models.dart`),
so it must learn the `banned` value and hide the suspend toggle for it.

One transaction, in this order (more than today's suspend):

1. Status `banned`, `instance_bans` row, escalation resolved.
2. Delete sessions and disable push subscriptions (as suspension does).
3. Revoke unredeemed invites the account created.
4. Cancel its pending K0 recovery claims and device-link sessions, and
   retire its history transfers as `DeleteAccountData` does
   (`retireHistoryForLinks`). The status check already refuses new ones.
5. Revoke every device and queue its removal from every MLS group with
   `queueMLSRevocations` and `releaseMLSRevocationConfirmations`, exactly as
   `DeleteAccountData` does (`storage/account_store.go`); then drop the
   account's memberships. Key-package claims for its devices are refused
   from then on (revoked devices).
6. Audit rows (section 5). After commit, disconnect its realtime sessions.

Ciphertext the account sent stays in other members' history; nothing is
decrypted or deleted. Lifting the ban sets `active` and deletes the row;
devices stay revoked and memberships are not restored, so the person signs
in again only through K0 recovery (password and recovery key) and must be
re-invited to each conversation.

### 5. Audit entries (ids and kinds only)

| Log | Entry | Actor | Metadata |
|---|---|---|---|
| B9 `audit_events` | `escalation.created` | raising admin | escalation, community, target, evidence count |
| B9 `audit_events` | `escalation.dismissed` / `escalation.expired` | owner / system | escalation |
| B9 `audit_events` | `account.banned` | owner | target, escalation (if any) |
| B9 `audit_events` | `account.unbanned` | owner | target |
| C5 `moderation_events` | `escalate` | raising admin | target (raising community only) |
| C5 `moderation_events` | `escalation_dismissed` / `instance_ban` | owner | target (raising community; `instance_ban` also in every community the target was in) |

Never in any log: the reason, the sealed body, the envelope ids, or message
text. The raising admins see the status (`open`, `dismissed`, `banned`,
`expired`) through their community, not the owner's notes.

### 6. Keeping to the no-plaintext rules

- The server stores the sealed body as opaque bytes, never logs it, and
  holds no key that opens it. It learns what it already knows: account and
  community ids, which envelopes were named, and times.
- The owner gets plaintext only for messages a member or admin chose to
  reveal (the C6 reporting act), proven by franking, not by any server
  read of message content. No admin route returns ciphertext or keys.
- An open escalation expires after 90 days; the sealed copies and the
  evidence pins are deleted 30 days after the escalation closes.
- Limit: a banned person can join again with a new account through a fresh
  invite. The ban revokes their own invites; nothing else ties a person to
  an account.

## Draft schema (do not number yet)

Parallel packages also add migrations, so the migration number is assigned at
merge. Tables: `member_bans`, `moderation_events`, `moderation_escalations`
(`id, community_id, target_account_id, raised_by, status, created_at,
resolved_by, resolved_at`), `escalation_sealed(escalation_id,
owner_account_id, body)`, `escalation_evidence(escalation_id, envelope_id)`
(pins the envelope's metadata), `instance_bans`; columns
`memberships.timeout_until`, `channels.slow_mode_seconds`,
`communities.invites_paused_until`; the account status value `banned`.
Migrations are a second-opinion area.

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
3. Slow mode clock: server time is authoritative; is drop-on-receipt in apps
   needed, or is server refusal enough?
4. Instance-ban scope. Proposed: the account loses the whole instance
   (sign-in, DMs, groups, communities). Alternative: barred from every
   community but keeps DMs and groups (then it is not a status, but a check
   on community joins and invites).
5. Who handles escalations: the instance owner only (proposed), or instance
   admins too (each needs a C6 report key, and the body is sealed to each)?
6. Lifting a ban leaves devices revoked, so the person returns only through
   K0 recovery and re-invites. Accept, or keep devices and only suspend?
7. Retention: escalations expire after 90 days open; sealed copies and
   evidence pins are kept 30 days after closing. Accept these numbers?
8. Should the owner be able to send a short sealed reply to the raising
   admins (proposed: no, status only)?

Answered: per-community bans (was question 3).

Depends on C6 for the owner's report key and the HPKE seal call (a crypto ABI
change), and on C6 open item 2 for the evidence pins.

## Owner decisions (2026-11-01)

- Bans are per community. Admins can escalate to the instance owner, who may issue an instance-wide ban (needs a design for the escalation path).
- No interim trust in the server-reported role: app-side drops wait for C4's signed roles.
