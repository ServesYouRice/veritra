# C1 progress and open choices

Status 2026-11-01 (agent/C1). C1 is **not** done. Read with
[C1-membership-plan](C1-membership-plan.md) and
[C1-sync-isolation](C1-sync-isolation.md).

## Built (server only, inactive)

`server/internal/storage/scoped_sync_store.go`: `ListAccountSyncEvents` and
`ListConversationSyncEvents`, read-only, no route and no client use. They
reuse `syncEventVisibleTo`, so visibility matches the legacy stream. Tests
(`scoped_sync_store_test.go`) show the account stream plus the conversation
stream equal the legacy stream for the blocker, blocked sender and
bystander, including a Welcome-like event; outsiders get `ErrForbidden`;
pruning one conversation expires only that conversation's cursor.

## Built: scoped routes behind a switch (server only, default off)

`GET /api/v1/sync/account-events` and `GET /api/v1/conversations/{id}/sync-events`
(`httpapi/scoped_sync_handlers.go`). Served only with
`PRIVATE_MESSENGER_SCOPED_SYNC` (on by default since 2026-11-07; `0` or
`false` turns it off, then they are not registered and answer 404).
Envelope: `scope`, `scope_id`, `events`, `sync_epoch`, `oldest_event_id`,
`latest_event_id`. A scope behind its retention gets 409 with the same
envelope minus `events`: `device_recovery_required` for the account scope
(device-wide, as the design keeps it), `conversation_recovery_required` for a
conversation scope (pauses only that conversation; a client must never relink
the device over it). Non-members and unknown conversations both get 403.
Bounds are the account's, as in the legacy stream: a scoped client must not
read them as one scope's progress, floor or "caught up" mark (per-scope
bounds would need a new store query and review). Delivery receipts
are recorded as in the legacy route. Handler tests: auth, outsider 403,
envelope, switch off, and account + conversation equal to the legacy stream.
No client uses the routes; no migration.

## Design finding: no new retention-floor table

The sync-isolation design proposes `sync_retention_floors`. Migration 0044
already keeps per-account and per-conversation prune marks, and the scoped
expiry check reads those. A new table and migration are not needed for the
server slice. Limit: account marks do not record the conversation of a
pruned Welcome, so a conversation stream is also expired by any pruned
account event after its cursor. That errs towards pausing, never towards a
silent gap. Splitting account marks by conversation would need a migration.

## Not built, and why

- Client scoped cursors, recovery table, `ScopedMlsTransition`, native
  changes: they touch `app_state.dart`, `local_store.dart` and the local
  schema, owned by W8/K2/coordinator, and need an independent review first.
- Invite links, join requests, community leave/remove, encrypted rename:
  they depend on the sync prerequisite, C0 shared-group routing and W11/C3
  encrypted names (C1 plan, prerequisites 1 to 3).

## Owner questions

1. Approved by D90 (secret after `#`; binding to target, account and device
   keys built before merge). The binding is v2 (a device signature, a key
   commitment in the link and the secret-keyed tag), built in
   `C1-invite-format.md`; it still needs an independent design review; a
   link the server can read gets no protection. Open: should an invitation
   from someone the joiner shares no group with be refused outright? (v2
   anchors that case on the commitment in the link.)
2. Allow a migration splitting account prune marks by conversation, or
   accept the conservative pause?
3. Which agent owns `app_state.dart`, `models.dart`, `api_client.dart` and
   the local schema number for the client slice, once W8/K2 release them?

## Update 2026-11-07: prerequisite 1 built as a hybrid (agent/c1-p1)

One conversation's MLS failure now pauses only that conversation (local
schema 20, a pause table, replay through the scoped conversation route). It
is not the design's account stream and per-scope cursors; see
[C1-sync-isolation](C1-sync-isolation.md), "Built slice (P1)", and
`testing/evidence/C1-P1-conversation-pause.md`. It needs an Opus review and
is active against a default server (the switch is on by default). The D92 answers
stand: the conservative prune pause stays and the C1 client steps own the
shared client files.

## 2026-11-07 round 2: invites, requests, leave and remove

Owner approved the invite format (secret after `#`, requests an admin
approves). Built, server and app: migration 0048, link with fragment secret,
join requests and approval, community leave and remove, community member
list with usernames, and the Flutter screens. Format, rules and limits are in
[C1-invite-format](C1-invite-format.md). C1 is still **not** done:

- Rename is not built. Group and community names must be encrypted metadata
  (W11, C3), and neither exists; no plaintext rename route was added.
- Approval records membership; encrypted access still follows the existing
  staged MLS commits. C0 shared groups are not built, so a community join is
  still one commit per channel.
- Approval-gated invites are not the "open invites" that C0 blocks on the I33
  halt, but per-conversation halting is still outstanding.
- The server does not notify admins of a new request; they see it when they
  open the list.
- Not tested on a device. Dart analyzer, formatter and the new tests ran
  locally on Flutter 3.44.0 (see `testing/evidence/C1-membership.md`).

## 2026-11-07: scanned-through paging (TASK-209, D92)

