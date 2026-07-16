# UI / UX Issues — Veritra Audit (audits-fable)

Scope: the Flutter client (`mobile/lib/**`) and the server's `/setup` page. Note that many UI surfaces cannot currently be exercised at all because the client crypto is a stub (see LOG-0); findings below are from reading the widget tree and tracing state, plus the flows that *are* reachable.

> **Historical snapshot with later status notes:** detailed findings describe
> `c939f26`; the status column records selected remediation through 2026-07-16.
> Use [`../audits-codex/README.md`](../audits-codex/README.md) for current release
> status.

**Severity scale:** Critical / High / Medium / Low / Nice-to-have.

---

## Summary table

| ID | Title | Severity | Blocker | Status (2026-07-16) |
|---|---|---|---|---|
| UI-1 | Errors shown as raw exception strings (`StateError: …`, `Request failed (500)`) | High | Yes | **Fixed** — `describeError()` + full `ApiException` code map |
| UI-2 | No form validation feedback on any auth field | High | Yes | **Fixed** — `Form` + field validators on connect screen |
| UI-3 | Connect screen ignores setup status; wrong mode = confusing failures | Medium | Yes | **Fixed** — debounced setup probe steers auth mode |
| UI-4 | Loading states are inconsistent and largely absent | Medium | No | **Fixed** — per-list first-load flags (`communitiesLoaded`/`invitesLoaded`/`devicesLoaded`) drive spinners on Communities, Invites, and Settings→Devices; chat list + messages already covered |
| UI-5 | Chat message load has no error/retry state; failure looks empty | Medium | No | **Fixed** — per-conversation error state + retry |
| UI-6 | "Add member" / "New conversation" require raw account IDs (no directory) | High | Yes | **Fixed** — username lookup picker (exact match by server design); raw ID kept as fallback |
| UI-7 | Session-created records vanish on refresh (invites, communities) with weak warning | Medium | No | **Fixed** — server `GET /invites`, `GET /communities`, `GET /communities/{id}/channels` added; client hydrates on session start |
| UI-8 | No unread indicators, message previews, or ordering by activity | Medium | No | **Fixed (ordering + unread)** — server `ListConversations` now returns `last_message_at` + `unread_count` and orders by activity; chat list shows unread badges, recency ordering, and activity time. Message previews still blocked on decryption (LOG-0) |
| UI-9 | Device-link screen missing QR rendering; code entry only | Medium | Yes | **Fixed** — QR rendering, camera scanning, and the required iOS camera usage declaration are present; manual code entry remains available |
| UI-10 | No pull-to-refresh / manual refresh on several screens | Low | No | **Fixed** — `RefreshIndicator` on invites and communities screens (chat list already had one) |
| UI-11 | Attachment button permanently disabled with no path forward | Low | No | Open — intentional placeholder (blocked on LOG-0/LOG-3) |
| UI-12 | Accessibility: unlabeled icon-only controls, no semantics on brand/avatars | Medium | No | **Partial** — bubble sender/time semantics; decorative avatars excluded across chat list, communities, and conversation details; all section headers marked `header: true`; chat-list rows merged into one node with an unread-count label. Full manual TalkBack/VoiceOver pass still recommended before launch |
| UI-13 | Message metadata line leaks raw protocol string into the bubble | Low | No | **Fixed** — protocol dropped from meta line |
| UI-14 | Empty password/username accepted by UI, rejected opaquely by server | Medium | No | **Fixed** — with UI-2 |
| UI-15 | No confirmation that a message failed to send vs. sent | Medium | No | **Fixed at the encrypted outbox boundary** — queued envelopes render durable sending/failed state, survive restart, and retry with their original idempotency key; production sending remains fail-closed on LOG-0 |
| UI-16 | `/setup` page is a dead-end notice with no actionable next step | Low | No | **Fixed** — notice gives the safe stop condition, exact prerequisite, and warns against placeholder/test keys |
| UI-17 | Search bar has no clear button; stale results linger between queries | Low | No | **Fixed** — clear (✕) button resets query + results |
| UI-18 | No account/profile screen; account is an ID string only | Medium | No | **Fixed** — Settings links to a profile surface with username, instance role, copyable account ID, and current-device identity; unsupported editing and safety-number verification are explicit |
| UI-19 | Timestamps use device-local parsing with silent failure risk | Low | No | **Fixed** — `tryParse` with epoch sentinel; one bad row can't blank a list |
| UI-20 | Retention radio has no "custom" and no confirmation of destructive change | Low | No | **Fixed** — confirmation dialog stating existing messages keep their timer |

