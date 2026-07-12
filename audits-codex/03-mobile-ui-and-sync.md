# Mobile, UI, and sync

Production crypto, platform projects, Flutter CI drift, the channel-kind mismatch, and false deletion wording are release gates R-02 through R-05 and R-14.

## MOB-01 — Sync catch-up reads one page and drops concurrent triggers (High)

- **Evidence:** `ApiClient.syncEvents` defaults to 100 (`mobile/lib/core/api_client.dart:226-241`). `_catchUpSyncEvents` performs one request; if already running, a new WebSocket/error trigger simply returns (`mobile/lib/core/app_state.dart:590-638`).
- **Impact:** more than 100 pending events remain unapplied until another unrelated trigger. An event arriving during a catch-up can be lost as a trigger, leaving the client stale indefinitely.
- **Fix:** loop until a short page, carry a “catch-up requested again” flag, and test bursts larger than every page boundary.

## MOB-02 — The client acknowledges events before applying their state (High)

- **Evidence:** the loop advances `_lastSyncEventId`, then persists it at `app_state.dart:606-624`; conversation/message refresh happens afterward at `625-630`.
- **Impact:** if a refresh fails or the process dies after cursor persistence, the event is permanently acknowledged but its state was never applied.
- **Fix:** apply event effects to durable local state first, then atomically commit state plus cursor. If state is fetched, persist the cursor only after all required fetches succeed.

## MOB-03 — Session and sync cursor can be paired with the wrong account (High)

- **Evidence:** secure storage uses two global keys (`mobile/lib/storage/local_store.dart:62-63`) and separate writes. Login/register/device-link save the new session before resetting the cursor (`mobile/lib/core/app_state.dart:148-150,278-280,520-522`).
- **Impact:** a crash between writes can pair a new server/account with an old high cursor and skip its initial events.
- **Fix:** store a single versioned session record or key cursors by canonical server/account/device; update it atomically in a local database.

## MOB-04 — Client pings are never answered by the hand-written server WebSocket (High)

- **Evidence:** the Flutter socket sends pings every 30 seconds (`mobile/lib/sync/sync_service.dart:57-61`). The server frame reader discards every non-close frame and does not echo ping payloads as pong (`server/internal/realtime/websocket.go:147-200`).
- **Impact:** Dart's ping watchdog can close otherwise healthy connections, causing perpetual reconnect churn and delayed sync.
- **Fix:** use a maintained WebSocket implementation, or implement RFC-compliant serialized control writes and tests for ping, pong, close, fragmentation, masking, payload limits, and concurrency.

## MOB-05 — Reconnect logic becomes a one-second hot loop (High)

- **Evidence:** any connection that closes normally resets delay to one second (`mobile/lib/sync/sync_service.dart:30-45`), even if it lived only milliseconds. Authentication failures retry forever. JSON decode exceptions inside the listener are not contained (`sync_service.dart:64-79`).
- **Impact:** server rejection/short-close conditions drain battery, create log/request storms, and can surface unhandled async errors.
- **Fix:** reset backoff only after a stable connection, add jitter, stop on terminal auth/protocol errors, contain malformed events, and await socket/subscription shutdown.

## MOB-06 — Session expiry leaves a zombie signed-in UI (High)

- **Evidence:** API errors translate 401 to text only (`mobile/lib/core/api_client.dart:494-496`). `AppState._run` records an error but does not clear the session/stop sync (`app_state.dart:680-691`). Sessions expire after 30 days server-side.
- **Impact:** the app can look signed in while every request and WebSocket reconnect fails forever.
- **Fix:** surface typed auth errors; centrally clear runtime credentials and stop sync on 401; preserve only non-secret device identity needed for a proof-based login.

## MOB-07 — Users cannot sign out while offline (High)

- **Evidence:** `logout` waits for the server request before `_clearLocalSession` (`mobile/lib/core/app_state.dart:529-537`).
- **Impact:** network failure prevents a local security action on a lost/shared device.
- **Fix:** clear token and sensitive local data first, close connections, then attempt remote revocation best-effort or queue it. Explain that server sessions may remain until expiry.

## MOB-08 — Cold start can show a blank screen for network timeouts (Medium)

- **Evidence:** `main` awaits `tryRestoreSession` before `runApp` (`mobile/lib/main.dart:20-25`). Restore performs conversation and device network calls (`mobile/lib/core/app_state.dart:85-100`), each with up to 30-second request phases.
- **Impact:** offline users can see no application UI for a long period and cannot cancel or choose another account.
- **Fix:** render immediately, hydrate local state asynchronously, show an offline/restoring shell, and put strict total bounds on startup refresh.

