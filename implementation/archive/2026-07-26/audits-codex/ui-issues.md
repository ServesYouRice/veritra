# UI and UX Issues

**Audit date:** 2026-07-21  
**Production UI verdict:** No-go

## Scope and evidence

Reviewed every Flutter screen under `mobile/lib/features`, shared UI components, app state/models/API integration, seven mobile test files, platform configuration, and the embedded `/setup` page. The Flutter UI could not be rendered because it does not compile with the locked `mobile_scanner` API. Browser-based inspection of `/setup` was also unavailable, so that page was reviewed from its HTML and test contract. These are audit limitations, not evidence that the unrendered layouts are correct.

## Findings

### UI-01 — Messaging is intentionally unusable in the shipped app

| Field | Detail |
| --- | --- |
| Severity | Critical |
| Location | `mobile/lib/main.dart:19`; `mobile/lib/crypto/crypto_service.dart`; `mobile/lib/features/chat/chat_screen.dart:283-408` |
| Blocker before production | **Yes** |

**Description:** `main.dart` always injects `UnavailableCryptoService`. Sending fails closed, received ciphertext is never decrypted, and every bubble renders as “Encrypted message.”

**Why it matters:** The product's core user flow—reading and sending messages—does not work. The placeholder UI could also be mistaken for a transient error rather than a deliberate release gate.

**Recommended fix:** Package the reviewed Rust library for Android/iOS, implement the production `CryptoService`, restore and persist MLS state atomically, implement group lifecycle operations, then replace placeholder rendering with authenticated decrypted content and explicit corrupt/undecryptable states.

**Risks/dependencies:** Depends on the crypto integration, key-package API fix, protected local persistence, interoperability vectors, real-device testing, and independent review. Do not add a plaintext fallback.

### UI-02 — The mobile UI does not compile

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `mobile/lib/features/auth/qr_scan_screen.dart:83`; locked `mobile_scanner` 7.2.1 API |
| Blocker before production | **Yes** |

**Description:** `MobileScanner.errorBuilder` is supplied a three-argument callback, while the locked package expects two arguments. `flutter analyze` and `flutter test` both fail compilation.

**Why it matters:** No trustworthy app build, widget test run, emulator review, or release artifact can be produced from the audited commit.

**Recommended fix:** Update the callback to the locked API, add a widget compile test for `QrScanScreen`, then rerun analyze, tests, and Android/iOS release builds from clean environments.

**Risks/dependencies:** A package upgrade is an alternative but requires compatibility and license review. Keep `pubspec.lock` enforced in CI.

### UI-03 — Direct-message rows do not identify the other person

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `mobile/lib/features/chat/chat_list_screen.dart:206-217`; `server/internal/storage/community_store.go:865`; conversation response model |
| Blocker before production | **Yes** |

**Description:** Every DM is titled and subtitled “Direct message.” The conversation API does not return peer identity/display metadata, and repeated DM creation is allowed.

**Why it matters:** Users can easily open or send to the wrong conversation. That is a trust and privacy failure in a private messenger, not cosmetic polish.

**Recommended fix:** Define a privacy-reviewed conversation summary containing the DM peer's stable account ID and username, reuse one canonical DM per account pair, and render peer name, unambiguous avatar/initials, activity, and unread state.

**Risks/dependencies:** Requires API/model changes and a migration or deterministic lookup for existing duplicate DMs. Avoid leaking peer metadata outside shared membership.

### UI-04 — Older message history is unreachable

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `mobile/lib/core/app_state.dart:319-329`; `mobile/lib/features/chat/chat_screen.dart`; `GET /api/v1/conversations/{id}/messages` |
| Blocker before production | **Yes** |

**Description:** The client always fetches the default newest page and ignores `next_before`. There is no scroll-triggered loader, manual “load older” action, or pagination state.

**Why it matters:** Messages beyond the newest page appear lost even though the server retains them. Old edits/deletions can also remain invisible after catch-up.

**Recommended fix:** Implement cursor-based backward pagination, merge pages without duplicates, preserve scroll position, show initial/loading-more/retry/end states, and test histories larger than one page.

**Risks/dependencies:** Local storage must move away from the current single secure-storage JSON record before caching substantial history.

### UI-05 — Conversation membership management is incomplete and misleading

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `mobile/lib/features/chat/conversation_details_screen.dart`; `server/internal/httpapi/conversation_handlers.go:172-204`; conversation member routes |
| Blocker before production | **Yes** |