---

## UI-1 — Errors are raw exception strings

- **Severity:** High
- **Location:** `mobile/lib/core/app_state.dart:640` (`error = err.toString()`), surfaced verbatim by `connect_screen.dart:182-185`, `chat_screen.dart:118-120`, and every `SnackBar(content: Text(state.error!))`
- **Description:** `_run` stores `err.toString()`. For `StateError` (the crypto stub, offline logout, "device must be linked") the user sees `Bad state: Production MLS/OpenMLS encryption is not integrated`. For `ApiException` the mapped `message` is better but still yields `Request failed (500).` for anything unmapped (duplicate username, channel kind, etc. — see LOG-10/LOG-11). Server error codes like `storage_error` are shown to end users.
- **Why it matters:** Raw exception text is developer-facing, sometimes leaks internals, and never tells the user what to do. This is the first thing a real user sees when anything goes wrong.
- **Recommended fix:** Introduce a user-facing error mapping layer (extend `ApiException.message` to cover all server codes; catch `StateError` from the crypto stub and show a "This build has no encryption support" notice). Never render `toString()` of an arbitrary error.
- **Blocker:** Yes for launch quality.

## UI-2 — No form validation feedback on auth fields

- **Severity:** High
- **Location:** `mobile/lib/features/auth/connect_screen.dart:83-161` (plain `TextField`s, no `Form`/`TextFormField`/validators)
- **Description:** Instance URL, username, password, invite code, and link code are all bare `TextField`s. There is no inline validation: empty username, sub-12-char password (server rejects with `weak_password` → "Request failed (400)"), malformed URL, or empty invite are only caught server-side and returned as opaque errors. Password rules are never communicated before submission.
- **Why it matters:** Registration/login is the funnel. Users must guess the password policy and re-submit against a round-trip to discover each rule. This is the highest-friction part of the whole app.
- **Recommended fix:** Wrap in a `Form`, add `TextFormField` validators (URL parseable, username charset per LOG-9, password ≥12 chars with a helper text, invite/link non-empty), disable submit until valid, and show field-level error text.
- **Blocker:** Yes for launch quality.

## UI-3 — Connect screen ignores setup status

- **Severity:** Medium
- **Location:** `mobile/lib/features/auth/connect_screen.dart:22` (defaults to `AuthMode.owner`), `mobile/lib/core/app_state.dart:59-64` (`connect()`/`setupStatus` exists but is never called — see LOG-23)
- **Description:** The screen opens in "Owner" mode regardless of whether the instance already has an owner. A joining user must know to switch to "Join"; picking the wrong mode yields `already_setup` or credential errors. The app already has a `setupStatus` probe but never uses it to steer the UI.
- **Why it matters:** First-run vs. join is a fork every user hits once, and the default is wrong for everyone except the very first person on an instance.
- **Recommended fix:** On URL entry/blur, call `setupStatus`; if setup is not required, hide/disable "Owner" and default to "Sign in"/"Join"; if required, show only "Owner". Wire up the existing `connect()`.
- **Blocker:** Yes for onboarding clarity.

## UI-4 — Inconsistent and mostly-absent loading states

- **Severity:** Medium
- **Location:** connect button spinner (`connect_screen.dart:172-176`) and send button spinner (`chat_screen.dart:310-317`) exist; but `ChatListScreen`, `CommunityScreen`, `SettingsScreen`, `ConversationDetailsScreen`, `DeviceLinkScreen`, `InviteScreen` show no loading indicator during their network calls — they render stale/empty content while `busy` is true
- **Description:** The global `busy` flag drives only two buttons. Cold-start hydration (`tryRestoreSession` → refresh conversations/devices) shows an empty chat list with the "No conversations yet" empty state until data lands, which reads as "you have nothing" rather than "loading".
- **Why it matters:** The empty state masquerading as a loading state actively misinforms; users may think their data is gone.
- **Recommended fix:** Distinguish "loading" from "empty" — show skeletons/spinners while first-load is in flight (needs a per-list loading flag; ties into LOG-24's global-state refactor).
- **Blocker:** No.

## UI-5 — Chat message load has no error/retry state

- **Severity:** Medium
- **Location:** `mobile/lib/features/chat/chat_screen.dart:82-90`, fed by `app_state.dart:525-529` (unawaited, uncaught — LOG-14)
- **Description:** If loading a conversation's messages fails, the pane shows the "No messages yet" empty state (or the previous conversation's cached list). There is no error banner and no retry.
- **Recommended fix:** Add a per-conversation error/retry state; show a retry button on failure.
- **Blocker:** No.