The scoped conversation route, only when asked with `?scan=bounded` (the account route never), now adds `scanned_through` (the
highest id examined, hidden rows included, never below the cursor) and
`scan_truncated` (a 2,000-candidate scan budget ended the page early) to the
envelope. A conversation cursor that names a row of its own scope, hidden or
not, is accepted by the legacy-mark expiry test. D92 holds: a block-hidden
tail the cursor passes is not replayed after an unblock. The app's paused
conversation replay keeps paging while `scan_truncated` and moves to
`scanned_through`. Not built: the heads route, `scope_head`, per-scope
client cursors (C1-B2 to B4), and the legacy global stream is unchanged.
(Superseded: `PRIVATE_MESSENGER_SCOPED_SYNC` is on by default in
`config.go`, D98; see the 2026-11-21 section.)

## 2026-11-14 bounded sync only (D134, TASK-209)

`GET /api/v1/sync/events` and the scoped conversation route are always
bounded: the 2,000-candidate scan budget, `scanned_through` and
`scan_truncated` apply to every request, and `?scan=bounded` is accepted and
ignored. A 200 from `/sync/events` carries `events`, `sync_epoch`,
`scanned_through` and `scan_truncated`; `oldest_event_id` and
`latest_event_id` are in the 409 `device_recovery_required` body only. The
account stream (`/sync/account-events`) has no hidden rows and is unchanged.
A client that stops at an empty page must page on while `scan_truncated`.

## 2026-11-09 local port onto 0d09fcb (partial)

Ported both commits from `origin/agent/invite-v2`, preserving current L1,
C4 and L0 bindings. Counters: ABI 21, local schema 32, server migration
0066. Group requests now persist a verified inviter/target anchor before
submission; Welcome validation checks the actual MLS group id and inviter
leaf key before committing state, with rollback on mismatch. See the current
section in `C1-invite-format.md` and `testing/evidence/C1-invite-v2.md`.

Remaining: the community-to-shared-group anchor, encrypted group/community
rename app wiring, native end-to-end community approval/removal evidence,
and independent security review. Existing request, leave, removal and
username screens remain in place. No STATE.md or release gate changed.

## 2026-11-21 review of what is left (agent/c1-c8)

**Scoped sync stays on by default (D98); nothing to flip.** The switch is
`!envOff(...)` in `config.go` and `TestLoadScopedSyncDefaultsOn` pins it. The
earlier worry, "bounds are still account-wide; decide per-conversation bounds
before a client uses them", is closed by how the client uses the routes:

- The app reads only `events`, `scope`, `scope_id`, `scanned_through` and
  `scan_truncated` from the scoped conversation route
  (`ApiClient.conversationSyncPage`). It never reads the envelope's
  `sync_epoch`, `oldest_event_id` or `latest_event_id` there; the D70 leave
  floor fallback `syncLatestEventId` calls the legacy route.
- It uses the conversation route only for a conversation the P1 pause froze
  (`conversation_pause.dart`), never as the main stream, so it has no
  per-scope cursor, head or "caught up" mark to get wrong. The account
  stream route is not called at all.
- D134 made `scanned_through` and `scan_truncated` part of every page, which
  is the per-scope progress a replaying client needs.
- Expiry is the server's 409, from the per-scope prune marks.

So the `scope_head` and `/sync/heads` design in
[C1-scoped-sync-bounds](C1-scoped-sync-bounds.md) is not needed by the built
hybrid (see "Built slice (P1)" in C1-sync-isolation). It becomes needed only
if a later package makes scoped streams the main path (the full design with
per-scope cursors); until then the envelope's account-wide bounds are
documented as "do not read" and no client reads them.

**Rename is built, through W11 and C3, not through a rename route.** A group
name is the encrypted group profile (W11): `group-profile-tile` in
`conversation_details_screen.dart` opens `ProfileEditScreen.group`. A
community's and a channel's name and topic are encrypted info records (C3):
`EditInfoDialog` in `community_screen.dart`, offered to owners and admins
(community) and per D80 (channel). No plaintext rename route exists, by
design.

**Still open in C1** (not built here, see the report):

1. The community-to-shared-group anchor: a community target id differs from
   the shared MLS group id, and the signed invitation does not carry it, so a
   community join does not yet pin the inviter's key the way a group join
   does. This changes what an invitation signs (second-opinion area).
2. Join-request notification: admins still see a request only when they open
   the list. A generic push ("something needs your attention") would need
   the L2/W8 push design and an owner decision on what it may reveal.
3. Independent security review of invite v2 (the 2026-11-09 port was done
   solo at the owner's request), and native end-to-end evidence for a
   community approval and removal on devices.

## 2026-11-21: community-to-shared-group anchor (invite v3)

Owner approved the anchor 2026-11-21. Built as invitation format v3 (design in
[C1-invite-format](C1-invite-format.md), last section): the signed binding
now names the MLS group the invitation admits to (a community's C0 shared
conversation, or the group itself). The joiner pins it before filing the
request, the D99 Welcome check then covers community joins, and a community
pinned this way is shown only while the server names the same shared group.
No crypto ABI, Rust, migration or local schema change; v1 and v2 links are no
longer read. Item 1 of "Still open" above is built; the independent security
review (item 3) now covers v3 too. Remaining limit: the inviter's own
community-to-group mapping still comes from the server (needs the C0 signed
layout record).