**Description:** The details screen cannot list members and offers no leave, remove, or role-management flow. “Add member” appears for DMs, allowing a two-party DM to become a group without a clear transition. Moderators are shown an Admin role option the server may reject.

**Why it matters:** Users cannot verify who can receive future ciphertext, remove a participant, leave an unwanted conversation, or understand authorization failures.

**Recommended fix:** Add scoped list/leave/remove/change-role endpoints with MLS commit coordination. Hide member controls for DMs, or require an explicit “convert to group” flow with a new conversation. Derive allowed roles from the actor's role and show member/crypto-roster state.

**Risks/dependencies:** Membership database state and MLS roster state must converge; server membership alone must never claim cryptographic removal.

### UI-06 — Blocking and other safety controls have no UI

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `mobile/lib/features/settings/settings_screen.dart`; `mobile/lib/features/chat/conversation_details_screen.dart`; `/api/v1/account/blocks` |
| Blocker before production | **Yes** |

**Description:** The backend supports block/list/unblock, notification mutes, export, and admin controls, but the app exposes none of these. There is no block/report-like safety action from a DM or profile.

**Why it matters:** A real user cannot stop abusive contact using the app, inspect block state, mute a noisy conversation, or obtain their export.

**Recommended fix:** Prioritize block/unblock from DM details and a blocked-accounts settings page. Then add per-conversation mute, paginated export with secure share/save handling, and role-gated admin screens.

**Risks/dependencies:** Block UI must explain local/server effects and must not imply deletion from another participant's device. Export handling can expose ciphertext and metadata if shared insecurely.

### UI-07 — Search promises unsupported results and has dead-end rows

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `mobile/lib/features/search/search_screen.dart:101-180`; `server/internal/storage/message_store.go:615-674`; `docs/api.md` search contract |
| Blocker before production | No, if copy and navigation are corrected before launch |

**Description:** The UI promises chats/conversations, groups, communities, and channels. The server searches accounts, communities, and channels only. Community results are inert; channel results are actionable only if a matching conversation is already loaded; account results always create another DM.

**Why it matters:** Search appears broken and can proliferate indistinguishable duplicate DMs.

**Recommended fix:** Align copy and result types with the API, add deterministic navigation for every returned type, reuse an existing DM, and either add scoped conversation-title search or stop promising it.

**Risks/dependencies:** Account search must remain exact-match to avoid user-directory enumeration. Conversation search must stay metadata-only.

### UI-08 — Community channel rows are duplicated and one copy cannot be opened

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `mobile/lib/features/communities/community_screen.dart:191-229` and `:48-100` |
| Blocker before production | No |

**Description:** Channels shown inside each community card are plain `ListTile`s without `onTap`. A second “Channels you are in” section below contains the working navigation.

**Why it matters:** The visually grouped channel list looks interactive but does nothing, while duplicate content adds noise and inconsistent behavior.

**Recommended fix:** Make the community-card channel rows the canonical navigation surface and remove or repurpose the duplicate section. Add empty/error/loading states per community.

**Risks/dependencies:** Channel-to-conversation mapping must be present before navigation; otherwise show a clear unavailable state.

### UI-09 — Password and conversation forms provide weak validation feedback

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `mobile/lib/features/settings/settings_screen.dart:331-378`; `mobile/lib/features/chat/new_conversation_sheet.dart`; `mobile/lib/features/auth/connect_screen.dart:359` |
| Blocker before production | No |

**Description:** The change-password dialog closes silently when confirmation or byte-length validation fails, with no inline error or success confirmation. Group creation permits an empty group with no title or members. One password error contains visible mojibake (`12â€“72`).

**Why it matters:** Users cannot tell whether a security-sensitive action succeeded, and accidental empty entities make the product feel unfinished.

**Recommended fix:** Use `Form` validators that remain visible in the dialog, revalidate both fields, show success, fix the UTF-8 source literal, and require a group name plus at least one other member unless a documented self-group is intentional.

**Risks/dependencies:** Validate password length in UTF-8 bytes to match bcrypt/server behavior; keep server-side validation authoritative.

### UI-10 — Realtime, offline, and push state is not understandable

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `mobile/lib/sync/sync_service.dart`; `mobile/lib/core/app_state.dart`; `mobile/lib/features/settings/settings_screen.dart:151-166` |
| Blocker before production | No |

