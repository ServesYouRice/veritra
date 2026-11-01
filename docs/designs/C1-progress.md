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

## Design finding: no new retention-floor table

The sync-isolation design proposes `sync_retention_floors`. Migration 0044
already keeps per-account and per-conversation prune marks, and the scoped
expiry check reads those. A new table and migration are not needed for the
server slice. Limit: account marks do not record the conversation of a
pruned Welcome, so a conversation stream is also expired by any pruned
account event after its cursor. That errs towards pausing, never towards a
silent gap. Splitting account marks by conversation would need a migration.

## Not built, and why

- HTTP routes `/sync/account-events` and `/conversations/{id}/sync-events`:
  inactive routes need coordinator review; the stream envelope (`scope`,
  `scope_id`, `sync_epoch`, bounds) is specified in the sync-isolation design.
- Client scoped cursors, recovery table, `ScopedMlsTransition`, native
  changes: they touch `app_state.dart`, `local_store.dart` and the local
  schema, owned by W8/K2/coordinator, and need an independent review first.
- Invite links, join requests, community leave/remove, encrypted rename:
  they depend on the sync prerequisite, C0 shared-group routing and W11/C3
  encrypted names (C1 plan, prerequisites 1 to 3).

## Owner questions

1. Approve the invitation wire format and proof (secret after `#`, binding
   to target, account and device keys). Needs an independent design review;
   not guessed here.
2. Allow a migration splitting account prune marks by conversation, or
   accept the conservative pause?
3. Which agent owns `app_state.dart`, `models.dart`, `api_client.dart` and
   the local schema number for the client slice, once W8/K2 release them?