## MOB-09 — Search returns only disabled rows (High)

- **Evidence:** the server returns `account`, `community`, and `channel` result types (`server/internal/storage/sqlite.go:1368-1388`). The UI enables taps only for a nonexistent `conversation` result (`mobile/lib/features/search/search_screen.dart:139-161`) while claiming conversation-title search (`search_screen.dart:10,122-124`).
- **Impact:** every real search result is inert; the main search surface is functionally broken.
- **Fix:** either return scoped conversation results or implement navigation/actions for account/community/channel; align copy and contract tests.

## MOB-10 — Older search responses can overwrite newer input (Medium)

- **Evidence:** debounce cancels timers only; `_search` has no request generation/token (`mobile/lib/features/search/search_screen.dart:36-80`). Clearing does not invalidate an in-flight request.
- **Impact:** slow responses can replace newer results or repopulate a cleared screen.
- **Fix:** use a monotonically increasing generation/cancellation token and apply a result only when it still matches the normalized query.

## MOB-11 — HTTP clients leak and responses are unbounded (Medium)

- **Evidence:** each `ApiClient` owns an `HttpClient` (`mobile/lib/core/api_client.dart:7-15`) but exposes no close method. Setup probes/auth attempts create replacements. Response bodies are fully decoded with `utf8.decodeStream` without a byte cap (`api_client.dart:381-411`); `.timeout` does not explicitly abort the underlying request.
- **Impact:** repeated connection attempts can retain sockets; a malicious/broken server can exhaust memory or continue background I/O after a UI timeout.
- **Fix:** make the client disposable, reuse it per canonical origin, abort timed-out requests, cap response bytes, and stream large exports.

## MOB-12 — Server URLs are not canonicalized or restricted to origins (High)

- **Evidence:** validation accepts any HTTP(S) URI with a host, including paths, query, fragment, and userinfo (`mobile/lib/features/auth/connect_screen.dart:292-304`). API paths use `Uri.resolve` while WebSocket uses `replace`; device-ID reuse compares raw URL strings (`mobile/lib/core/app_state.dart:133-146`).
- **Impact:** equivalent URLs create duplicate identities, base paths behave inconsistently, and query/userinfo can accidentally propagate to requests/WebSocket URLs.
- **Fix:** accept and store a canonical origin only: lowercase/punycode host, explicit effective port, no userinfo/query/fragment, and a defined base-path policy.

## MOB-13 — The HTTP warning can be bypassed by attacker-controlled hostnames (High)

- **Evidence:** `_isLocalHost` treats any hostname beginning `10.` or `192.168.` as local (`mobile/lib/features/auth/connect_screen.dart:406-425`), so names such as `10.attacker.example` skip the warning. It also considers all `.local` and RFC1918 destinations safe over plaintext.
- **Impact:** passwords, bearer tokens, and metadata can be sent over cleartext without confirmation to a remote/DNS-rebound host; LAN observers remain in the threat model.
- **Fix:** allow plaintext only for parsed loopback IPs by default. Parse IP literals structurally, require explicit development mode for LAN HTTP, and enforce HTTPS in release builds.

## MOB-14 — Registration has no password confirmation or byte-limit parity (Medium)

- **Evidence:** owner/join has one password field (`mobile/lib/features/auth/connect_screen.dart:235-255`). Client validation uses Dart string length and only a 12-character minimum (`connect_screen.dart:307-315`); server bcrypt policy is 12 to 72 bytes (`server/internal/auth/auth.go:13-25`).
- **Impact:** a typo can permanently lock out a user because no reset exists; long/multibyte passwords fail only after submission with confusing policy differences.
- **Fix:** add confirmation for account creation, show byte-compatible bounds, support password managers/paste, and test Unicode boundary cases.

## MOB-15 — Pushed chat routes depend on mutable global selection (Medium)

- **Evidence:** every route constructs `ChatScreen(state: ...)` without an ID; the screen reads `state.selectedConversation` (`mobile/lib/features/chat/chat_screen.dart:13-35`). Selection is global (`mobile/lib/core/app_state.dart:41,59-66`).
- **Impact:** another navigation/action can change the selection underneath an existing route, showing or sending to the wrong conversation.
- **Fix:** pass immutable `conversationId` into each route and every send/detail action; keep selection only as optional shell state.

## MOB-16 — The UI presents controls the user cannot exercise (Medium)

