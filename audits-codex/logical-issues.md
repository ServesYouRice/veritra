# Logical and Data-Integrity Issues

This file applies the method and severity rules in [audit-plan.md](audit-plan.md). Findings are ordered by production impact, not by file order.

## Summary

| ID | Severity | Finding | Blocker |
| --- | --- | --- | --- |
| LOG-01 | Critical | Background push catch-up skips MLS processing while advancing the shared cursor | Yes |
| LOG-02 | High | The outbox silently deletes the oldest unsent envelope after 100 entries | Yes |
| LOG-03 | High | Cold-start restoration races with interactive authentication | Yes |
| LOG-04 | High | In-flight sync can write old-account state after sign-out or account change | Yes |
| LOG-05 | High | Retention cleanup cannot keep up with modest production traffic | Yes |
| LOG-06 | High | MLS control-message delivery has no reliable retry loop | Yes |
| LOG-07 | High | A post-commit recipient lookup failure permanently suppresses fan-out | Yes |
| LOG-08 | High | An MLS-enabled client has no recovery path after sync-cursor expiry | Yes |
| LOG-09 | High | Android FCM-only deployments cannot register for push | Yes |
| LOG-10 | High | Any conversation member can drive another participant's call state | Yes, before calls |
| LOG-11 | Medium | Retry timestamps are persisted but no timer wakes the message outbox | No |
| LOG-12 | Medium | WebSocket disposal can lose a connection established during shutdown | No |
| LOG-13 | Medium | Direct device refresh failures escape without a user-visible state | No |

## Findings

### LOG-01 - Background push catch-up skips MLS processing while advancing the shared cursor

- **Severity:** Critical
- **Location:** `mobile/lib/push/background_push.dart:11-68`; `mobile/lib/core/app_state.dart:1400-1513`; Android `VeritraPushService.startBackgroundCatchUp`
- **Description:** The Android headless task reads up to 1,000 durable sync events and saves the newest event ID through `saveSnapshot`, but it does not initialize or invoke `MlsConversationCryptoService`. It therefore advances the same cursor used by foreground crypto processing across `mls.message.created`, application-message, call, and revocation events. Its `full_resync_required` branch also jumps directly to `latest_event_id`. On the next foreground launch, those events are already behind the cursor and are never processed.
- **Why it matters for production:** Once MLS is enabled, a normal background wake can permanently skip group commits, welcomes, revocations, and application messages. The device's MLS epoch can diverge from peers, decryption can fail, and a revoked device transition may never complete. Advancing the cursor without atomically advancing protected crypto state violates the project's core state/cursor invariant.
- **Recommended fix:** Until background crypto is implemented, make the headless task record only a generic wake marker and never mutate the sync cursor. A complete implementation must initialize the native crypto device and process events in order, atomically committing each event's dedupe marker, crypto state, affected ciphertext, and cursor exactly as foreground sync does. Remove the unconditional full-resync cursor jump for MLS sessions.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** Requires production MLS wiring, Android background-execution tests, concurrent foreground/background database tests, and revocation/offline vectors.

### LOG-02 - The outbox silently deletes the oldest unsent envelope after 100 entries

- **Severity:** High
- **Location:** `mobile/lib/storage/local_store.dart:528-530,625-637,772-789`; `mobile/lib/storage/encrypted_database.dart:474-503,745-797`
- **Description:** Both ordinary and MLS application enqueue paths insert the new envelope, load all outbox rows, and delete the oldest rows above `_maxPendingEnvelopes = 100`. The caller receives no capacity error and the UI receives no indication that an unsent message was discarded. In the MLS application path, protected group state has already advanced in the same transaction.
- **Why it matters for production:** An offline user can send 101 messages and permanently lose the first message. Its plaintext is not retained and its idempotency key disappears, so it cannot be retried or reconstructed. Silent data loss is unacceptable in the core messaging flow.
- **Recommended fix:** Never evict unsent data. Enforce capacity before encryption/state advancement and return a typed `outbox_full` result, or use a storage quota based on measured bytes with explicit user remediation. Preserve every queued envelope until acknowledged or explicitly discarded by the user. Add a boundary test at 99/100/101 entries for both crypto and non-crypto paths.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** Draft ownership, MLS ratchet advancement, disk-pressure handling, backup/restore, and user-visible outbox management.