## UI-6 — Core actions require pasting raw account IDs

- **Severity:** High
- **Location:** `mobile/lib/features/chat/new_conversation_sheet.dart:85-95` (DM/group by account ID), `mobile/lib/features/chat/conversation_details_screen.dart:150-158` (add member by account ID)
- **Description:** Starting a DM or adding a member requires the user to obtain and paste a counterpart's opaque `acct_<32 hex>` ID. There is no people picker, no search-to-add, no contacts. The account ID is only discoverable by the other person copying it from Settings and sending it over some other channel.
- **Why it matters:** This is unusable as a consumer messaging flow. It is effectively a developer/testing affordance shipped as the primary "start a conversation" UI.
- **Recommended fix:** Build a people picker backed by the existing metadata search (`account` type), resolve usernames → IDs behind the scenes, and let users start a DM directly from a search result (ties to LOG-16). Keep raw-ID entry as an advanced fallback.
- **Blocker:** Yes for product launch (not for the foundation).

## UI-7 — Session-only records disappear on refresh

- **Severity:** Medium
- **Location:** `mobile/lib/features/settings/invite_screen.dart:99-111` ("No invites this session"), `mobile/lib/features/communities/community_screen.dart:10-12` (comment), `app_state.dart:34-37`
- **Description:** Invites and communities created in the current session are held only in memory because the server has no list endpoints for them. After an app restart (or the global-state clear on any logout), created invite codes and communities vanish from the UI. The warning ("copy the code before leaving") is easy to miss.
- **Why it matters:** A user creates a 25-use invite, backgrounds the app, comes back, and the code is gone with no way to look it up — the invite still works on the server but is unrecoverable from the client.
- **Recommended fix:** Add server list endpoints (`GET /invites`, `GET /communities`) and hydrate on load; until then, persist session-created records to secure storage and show a prominent "save this code now" affordance.
- **Blocker:** No (but data-loss-shaped).

## UI-8 — Chat list lacks unread state, previews, and activity ordering

- **Severity:** Medium
- **Location:** `mobile/lib/features/chat/chat_list_screen.dart:79-123` (tiles show title + static subtitle + created date)
- **Description:** Conversations are ordered by creation date (server `ORDER BY created_at DESC`), not last activity. Tiles show a static descriptor ("Direct message · Encrypted"), never a last-message preview or timestamp, and there is no unread badge. Read receipts exist server-side but drive nothing in the list.
- **Why it matters:** The chat list is the home screen; without recency ordering and unread cues it is unnavigable past a handful of conversations. (Message previews are blocked by LOG-0, but ordering and unread counts are not.)
- **Recommended fix:** Order by last message time; compute unread from the read-receipt cursor vs. latest message; add badges. Preview text waits on decryption.
- **Blocker:** No.

## UI-9 — Device-link screen has no QR rendering

- **Severity:** Medium
- **Location:** `mobile/lib/features/settings/device_link_screen.dart` (shows code/URI as copyable text; icon is `Icons.qr_code_2` but no QR is drawn), `mobile/lib/features/auth/connect_screen.dart:93-101` (link code typed manually)
- **Description:** The linking flow is entirely manual code entry despite QR iconography throughout. The server emits a `veritra://device-link?code=…` URI ready for a QR, but nothing renders or scans it. This is called out as Tier-3 work in `WORK_IN_PROGRESS.md`.
- **Why it matters:** Manual entry of a base32 code plus a 6-digit verification code across two devices is error-prone; QR is the expected UX and reduces mis-entry (which currently yields opaque errors).
- **Recommended fix:** Render the link URI as a QR (a small dependency) and add a camera scanner on the claiming device, including the key-fingerprint continuity check described in the plan.
- **Blocker:** Yes for the linking flow to be usable at consumer level.