- **Evidence:** Invites is shown to every account (`mobile/lib/features/settings/settings_screen.dart:69-78`). Add-member, admin-role grants, and retention controls are shown to every conversation member (`conversation_details_screen.dart:80-112,187-250`). The client does not load current conversation role/capabilities.
- **Impact:** normal users discover authorization only through 403 errors; high-risk role actions lack contextual constraints.
- **Fix:** return explicit capabilities/current role, hide or explain unavailable actions, and still enforce all rules server-side.

## MOB-17 — Community UI state is session-only and duplicates channels (Medium)

- **Evidence:** the screen documents the missing list endpoint and uses only communities created in the current session (`mobile/lib/features/communities/community_screen.dart:8-22`). Channel conversations are then listed again under “Channels you are in” (`47-73`); rows inside a new community card are not tappable (`206-211`).
- **Impact:** app restart loses the community hierarchy, the same channel appears in two places, and one copy cannot be opened.
- **Fix:** add a scoped community/channel read model, persist/cache it, map one channel to one navigation target, and provide consistent actions.

## MOB-18 — Accessibility and localization have no verified contract (Medium)

- **Evidence:** message bubbles add a custom `Semantics` label without excluding child semantics (`mobile/lib/features/chat/chat_screen.dart:282-286`); decorative empty-state icons are not excluded. All strings and month/time formatting are hardcoded; time is always 24-hour (`mobile/lib/ui/format.dart:4-45`). Day difference uses elapsed hours, which can mislabel dates across DST (`format.dart:13-21`). No accessibility/localization tests exist.
- **Impact:** screen readers may announce duplicated/noisy content, regional settings are ignored, and date labels can be wrong.
- **Fix:** perform TalkBack/VoiceOver and large-text/contrast passes; use Flutter localization/date APIs and calendar-day arithmetic; add semantics and text-scale widget tests.

## MOB-19 — There is no durable offline message state or outbox (High)

- **Evidence:** `LocalStore` persists only session and sync cursor (`mobile/lib/storage/local_store.dart:7-13`). Conversations/messages and sends live in the 666-line in-memory `AppState`; sending is a single immediate API call (`mobile/lib/core/app_state.dart:430-440`).
- **Impact:** restart/offline mode loses all visible message state; sends cannot queue/retry safely; sync correctness depends on full server refetches.
- **Fix:** add an encrypted local database keyed by account/device, a transactional event cursor, idempotent outbox, delivery states, bounded cache, and logout wipe policy.

## MOB-20 — Push notifications are only a server-side placeholder (High)

- **Evidence:** the mobile app contains no APNs/FCM/UnifiedPush registration or wake/sync handling. The server stores endpoints but has no provider wired; `docs/TODO.md:10` explicitly leaves providers open.
- **Impact:** backgrounded/offline mobile clients will not learn about messages until foreground/manual reconnect, which is incompatible with a practical messenger.
- **Fix:** implement optional provider adapters behind the existing generic-payload rule, platform registration/rotation/revocation, background catch-up, and privacy-focused integration tests.

## MOB-21 — Channel and backing-conversation creation is not atomic (High)

- **Evidence:** the client first commits a channel, updates local state, exits one `_run`, and then calls a separate conversation endpoint (`mobile/lib/core/app_state.dart:319-346`). There is no uniqueness constraint tying one backing conversation to one channel.
- **Impact:** any second-call failure leaves an orphan channel; retrying can create more channels or multiple conversations for one channel.
- **Fix:** expose one idempotent server application command that creates channel, conversation, owner membership, and events in one transaction.

## MOB-22 — A pruned sync cursor produces silent state gaps (High)

- **Evidence:** sync/audit events are deleted after 30 days by default (`server/internal/app/app.go:106-136`). `GET /sync/events` accepts any `after` value and returns only surviving rows (`server/internal/httpapi/api.go:1028-1036`); it provides no oldest cursor, epoch, or “full resync required” response.
- **Impact:** a device offline beyond retention resumes from an obsolete cursor and silently misses every pruned change.
- **Fix:** return a sync epoch plus retained cursor bounds; reject expired cursors with a typed full-resync requirement; rebuild a consistent snapshot before accepting a new cursor.

## MOB-23 — The account-ID fallback accepts malformed IDs (Medium)

- **Evidence:** server account IDs are exactly `acct_` plus 32 hex characters (`server/internal/domain/types.go:199-204`), but the picker accepts any 8-or-more hex characters (`mobile/lib/ui/widgets/account_picker.dart:59,132-180`) without resolving the account.
- **Impact:** the UI can submit fabricated IDs that become foreign-key/storage errors, often surfaced as misleading lookup/500 failures.
- **Fix:** share the exact ID grammar, resolve/authorize pasted IDs before selection, and map nonexistent accounts to a typed 404/validation error.