### LOG-03 - Cold-start restoration races with interactive authentication

- **Severity:** High
- **Location:** `mobile/lib/main.dart:15-30`; `mobile/lib/core/app_state.dart:209-261`; `mobile/lib/features/auth/connect_screen.dart`
- **Description:** `runApp` renders the connect screen before `tryRestoreSession()` is started as an unawaited future. There is no `initializing` state and authentication actions are not blocked while restoration reads secure storage, activates crypto, refreshes data, and starts sync. A user can begin login, registration, or device linking while restoration is mutating the same `session`, `api`, encrypted store, and sync fields.
- **Why it matters for production:** Slow Keychain/Keystore access makes the race realistic. Interleaving can switch the UI to the wrong session, close a newly created client, or mix old and new account state. Even without the race, every cold start can flash an unauthenticated screen before the restored session appears.
- **Recommended fix:** Add an explicit bootstrap state (`initializing`, `ready`, `recoveryRequired`) and complete initialization before exposing connect actions. Serialize all session transitions behind one generation/lock. Keep `MaterialApp` mounted, but render a dedicated startup surface until restoration has a definitive outcome.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** LOG-04, encrypted-store recovery UX, push startup, and account-scoped local data.

### LOG-04 - In-flight sync can write old-account state after sign-out or account change

- **Severity:** High
- **Location:** `mobile/lib/core/app_state.dart:1278-1305,1400-1524,1624-1680`
- **Description:** `_catchUpSyncEvents` captures the current session and API client, then performs multiple asynchronous reads and local writes. `_clearLocalSession` cancels the stream subscription without awaiting it and disposes the socket, but it neither cancels nor awaits the active catch-up. The old task can continue refreshing lists and call `localStore.saveSnapshot(...)` after local data was cleared or a different account signed in.
- **Why it matters for production:** Old-account metadata/ciphertext can be repopulated into the single local database after logout and then appear under a later session. This is a privacy boundary failure as well as a source of cursor corruption and stale UI.
- **Recommended fix:** Introduce a monotonically increasing session generation or cancellation token. Check it after every await and immediately before every state or storage commit. Await sync-loop and subscription quiescence during session teardown. Scope database state by canonical server origin plus account/device identity rather than relying only on destructive clearing.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** LOG-01, LOG-03, WebSocket lifecycle, background isolates, and multi-account support.

### LOG-05 - Retention cleanup cannot keep up with modest production traffic

- **Severity:** High
- **Location:** `server/internal/app/app.go:227-280`; `server/internal/storage/message_store.go:479-579`; `server/internal/storage/content_store.go:511-555`
- **Description:** The sweeper runs once at startup and then every six hours. Each cleanup query removes at most 500 rows per table per run. A table receiving more than roughly 83 expiring rows per hour accumulates backlog indefinitely. This affects expired messages/attachments, sync events, audit events, sessions, invites, device links, key packages, calls, and queued blob deletions.
- **Why it matters for production:** A moderately active instance will retain records past the configured window, grow without bound, and misrepresent disappearing-message and operational-retention guarantees. Backlog also increases future query and backup cost.
- **Recommended fix:** Drain bounded batches in a loop until fewer than the batch size remain, with a total time/batch budget and short yields. Run high-volume classes more frequently, add backlog/oldest-row metrics and alerts, and index each cutoff/order predicate. Test sustained arrival rates above the cleanup rate.
- **Blocker before production:** Yes, because retention is a privacy promise.
- **Related risks or dependencies:** Disk capacity, WAL growth, blob deletion, backup size, and PERF-05.

### LOG-06 - MLS control-message delivery has no reliable retry loop

- **Severity:** High
- **Location:** `mobile/lib/core/app_state.dart:1295-1298,1757-1772,1784-1805`; `mobile/lib/crypto/native_crypto_service.dart:110-160,203-237`
- **Description:** MLS commits/welcomes are durably queued with protected state, but `_flushMlsOutbox` sends them sequentially with no per-item error handling, backoff, timer, or connection-triggered retry contract. It is invoked unawaited during startup. A transient failure produces an unhandled future and leaves the queue stuck until another narrow call site or app restart. Revocation processing may try to create the same logical removal again against already-advanced local state instead of first flushing the existing commit.
- **Why it matters for production:** Membership additions, welcomes, epoch updates, and device revocations can stall indefinitely while the app appears connected. These are security-critical control messages, not optional notifications.
- **Recommended fix:** Give the MLS outbox a single serialized delivery worker with durable attempt state, bounded exponential backoff, connectivity wakeups, typed terminal errors, and observability. Always drain an existing transition before creating another transition for the same revocation/conversation. Test restart and every failure boundary.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** MLS state machine ordering, server idempotency, revocation coordinator election, and LOG-01.

