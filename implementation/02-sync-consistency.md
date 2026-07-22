# Plan 02 — Make sync convergent

Durable state and its durable sync event must commit together. Realtime
publication happens only after commit and always carries a positive event ID.
Typing remains best-effort and non-durable.

## Y01 — Make encrypted edit/delete atomic with their events

Audit references: LOG-04, TEST-06.

Objective:
Commit each encrypted message edit or delete marker in the same transaction as
its durable event.

Read first:

- server/internal/storage/message_store.go
- server/internal/httpapi/conversation_handlers.go
- server/internal/messaging/service.go
- server/internal/storage/sqlite_test.go
- server/internal/httpapi/api_test.go

Steps:

1. Add failure-injection tests proving that an event insert failure rolls back
   the message mutation.
2. Move edit/delete mutation plus event insert into focused store/service
   methods.
3. Return the committed envelope, event ID, and recipient-routing inputs.
4. Publish realtime only after commit and only with event ID greater than zero.
5. Define retry/idempotency behavior for duplicate encrypted markers.

Acceptance:

- No successful edit/delete response can exist without its durable event.
- No durable event can describe a rolled-back mutation.
- Offline catch-up observes the same state as realtime clients.
- Existing ciphertext-only and ownership checks remain.

## Y02 — Make reactions, receipts, and retention atomic

Audit references: LOG-04, TEST-06.

Depends on: Y01 transaction pattern.

Objective:
Apply the same state-plus-event transaction pattern to reactions, read
receipts, and retention policy.

Steps:

1. Split the work into three focused commits if needed: reactions, receipts,
   retention.
2. Add a store/service method per mutation rather than a generic transaction
   abstraction.
3. Add event-insert failure tests for create/delete reaction, receipt update,
   and retention update.
4. Preserve reaction uniqueness, receipt monotonicity, role authorization, and
   retention expiry semantics.
5. Publish only after commit.

Acceptance:

- Every durable mutation has exactly one recoverable event after success.
- Repeated client requests do not duplicate state.
- Best-effort typing is unchanged and clearly excluded.

## Y03 — Make call and device lifecycle events atomic

Audit references: LOG-04, TEST-06.

Depends on: Y01 transaction pattern.

Objective:
Eliminate state/event gaps in call transitions and device-link/revocation
events that clients must recover offline.

Read first:

- server/internal/storage/content_store.go
- server/internal/httpapi/call_sync_handlers.go
- server/internal/storage/identity_store.go
- server/internal/httpapi/auth_handlers.go

Steps:

1. Inventory every call/device mutation that writes state then invokes
   saveSyncEvent.
2. Mark purely operational audit events separately from client convergence
   events.
3. Add focused transactional methods and failure-injection tests.
4. Keep call metadata on the strict encrypted schema.
5. Disconnect revoked sessions only after the durable revocation commit.

Acceptance:

- Successful durable call/device changes are recoverable through catch-up.
- Realtime is never published with event ID zero.
- Revocation still fails closed if follow-up realtime disconnect fails.

## Y04 — Add authorized single-message repair

Audit references: LOG-08, UI-04.

Depends on: Y01, Y02.

Objective:
Let a client repair any message referenced by a durable event without
refetching only the newest conversation page.

Read first:

- server/internal/httpapi/api.go
- server/internal/httpapi/conversation_handlers.go
- server/internal/storage/message_store.go
- docs/api.md
- docs/sync.md
- mobile/lib/core/api_client.dart

Steps:

1. Choose one contract: authorized GET /api/v1/messages/{id}, or a complete
   authorized encrypted envelope/tombstone in every durable event.
2. Prefer the single-message endpoint if it keeps event rows small and avoids
   duplicated visibility logic.
3. Require current conversation membership and blocked-sender visibility rules.
4. Define expired/deleted tombstone behavior so a client can remove stale local
   state.
5. Add HTTP tests for member, nonmember, blocked sender, expired message, and
   deleted marker.
6. Update docs before changing the Dart client.

Acceptance:

- Every durable message event can be deterministically repaired.
- The endpoint never exposes an envelope outside current authorization.
- No plaintext field or server-side decryption is added.

## Y05 — Use trusted client identity for realtime limits

Audit references: LOG-05, TEST-05.

Objective:
Apply one spoof-resistant trusted-proxy client-IP resolver to HTTP and
WebSocket connection limits.

Read first:

- server/internal/app/app.go clientIP
- server/internal/httpapi/call_sync_handlers.go syncWebSocket
- server/internal/realtime/hub.go
- deploy/caddy/Caddyfile
- deploy/docker-compose.yml

Steps:

1. Move client-IP resolution behind a small shared interface or pass the
   resolved value into the API; do not duplicate parsing.
2. Trust forwarded headers only when the direct peer is in configured proxy
   CIDRs.
3. Keep account and device connection caps.
4. Add tests with one trusted proxy and more than 20 distinct forwarded
   clients, plus an untrusted spoofed-header negative case.
5. Test X-Real-IP fallback and malformed chains.

Acceptance:

- The 21st legitimate device behind bundled Caddy is not rejected due to the
  proxy address.
- One real client cannot bypass the per-IP cap with an untrusted header.
- HTTP throttling and realtime registration resolve the same identity.

## Y06 — Classify and isolate outbox failures

Audit references: LOG-10, MERGE-08.

Depends on: C03 transactional local outbox.

Objective:
Prevent one terminal envelope from blocking later independent sends.

Read first:

- mobile/lib/core/app_state.dart outbox methods
- mobile/lib/core/api_client.dart error mapping
- mobile/lib/storage/local_store.dart or its C03 replacement
- docs/crypto-protocol.md ordering rules

Steps:

1. Define retryable, reauthentication, throttled, and terminal status classes.
2. Process envelopes independently across conversations.
3. Preserve per-conversation ordering required by MLS epochs.
4. Quarantine terminal items with delete/retry details instead of retrying on
   every reconnect.
5. Apply bounded exponential backoff to retryable failures and honor the
   server's bounded Retry-After value for 429 responses.
6. Add tests with a poison item followed by valid items in the same and a
   different conversation.

Acceptance:

- A terminal item cannot block another conversation.
- Same-conversation MLS ordering is not violated.
- Terminal items remain visible and recoverable by explicit user action.
- Reconnect does not create an infinite 4xx loop.
- A 429 response cannot create a tight client retry loop.

## Y07 — Replace global busy/error with scoped operation state

Audit references: LOG-11, UI-10.

Objective:
Stop unrelated background and foreground actions from disabling controls or
displaying each other's errors.

Read first:

- mobile/lib/core/app_state.dart
- chat, connect, settings, invite, and community screens that read busy/error
- existing AppState tests

Steps:

1. Inventory every busy/error consumer before changing the model.
2. Introduce small operation/resource states for auth, send, membership,
   settings, and background sync.
3. Return action errors to the caller where a screen owns the interaction.
4. Model connection/sync state separately from action failure.
5. Migrate one feature family at a time and remove global fields only after all
   consumers are gone.
6. Add interleaving tests.

Acceptance:

- A sync failure cannot be shown as a send failure.
- One settings operation cannot disable another conversation's composer.
- Duplicate submission is still prevented per operation.
- Whole-app rebuild frequency does not materially increase.

## Y08 — Apply catch-up incrementally

Audit references: PERF-02, LOG-08.

Depends on: C03, Y04, Y07.

Objective:
Use typed events to update or fetch only affected rows while retaining a safe
full-resync path.

Steps:

1. Document the client reducer for each durable event type.
2. Repair referenced messages through Y04.
3. Update only the affected conversation summary and message rows.
4. Coalesce event bursts and debounce persistence.
5. Process and commit local state before advancing the durable cursor.
6. Retain full_resync_required behavior and test cursor expiry.

Acceptance:

- One message event does not refetch every conversation.
- Cursor advancement is atomic with applied state.
- Duplicate events are idempotent.
- Full resync repairs intentionally dropped/corrupt local caches.
