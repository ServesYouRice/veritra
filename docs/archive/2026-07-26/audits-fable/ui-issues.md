# UI Issues — Interface & Experience Audit (Flutter client)

General impression: the client shell is well above MVP average — consistent Material 3 usage, real empty/loading/error states with retry, deliberate Semantics/accessibility work, day separators, unread badges, responsive rail/bottom-nav switch. The issues below are what still separates it from production.

---

## UI-1. Every DM is titled "Direct message" — conversations are indistinguishable

- **Severity:** High
- **Location:** `mobile/lib/features/chat/chat_list_screen.dart:200-212` (`conversationTitle`), `chat_screen.dart` app bar; server side: `ListConversationsPage` returns no counterpart identity for DMs (`server/internal/storage/community_store.go`)
- **Problem:** DMs have no title (`title` is forced null for kind `dm`), and the server's conversation list doesn't include the other participant's username. The client falls back to the literal string "Direct message" for every DM, with an identical generic avatar. A user with three DMs sees three identical rows; the subtitle ("Direct message · Encrypted") adds nothing.
- **Why it matters:** The chat list is the home screen of the product. Users cannot find a conversation or confirm who they're talking to — also a safety issue (sending to the wrong person).
- **Recommended fix:** Include DM counterpart `{account_id, username}` (and group member counts) in the conversation list response; render the username as the DM title and derive an avatar (initials). This is a server + client change.
- **Blocker before production:** Yes.
- **Related:** Message bubbles show "sender acct_…" short IDs (`chat_screen.dart:361`) for the same reason — group chats need sender display names too.

## UI-2. Messages render as "Encrypted message" placeholders (no decryption)

- **Severity:** Critical (documented blocker)
- **Location:** `chat_screen.dart:396-415` (`_MessageBubble`); root cause `UnavailableCryptoService` (`mobile/lib/crypto/crypto_service.dart`)
- **Problem:** Every received message renders as a lock icon + "Encrypted message"; sending always fails with "Production MLS/OpenMLS encryption is not integrated". The entire core loop is non-functional by design.
- **Why it matters:** This is Blocker #0 from `REMAINING-WORK.md`; recorded here for completeness so the UI file stands alone.
- **Recommended fix:** Complete the MLS integration plan; the bubble layout is already structured to take a text child.
- **Blocker before production:** Yes (already tracked).

## UI-3. Mojibake in the password helper text

- **Severity:** Low (but user-visible on the first screen)
- **Location:** `mobile/lib/features/auth/connect_screen.dart:359` — `'Password must be 12â€“72 UTF-8 bytes.'`
- **Problem:** A UTF-8 en-dash was corrupted through a wrong-encoding save; users literally see "12â€“72". Also, "UTF-8 bytes" is developer language.
- **Recommended fix:** Replace with `'Password must be 12–72 characters.'` (or "at least 12 characters" and enforce the 72-byte cap silently with a clearer message only when hit). Grep confirmed this is the only mojibake in the repo.
- **Blocker before production:** No — but it's a one-character fix on the first screen users see.

## UI-4. No UI for message actions the server already supports (edit, delete, reactions, reply, threads)

- **Severity:** Medium
- **Location:** `chat_screen.dart` (`_MessageBubble` has no gesture handlers); server routes exist: `POST /messages/{id}/edit|delete|reactions`, `reply_to_id`/`thread_root_id` fields
- **Problem:** There is no long-press/context menu on messages — edit, delete-for-everyone, reactions, and replies are unreachable, though the server, sync events, and even the client models (`editedAt`, `deletedAt` render states exist) support them.
- **Why it matters:** Server-side features that no client exercises rot (see the untested key-package endpoint); and "delete message" is a privacy-relevant control users expect.
- **Recommended fix:** Long-press context menu on own messages (edit/delete) and all messages (react/reply) — gated on crypto availability like the composer.
- **Blocker before production:** Delete: yes (privacy control). Others: no.

## UI-5. Chat view never paginates — only the newest 100 messages are ever visible