### LOG-07 - A post-commit recipient lookup failure permanently suppresses fan-out

- **Severity:** High
- **Location:** `server/internal/messaging/service.go:31-51`; message-envelope handler and `server/internal/httpapi/content_handlers.go:318-353`
- **Description:** Message storage and its durable sync event commit first. The service then queries conversation recipients. If that query fails, the API returns an error after the message is already committed. The client retries with the same idempotency key, but the duplicate path intentionally returns no recipients, so realtime and push fan-out are never retried. Push target lookup failures are also silently dropped.
- **Why it matters for production:** The sender sees a failure for a message the server accepted, while sleeping recipients may receive no wake event. Durable catch-up repairs data only when a client independently reconnects or opens the app.
- **Recommended fix:** Persist a notification/fan-out job in the same transaction as the message and sync event. Process it through a bounded worker with dedupe and retries. An idempotent request should return the committed envelope and be allowed to re-drive any incomplete side effect safely.
- **Blocker before production:** Yes for reliable background delivery.
- **Related risks or dependencies:** Push worker design, realtime dedupe, notification observability, and PERF-02.

### LOG-08 - An MLS-enabled client has no recovery path after sync-cursor expiry

- **Severity:** High
- **Location:** `mobile/lib/core/app_state.dart:1498-1514`; server sync retention configuration
- **Description:** `full_resync_required` is handled only when `_mlsCrypto == null`. With MLS active, an expired cursor becomes a generic offline error and the client remains stuck. A blind metadata resync would be unsafe because skipped MLS epochs cannot be reconstructed from current server metadata, but no relink/restore/recovery-required state exists.
- **Why it matters for production:** A device offline longer than the default sync retention window can become permanently unusable with no actionable explanation. Raising retention only delays the failure and increases server storage.
- **Recommended fix:** Define an explicit cryptographic recovery protocol and UI. Options include restoring a recent encrypted backup, transferring current group state from an approved device, or revoking/re-enrolling the stale device. Return and surface a typed `device_recovery_required` state; never jump the cursor over unseen MLS events.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** Backup/recovery UI, device link, MLS state export, retention policy, and LOG-01.

### LOG-09 - Android FCM-only deployments cannot register for push

- **Severity:** High
- **Location:** Android `MainActivity.configureFlutterEngine`; `mobile/lib/core/app_state.dart:1315-1337`; server push configuration
- **Description:** The server considers push enabled when FCM, APNs, or WebPush is configured. AppState passes an empty VAPID key on an FCM-only server. Android's `register` method rejects the call unless both `instance` and `vapid` are non-empty before it attempts `registerWithFCM()`. AppState catches the failure silently.
- **Why it matters for production:** A documented FCM-only configuration never registers the device, so Android background wake is broken even though the UI and server report push as configured.
- **Recommended fix:** Make registration provider-aware. Attempt FCM when build-time FCM settings are available without requiring VAPID; require VAPID only for UnifiedPush/WebPush. Return a typed platform status and expose registration errors in Settings. Add FCM-only, UnifiedPush-only, APNs-only, and mixed-provider integration tests.
- **Blocker before production:** Yes for advertised FCM support.
- **Related risks or dependencies:** Mobile signing/build configuration, push credentials, UI-07, and LOG-01.

### LOG-10 - Any conversation member can drive another participant's call state

