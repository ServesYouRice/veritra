# UI Audit & Modernization Plan

Date: 2026-07-02
Scope: Flutter mobile client (`mobile/`) plus the server web setup notice (`server/websetup/`).
Note: this file lives in `docs/` because the repository root already contains `Plan.md`
(the original product brief); adding a root `plan.md` would collide on case-insensitive
filesystems (Windows/macOS), which this project explicitly supports.

## 1. Audit summary

### 1.1 What the server implements today

Enumerated from `server/internal/httpapi/api.go`:

| Area | Endpoints |
| --- | --- |
| Setup | `GET /setup`, `GET /api/v1/setup/status`, `POST /api/v1/setup/owner` |
| Auth | `POST /api/v1/auth/login`, `logout`, `logout-all`, `POST /api/v1/register` (invite-only) |
| Invites | `POST /api/v1/invites` (admin/owner) |
| Devices | `GET /api/v1/devices/me`, `DELETE /api/v1/devices/{id}` |
| Device links | create / claim / approve / claim-status / get |
| Communities | `POST /api/v1/communities`, `POST /api/v1/communities/{id}/channels` |
| Conversations | create (`dm`/`group`/`community_channel`, title, members, retention), list, add member, list messages (cursor), typing, read receipts, retention update |
| Messages | encrypted envelope create / edit / delete / reactions |
| Attachments | `POST /api/v1/attachments` (encrypted blobs) |
| Push | subscription create / delete |
| Calls | `POST /api/v1/calls` (signaling stub) |
| Sync | WebSocket + `GET /api/v1/sync/events` cursor catch-up |
| Search | `GET /api/v1/search/metadata` (metadata-only) |
| Account | export, delete; encrypted backups upload |

### 1.2 Implemented features with NO page in the mobile client

1. **Join with invite** — `POST /api/v1/register` exists; the connect screen only offers Owner / Sign in / Link. A new user with an invite code cannot join at all.
2. **Invite creation** — `POST /api/v1/invites` exists; there is no admin UI to mint an invite, so invite-only registration is unreachable end-to-end.
3. **New conversation flow** — the server accepts kind (`dm`/`group`), title, and `member_account_ids`; the UI has a single FAB that creates a bare untitled `group` with no members. No DM creation, no title, no member picker.
4. **Communities & channels** — `POST /api/v1/communities` and `POST /communities/{id}/channels` exist; the Communities tab is a static placeholder with two dead `ListTile`s.
5. **Conversation management** — add member (with role) and retention (disappearing messages) endpoints exist; no conversation details page.
6. **Metadata search** — `ApiClient.searchMetadata` is already written and covered by a test, but no screen calls it.
7. **Read receipts** — `ApiClient.markRead` is written but never invoked.
8. **Account deletion** — `DELETE /api/v1/account` exists; no UI.

### 1.3 Implemented features intentionally left without UI (blocked on client crypto)

`UnavailableCryptoService` throws for key packages and encryption, so any flow that
must produce ciphertext client-side cannot ship a functional page yet. These stay
out of scope, consistent with the project rule "no plaintext on the server":

- Message edit / delete / reactions (mutations must carry new ciphertext).
- Attachment upload (requires encrypted blob + key derivation metadata).
- Encrypted backups, account export download, calls (signaling stub only), push subscription management (needs platform push tokens).

### 1.4 Modernization problems in the current pages

- **Information architecture**: "Thread" is a bottom-nav tab; a conversation is a
  detail you navigate into, not a persistent tab. Selecting a chat in the list does
  not even switch tabs.
- **Branding/theme**: app title still "Private Messenger"; no dark theme, no
  `themeMode`, default typography, `useMaterial3` set manually (it has been the
  Flutter default for a long time).
- **Empty states**: bare centered icons with no copy or call to action.
- **Error handling**: raw `state.error` strings rendered inline in red; no snackbars.
- **Chat rendering**: encrypted envelopes rendered as `Card`+`ListTile` showing the
  crypto protocol string and the raw message ID — not a message bubble. No time
  formatting, no edited/deleted state (models already carry `editedAt`/`deletedAt`).
- **Chat list**: shows raw conversation IDs as subtitles, no kind distinction, no
  pull-to-refresh.
- **Settings**: single flat list mixing devices, actions, and disabled placeholders;
  device rows show raw IDs; destructive actions (revoke, sign out everywhere) have
  no confirmation.
- **No adaptive layout**: tablets get a stretched phone layout; Material 3 guidance
  is `NavigationRail` at medium+ widths.
- **Dead controls**: attach button in the composer does nothing.

## 2. Approach