**Description:** WebSocket reconnects happen silently, sync failures feed a shared error string, and the UI lacks offline/reconnecting/last-synced state. Push setup is reduced to one boolean/action and does not surface registration failure or clearly disclose missing iOS support.

**Why it matters:** Users cannot distinguish “securely queued,” “sent,” “offline,” “server unavailable,” or “push unavailable,” causing duplicate actions and loss of trust.

**Recommended fix:** Model connection and sync status explicitly, show a compact persistent offline/reconnecting banner, expose per-message delivery state, and present provider/platform-specific push status and repair actions.

**Risks/dependencies:** Status must be derived from durable sync/outbox facts, not optimistic socket state. Notification copy must remain generic.

### UI-11 — Supported message features have no interaction design

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `mobile/lib/features/chat/chat_screen.dart`; server edit/delete/reaction/reply/attachment/receipt routes |
| Blocker before production | No, after core messaging works |

**Description:** There are no accessible actions for edit, delete, react, reply/thread, attach, mute, typing, or receipt visibility even though parts of the server contract exist.

**Why it matters:** The messenger feels like a transport demo rather than a complete product, and server features remain unvalidated by real client behavior.

**Recommended fix:** After MLS messaging works, add a consistent long-press/overflow action sheet, optimistic but reversible states, encrypted attachment progress/retry, and clear edited/deleted/reply affordances.

**Risks/dependencies:** Each action must be authenticated inside the encrypted payload. Accessibility alternatives are required for gesture-only actions.

### UI-12 — The setup notice omits required operator safety guidance

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `server/websetup/index.html`; `server/websetup/websetup_test.go` |
| Blocker before production | **Yes**, because the test contract currently fails |

**Description:** The page remains form-free, but its committed safety test expects warnings that are absent: setup unavailable, keep the instance private, never use placeholder key packages, and configure `PRIVATE_MESSENGER_SETUP_TOKEN`.

**Why it matters:** First-run operators receive incomplete security guidance, and the server test suite fails.

**Recommended fix:** Reconcile page and test around one reviewed fail-closed message. Include an actionable setup-token/private-instance warning and link to deployment instructions without creating a browser crypto shortcut.

**Risks/dependencies:** Do not restore an owner-creation form until the browser can generate and protect production device keys.

### UI-13 — Tablet/desktop layout does not use available width

| Field | Detail |
| --- | --- |
| Severity | Low |
| Location | `mobile/lib/features/shell/home_shell.dart`; chat list/detail navigation |
| Blocker before production | No |

**Description:** Wide layouts show navigation rail treatment but still push chats as full-screen routes instead of a stable master-detail workspace.

**Why it matters:** Tablet use is functional but inefficient and visually sparse.

**Recommended fix:** Introduce a responsive breakpoint with conversation list and selected chat panes, preserve selection across width changes, and keep phone navigation unchanged.

**Risks/dependencies:** Requires state restoration and keyboard/focus testing.

### UI-14 — Accessibility coverage is structural, not verified

| Field | Detail |
| --- | --- |
| Severity | Low |
| Location | Flutter screens and `mobile/test`; dynamic message bubble semantics |
| Blocker before production | No |

**Description:** The code has useful `Semantics`, tooltips, headers, and decorative exclusions, but no automated semantics assertions, large-text/golden coverage, or documented TalkBack/VoiceOver review. The future decrypted bubble semantics are not designed yet.

**Why it matters:** Regressions in focus order, labels, contrast, scaling, and gesture alternatives will otherwise reach users unnoticed.

**Recommended fix:** Add semantics tests for core flows, test 200% text scale and narrow widths, run platform screen-reader checklists, and make every long-press action available through an explicit button/menu.

**Risks/dependencies:** Final checks must occur after message content and action controls replace placeholders.

## Recommended UI Priorities Before Production

1. **Restore a compiling mobile baseline** (`UI-02`) and keep analyze/tests green.
2. **Complete and independently review MLS mobile integration** (`UI-01`).
3. **Make DMs unambiguous and canonical** (`UI-03`).
4. **Implement message-history pagination and correct sync rendering** (`UI-04`).
5. **Complete safe member lifecycle and block controls** (`UI-05`, `UI-06`).
6. **Expose trustworthy offline, outbox, and push state** (`UI-10`).
7. **Repair search/community navigation and form feedback** (`UI-07`–`UI-09`, `UI-12`).
8. **Add message feature polish, responsive layout, and verified accessibility** (`UI-11`, `UI-13`, `UI-14`).