- **Severity:** High
- **Location:** `server/internal/httpapi/call_sync_handlers.go:34-94`; `server/internal/storage/content_store.go:387-508`
- **Description:** Call creation checks only conversation membership and does not require a two-member DM. State transition also checks only that the actor is any current member. Any member can mark a call active/rejected/missed/ended and replace encrypted metadata, including in group/channel conversations, while the product describes calls as 1:1.
- **Why it matters for production:** A group participant can terminate or alter another participant's call. Concurrent transitions have no version precondition, so last-write-wins races can produce misleading state.
- **Recommended fix:** Enforce the supported conversation kind and exactly two active participants. Model caller/callee roles and allowed actor-specific transitions. Add an optimistic version or compare-and-swap state condition and reject stale transitions. Bind encrypted metadata to call ID, actor, and expected state in the client payload.
- **Blocker before production:** Yes before calls are enabled.
- **Related risks or dependencies:** Crypto-gated call UI, TURN testing, sync ordering, and call audit events.

### LOG-11 - Retry timestamps are persisted but no timer wakes the message outbox

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart:1693-1755`
- **Description:** A retryable failure stores `nextAttemptAt`, but `_flushOutbox` runs only at session startup and explicit call sites. If it encounters a future timestamp, it marks the message retrying and continues without scheduling a wakeup. A transient failure while the socket remains connected can therefore stay pending indefinitely unless the user taps Retry or the session restarts.
- **Why it matters for production:** The backoff metadata creates the appearance of automatic delivery without an automatic retry mechanism. Users reasonably expect queued messages to send when connectivity recovers.
- **Recommended fix:** Use one serialized outbox worker that schedules the earliest due item and is also woken by connectivity changes and new enqueue operations. Persist attempts, add jitter, and cancel the timer on session generation changes.
- **Blocker before production:** No, because manual retry exists, but it should be fixed before calling offline send reliable.
- **Related risks or dependencies:** LOG-02, LOG-04, battery use, and server idempotency.

### LOG-12 - WebSocket disposal can lose a connection established during shutdown

- **Severity:** Medium
- **Location:** `mobile/lib/sync/sync_service.dart:54-100`
- **Description:** `dispose()` closes `_socket` only if it is already assigned. If disposal occurs while `WebSocket.connect` is awaiting, the connection can succeed afterward, be assigned to `_socket`, and wait for the peer to close even though `_disposed` is true and the stream controller is closed.
- **Why it matters for production:** Sign-out/account switching can leave an authenticated socket alive longer than intended and leak network/battery resources. It compounds the cross-session race in LOG-04.
- **Recommended fix:** Recheck `_disposed` immediately after connect; close the new socket before installing listeners if disposal won. Make disposal awaitable and await the connect loop/socket close during session teardown. Add a deterministic delayed-connect test.
- **Blocker before production:** No, provided LOG-04 is fixed with session generations.
- **Related risks or dependencies:** Session token lifetime, platform socket behavior, and cancellation APIs.

### LOG-13 - Direct device refresh failures escape without a user-visible state

- **Severity:** Medium
- **Location:** `mobile/lib/features/settings/settings_screen.dart:39-43`; `mobile/lib/core/app_state.dart:328-340`
- **Description:** Settings passes `state.refreshDevices` directly to an `onPressed` callback. `refreshDevices` uses `finally` only, rethrows errors, and does not notify after a failure because execution never reaches `notifyListeners()`. The callback future is not awaited by Flutter and no scoped error is recorded.
- **Why it matters for production:** Network/auth failures can become unhandled asynchronous errors while the screen remains stale and offers no retry explanation. The `devicesLoaded` flag changes internally without a notification.
- **Recommended fix:** Route the action through a scoped operation that catches, maps, and renders the failure. Put `notifyListeners()` in the `finally` block or use immutable load state. Add a widget test for refresh failure and recovery.
- **Blocker before production:** No.
- **Related risks or dependencies:** Shared AppState error handling and UI-05.

## Production Blockers

The following must be resolved before launch:

- [ ] LOG-01: make cursor advancement and MLS state advancement inseparable in every execution context.
- [ ] LOG-02: stop silent eviction of unsent messages.
- [ ] LOG-03 and LOG-04: serialize bootstrap/session teardown and prevent cross-session writes.
- [ ] LOG-05: make retention capacity exceed supported production traffic and monitor backlog.
- [ ] LOG-06: implement reliable MLS outbox delivery.
- [ ] LOG-07: make post-commit fan-out durable and retryable.
- [ ] LOG-08: ship an explicit stale-device recovery path.
- [ ] LOG-09: repair and verify FCM-only registration.
- [ ] LOG-10: enforce call participants and actor-specific state transitions before enabling calls.