- **Severity:** Medium
- **Location:** `mobile/lib/core/app_state.dart:315-327` (`_fetchMessages` — no `before` cursor), `chat_screen.dart` `_MessageList` (no scroll listener)
- **Problem:** `listMessages` is always called without pagination parameters; the server caps at 100 and returns `next_before`, which the client ignores. Scrolling up stops at message #100 with no loader and no indication history exists.
- **Recommended fix:** On scroll-to-top, fetch with `before=<oldest id>` and prepend; the server contract (`next_before`) is already there.
- **Blocker before production:** Yes once messages render (history access is core).

## UI-6. Background/sync errors surface in the wrong places (or nowhere)

- **Severity:** Medium
- **Location:** `app_state.dart` (`error` set by `_catchUpSyncEvents:999` and `_run`), consumers: `connect_screen.dart:320` (only shown when logged out), `chat_screen.dart:163` (attributes any error to the send)
- **Problem:** While logged in, a sync failure writes `state.error` but no logged-in screen displays it except as a misattributed send-failure snackbar; conversely a stale `error` from a background failure can make `startConversation`/`createInvite` return null and show a confusing snackbar. There is also no offline/connection-state indicator anywhere, even though the sync service knows it is reconnecting.
- **Recommended fix:** Separate connection state (show a subtle "Reconnecting…" banner in the shell) from per-action errors (returned by the action, shown by the caller). See logical-issues L-6.
- **Blocker before production:** No, but high value.

## UI-7. Wide layouts get a rail but not a split view

- **Severity:** Low
- **Location:** `mobile/lib/ui/app_shell.dart` (rail at ≥720 px), `chat_list_screen.dart` (pushes `ChatScreen` full-screen)
- **Problem:** On tablets/desktop-width windows the chat list and conversation are never shown side by side; opening a chat covers the list, and `selectedConversationId` state suggests a master-detail design was intended.
- **Recommended fix:** At the rail breakpoint, render list + detail in a `Row` and stop pushing a route.
- **Blocker before production:** No.

## UI-8. Sending state blocks the composer globally and clears late

- **Severity:** Low–Medium
- **Location:** `chat_screen.dart:483-495` (send button disabled by global `busy`), `_send` (composer text cleared only after the full round-trip)
- **Problem:** (a) The send button disables during *any* app-wide operation, not just this conversation's send; (b) the composer keeps the typed text until the server acknowledges, so quick consecutive messages aren't possible — contrast with the optimistic outbox that already renders a pending bubble; (c) `sendMessageTo` refetches the entire first message page after every send.
- **Recommended fix:** Clear the composer immediately after enqueueing to the outbox (the pending bubble + retry already cover failure), and gate the button on empty text rather than global busy.
- **Blocker before production:** No.

## UI-9. Conversation details: members are write-only, and "Add member" appears on DMs

- **Severity:** Medium
- **Location:** `mobile/lib/features/chat/conversation_details_screen.dart` (comment at top acknowledges the gap; "Add member" tile at line 87-98)
- **Problem:** (a) You can add members but never see, remove, or leave — because the server lacks those endpoints (logical L-12); the screen even documents this. (b) The add-member tile is shown for DMs (the creator has the `owner` role), enabling the DM-to-group conversion of L-4 straight from the UI. (c) Role picker offers "Admin" which a moderator actor can't grant — server will 403 with a generic message.
- **Recommended fix:** Hide add-member for DMs now; add member list + leave/remove once the endpoints exist; filter grantable roles by the caller's own role.
- **Blocker before production:** Tied to L-4/L-12.

## UI-10. No push-permission or notification UX beyond a hidden distributor picker

- **Severity:** Medium
- **Location:** `app_state.dart:829-890` (`_startPush`, `choosePushDistributor`); settings screen
- **Problem:** Push setup is entirely silent: if the server has no VAPID keys, or Android has no UnifiedPush distributor installed, the user gets no indication that they will receive no notifications, and there is no iOS path at all (APNs deferred). Muting exists server-side per conversation (`/notifications`), and the client can set it, but there's no visible mute toggle in the chat UI (verify: no `notifications` call from any screen — only the API method exists).
- **Recommended fix:** Notification section in Settings: current push status ("No push provider installed — messages arrive when the app is open"), distributor picker entry point, and a per-conversation mute toggle in conversation details.
- **Blocker before production:** iOS honesty banner: yes; rest: no.

