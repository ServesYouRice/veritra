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
`PRIVATE_MESSENGER_SCOPED_SYNC=1`; off, they are not registered and answer 404.
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
   device signature waits for C7's ABI 13.
2. Allow a migration splitting account prune marks by conversation, or
   accept the conservative pause?
3. Which agent owns `app_state.dart`, `models.dart`, `api_client.dart` and
   the local schema number for the client slice, once W8/K2 release them?

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