## UI-10 — Missing manual refresh on several screens

- **Severity:** Low
- **Location:** `ChatListScreen` has `RefreshIndicator`; `CommunityScreen`, `InviteScreen`, `ConversationDetailsScreen` do not; `SettingsScreen` has a refresh action but only for devices
- **Description:** Inconsistent refresh affordances; users can't manually reconcile stale lists on screens without pull-to-refresh.
- **Recommended fix:** Add `RefreshIndicator` consistently once list endpoints exist.
- **Blocker:** No.

## UI-11 — Attachment button permanently disabled

- **Severity:** Low
- **Location:** `mobile/lib/features/chat/chat_screen.dart:290-296` (`onPressed: null`, tooltip "coming soon")
- **Description:** A visible-but-dead control. Honest, but it advertises a feature that has no timeline and can't be triggered. Fine as a placeholder; flagged so it isn't mistaken for a bug.
- **Recommended fix:** Keep disabled until attachments ship (blocked on LOG-0 + LOG-3), or remove until then.
- **Blocker:** No.

## UI-12 — Accessibility gaps

- **Severity:** Medium
- **Location:** icon-only `IconButton`s mostly have tooltips (good), but: the brand avatar and conversation `CircleAvatar`s carry no `Semantics` label; the `_StateChip` conveys link state by color+text (text present, OK); `RadioGroup` retention lacks a group label for screen readers; message bubbles announce only "Encrypted message" with no sender attribution for `TalkBack`/`VoiceOver`.
- **Description:** No evidence of screen-reader testing. Color contrast from the seed-generated scheme is likely fine, but semantic structure (headings, list semantics, image labels) is not set.
- **Why it matters:** Accessibility is a baseline production and often a legal requirement; retrofitting semantics later is costly.
- **Recommended fix:** Add `Semantics` labels to avatars/decorative icons, ensure dialogs and sheets have labeled fields, label the retention group, and run the Flutter accessibility checker + a manual TalkBack/VoiceOver pass.
- **Blocker:** No (but should precede a public launch).

## UI-13 — Raw crypto protocol string in message metadata line

- **Severity:** Low
- **Location:** `mobile/lib/features/chat/chat_screen.dart:257-264` (`_metaLine` appends `message.cryptoProtocol`)
- **Description:** Every bubble's meta line shows the raw protocol identifier (e.g., `test-only-not-production` today, `mls-…` later) next to the timestamp. That's debug info in the primary reading surface.
- **Recommended fix:** Drop it from the default view or replace with a lock icon + tap-for-details; keep the raw value in a details sheet.
- **Blocker:** No.

## UI-14 — UI accepts empty/short credentials

- **Severity:** Medium (overlaps UI-2)
- **Location:** `connect_screen.dart:211-232`
- **Description:** Submit is enabled with empty fields; `.trim()`ed empties are sent and bounced by the server. Password minimum (12) is never surfaced pre-submit.
- **Recommended fix:** Covered by UI-2 (validators + disabled submit).
- **Blocker:** No.

## UI-15 — No clear sent/failed feedback on messages

- **Severity:** Medium
- **Location:** `chat_screen.dart:105-122` (`_send`), message bubbles have no status indicator
- **Description:** `sendMessage` refreshes the list on success and shows a snackbar on error, but there is no per-message "sending/sent/failed" state, no optimistic bubble, and no resend. A message that fails leaves the composer cleared only on success — acceptable — but the user gets a transient snackbar and no persistent failed-message affordance.
- **Recommended fix:** Optimistic message insertion with a pending/failed status and a tap-to-retry, once real sending is wired (LOG-0).
- **Blocker:** No.

## UI-16 — `/setup` page is a non-actionable dead end

- **Severity:** Low
- **Location:** `server/websetup/index.html` (47 lines), `README.md:52` ("browser page is a setup notice only")
- **Description:** The setup URL renders a static notice that owner setup must come from a client capable of real crypto — which doesn't exist yet. An operator following the README lands on a page that tells them they can't proceed.
- **Recommended fix:** Once client crypto exists, either make `/setup` a real owner-creation form (it already has a CSP and CSRF guard header contract) or clearly point operators at the app. For now, ensure the copy states the exact prerequisite.
- **Blocker:** No.