## UI-11. Typing and read-receipt signals exist server-side but have no UI

- **Severity:** Low
- **Location:** server `POST /conversations/{id}/typing`, `read_receipt.updated` events; client sends receipts (`markNewestMessageRead`) but renders neither ticks nor "typing…"
- **Problem:** The client *emits* read receipts (privacy-relevant!) but never *shows* them, so users pay the privacy cost with zero benefit; typing is never sent or rendered.
- **Recommended fix:** Either render delivery/read state and a typing indicator, or stop sending receipts until the UI exists and add a privacy toggle when it does.
- **Blocker before production:** No — but decide the receipt asymmetry deliberately.

## UI-12. Connect screen niggles

- **Severity:** Low
- **Location:** `mobile/lib/features/auth/connect_screen.dart`
- **Problems:**
  - Default URL is `http://localhost:8080` (line 25) — meaningless on a phone; release builds then hit the HTTPS-required snackbar. Prefill empty with an `https://` hint instead.
  - "Sign in" requires the device to be already linked; a fresh install signing into an existing account gets `StateError('Password login requires this device to be linked first.')` — accurate but the mode isn't disabled and the error arrives only after submitting (`app_state.dart:201-206`). Steer fresh installs toward Link mode proactively.
  - `_confirmInsecureUrl` uses `context` across an async gap without a `mounted` guard before `showDialog` (line 434) — low-risk lint-level issue.
  - Password confirmation validator compares against live `password.text` but doesn't revalidate when the password field changes afterwards.
- **Blocker before production:** No.

## UI-13. Settings/admin coverage gaps

- **Severity:** Low–Medium
- **Location:** `mobile/lib/features/settings/` (settings, profile, invite, device-link screens exist)
- **Problem:** Server admin endpoints (account list/suspend, audit events, admin invite revocation) have no client surface at all — an owner must use curl. Account export (`GET /api/v1/account/export`) and block/unblock management also have no UI (blocks are enforceable server-side but a user cannot create or review them from the app; search results offer no "block" action).
- **Recommended fix:** Minimal admin panel (accounts + suspend + audit log) and a Blocked accounts screen under Settings; wire export to a share-sheet JSON download.
- **Blocker before production:** Blocks UI: yes (safety feature must be reachable); admin: no (curl is tolerable for self-hosters at v1, document it).

## UI-14. Accessibility — good foundation, unfinished pass

- **Severity:** Medium
- **Location:** app-wide; `REMAINING-WORK.md` already lists the manual TalkBack/VoiceOver pass as outstanding
- **Observations:** Semantics labels, MergeSemantics, live regions, and ExcludeSemantics on decorative avatars are used thoughtfully. Remaining risks: message bubbles use `excludeSemantics: true` with a summary label — once real message text renders, that pattern must be revisited so text is selectable/readable by screen readers; unread badge color-only distinction on the date (primary color) needs a non-color cue (bold already helps); dynamic type at large scales untested (fixed 420 px bubble max width, fixed avatar sizes).
- **Blocker before production:** The manual pass itself: yes (already tracked).

---

## Recommended UI Priorities Before Production

1. **UI-2 / crypto** — message rendering & sending (tracked Blocker #0; everything else assumes it).
2. **UI-1** — DM/group naming and sender identity in list + bubbles (with the server-side data change).
3. **UI-5** — message history pagination in the chat view.
4. **UI-9 + L-4** — hide "Add member" on DMs (one-line fix, trust integrity).
5. **UI-13 (blocks)** — reachable block/unblock UI (safety).
6. **UI-4 (delete)** — delete-message control (privacy), then edit/react/reply.
7. **UI-10** — honest notification-status UX (especially iOS "no push" state) + per-conversation mute.
8. **UI-6** — reconnecting banner + scoped error surfacing.
9. **UI-3** — fix the mojibake (trivial, do it with any of the above).
10. **UI-14** — manual screen-reader + dynamic-type pass on real devices.
11. **UI-7 / UI-8 / UI-11 / UI-12** — polish tier.
