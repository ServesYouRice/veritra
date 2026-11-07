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
   keys built before merge). The binding is a secret-keyed tag, built in
   `C1-invite-format.md`; it still needs an independent design review, and a
   v2 needs C7's ABI 13 signature and a key commitment the
   server cannot replace; a link the server can read gets no protection.
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

The scoped conversation and account routes now add `scanned_through` (the
highest id examined, hidden rows included, never below the cursor) and
`scan_truncated` (a 2,000-candidate scan budget ended the page early) to the
envelope. A conversation cursor that names a row of its own scope, hidden or
not, is accepted by the legacy-mark expiry test. D92 holds: a block-hidden
tail the cursor passes is not replayed after an unblock. The app's paused
conversation replay keeps paging while `scan_truncated` and moves to
`scanned_through`. Not built: the heads route, `scope_head`, per-scope
client cursors (C1-B2 to B4), and the legacy global stream is unchanged.
`PRIVATE_MESSENGER_SCOPED_SYNC` still defaults to off in `config.go`; the
brief said it now defaults on, but main does not.