## UI-17 — Search lacks clear button; results linger

- **Severity:** Low
- **Location:** `mobile/lib/features/search/search_screen.dart:79-97`
- **Description:** No clear (✕) affordance; clearing the field to empty resets `searched=false` (good) but there's no way to dismiss results without deleting text manually. Debounce is fine (350 ms).
- **Recommended fix:** Add a clear button in the search field suffix.
- **Blocker:** No.

## UI-18 — No profile / account screen

- **Severity:** Medium
- **Location:** `mobile/lib/features/settings/settings_screen.dart` (account section shows only an ID)
- **Description:** There is no display name, no avatar, no username shown to the user (only the account *ID*), no way to view or edit any profile info. Other users are also identity-less (see UI-6).
- **Why it matters:** Identity is fundamental to a messenger; "who am I / who is this" is currently unanswerable in-app.
- **Recommended fix:** Add a profile surface (username display, future display name/avatar) once the server returns account profile data; expose the current user's username (already known server-side) rather than only the ID.
- **Blocker:** No.

## UI-19 — Local timestamp parsing can throw / silently mis-order

- **Severity:** Low
- **Location:** `mobile/lib/core/models.dart:190,328-333` (`DateTime.parse`), `mobile/lib/ui/format.dart`
- **Description:** `ReceivedMessageEnvelope.createdAt` uses `DateTime.parse(json['created_at'])` with no fallback; a malformed timestamp throws during model construction, failing the whole list parse. Optional times swallow errors, but the required `createdAt` does not.
- **Recommended fix:** Parse defensively (tryParse with a sentinel + log) so one bad row can't blank the conversation.
- **Blocker:** No.

## UI-20 — Retention change is instant and unconfirmed

- **Severity:** Low
- **Location:** `mobile/lib/features/chat/conversation_details_screen.dart:88-107`
- **Description:** Selecting a retention radio immediately calls `setConversationRetention` with no confirmation. Given the semantics ambiguity (LOG-12), a user could believe they just scheduled deletion of existing messages. No undo.
- **Recommended fix:** Confirm the change and state clearly whether it affects existing messages.
- **Blocker:** No.

---

## Recommended UI Priorities Before Production

Ranked by user impact × likelihood-of-being-hit, assuming the crypto blocker (LOG-0) is resolved first (nothing below is reachable without it):

1. ~~**UI-2 + UI-14 — Auth form validation.**~~ **Done.** Every user passes through this; opaque round-trip failures were the biggest funnel leak.
2. ~~**UI-1 — Human-readable errors.**~~ **Done.** Kills the raw `StateError`/`Request failed (500)` experience everywhere at once.
3. ~~**UI-6 — People picker instead of raw account IDs.**~~ **Done.** The "start a conversation" flow was unusable for non-developers.
4. ~~**UI-3 — Setup-status-aware connect screen.**~~ **Done.** Fixed the wrong default mode that misdirected every joiner.
5. ~~**UI-9 — QR device linking.**~~ **Done.** QR rendering, camera scanning, and iOS camera permission copy are present; manual dual-code entry remains as a fallback.
6. ~~**UI-8 — Chat list recency ordering + unread badges.**~~ **Done (ordering + unread).** Home screen is navigable at scale; message previews still wait on decryption.
7. **UI-18 — Identity/profile surface + showing usernames** (pairs with UI-6). Fixed with the reachable profile identity surface; cryptographic verification stays release-gated.
8. ~~**UI-4 — Real loading states.**~~ **Done.** Per-list first-load spinners; UI-5's error/retry was already shipped.
9. **UI-12 — Accessibility pass** before any public/App Store release. Semantics groundwork in place; a manual TalkBack/VoiceOver pass remains.
10. ~~**UI-7 — Persist or list invites/communities**~~ **Done.** Created codes survive restarts via the list endpoints.

Lower priority polish: UI-10, UI-11, UI-13, UI-17, UI-19, UI-20.

Remaining open UI work is gated on crypto integration (LOG-0) — message previews (UI-8), send/failed status (UI-15), and attachments (UI-11).