Work happens only in the Flutter client (plus a light touch on the web setup page).
No server changes; the client keeps speaking the existing API contract. The
existing architecture (plain `ChangeNotifier` `AppState`, injected `ApiClient`,
`CryptoService`, `LocalStore`, `SyncService`) is sound and test-covered — keep it,
extend it; do not introduce a state-management dependency.

### 2.1 Foundation

- `lib/ui/theme.dart` — one seeded `ColorScheme` (existing brand teal `#126f7a`),
  light + dark `ThemeData`, shared shape/input/appbar themes; `themeMode: system`.
- `lib/ui/widgets/` — small shared widgets: `EmptyState` (icon + title + message +
  optional action), busy progress indicator wiring, error snackbar helper.
- `main.dart` — rename displayed title to Veritra, register light/dark themes.

### 2.2 Information architecture rework (`app_shell.dart`)

- Tabs become **Chats / Communities / Settings**; the thread tab is removed.
- Tapping a conversation pushes `ChatScreen` as a detail route.
- Adaptive navigation: `NavigationBar` under 720 px, `NavigationRail` above.

### 2.3 Remake existing pages

- **Connect screen**: onboarding layout (brand header, mode selector including the
  new *Join* mode, helper text per mode, busy state on submit, errors via snackbar).
- **Chat list**: conversation avatars by kind, titles with sensible fallbacks
  (never raw IDs), pull-to-refresh, real empty state, FAB opens the new
  conversation sheet, search action in the app bar.
- **Chat screen**: proper bubble layout (mine vs. theirs), day separators,
  time stamps, edited/deleted indicators, an explicit "encrypted envelope —
  client crypto pending" presentation for undecryptable payloads, modern pill
  composer, disabled attach affordance with an explanatory tooltip, best-effort
  read receipt on open, error snackbars.
- **Settings**: grouped sections (Account / Invites / Devices / Security / About),
  confirmation dialogs for destructive actions, device cards with created/last-seen
  times, danger zone with account deletion.
- **Device link screen**: stepper-style layout, copyable code/URI values, status
  chip; same flows as today.
- **Web setup notice** (`server/websetup/index.html`): small visual refresh only
  (typography, spacing, dark mode polish); it must stay a static no-JS notice.

### 2.4 New pages for implemented features

| Page | Backing endpoints |
| --- | --- |
| Join with invite (connect screen mode) | `POST /api/v1/register` |
| Invites screen | `POST /api/v1/invites` |
| New conversation sheet (DM / group, title, member IDs) | `POST /api/v1/conversations` |
| Communities screen (real): create community, create channel, list channel conversations | `POST /api/v1/communities`, `POST /communities/{id}/channels`, conversation list |
| Conversation details: metadata, add member with role, retention | `POST /conversations/{id}/members`, `PUT /conversations/{id}/retention` |
| Search screen | `GET /api/v1/search/metadata` |
| Account deletion (settings danger zone) | `DELETE /api/v1/account` |

Note: the server has no "list communities" or "list members" endpoints yet, so the
Communities page derives its content from `community_channel` conversations plus
communities created in-session, and the details page is write-only for membership.
Both are recorded as server-side TODOs rather than faked.

### 2.5 Data & state plumbing

- `models.dart`: add `Invite`, `Community`, `Channel`; extend `Conversation` with
  `communityId`, `channelId`, `retentionSeconds`, `createdAt` (all already in the
  server JSON).
- `api_client.dart`: add `register`, `createInvite`, `createCommunity`,
  `createChannel`, `addConversationMember`, `updateRetention`, `deleteAccount`.
- `app_state.dart`: expose the corresponding actions; mark-read on conversation
  open; keep every existing public member and behavior so current tests stay green.

### 2.6 Explicitly out of scope

- Anything requiring client-side crypto output (see 1.3).
- New Flutter dependencies (QR rendering, routing packages) — plain
  `MaterialPageRoute` and text codes keep the dependency surface unchanged.
- Server API changes.

## 3. Verification

- Extend `mobile/test/app_state_test.dart` (or siblings) with unit tests for the
  new models and `AppState` actions using the existing fake-client pattern.
- `flutter analyze` + `flutter test` via `scripts/lint.sh` / `scripts/test.sh`
  (Dockerized fallback) where the environment allows; otherwise noted in the PR.
- Manual smoke path: owner setup → invite → join → DM/group creation → send →
  search → device link → revoke → sign out.

## 4. Risks / notes

- The chat send path still fails at runtime by design (`UnavailableCryptoService`);
  the UI must surface that clearly instead of a stack-trace-ish string.
- Cursor pagination for messages exists server-side; the remade chat screen keeps
  single-page loading for now (follow-up: infinite scroll with `next_before`).
- Deriving community structure from conversations is a stopgap until list
  endpoints exist server-side.
