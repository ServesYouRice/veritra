# Nice-to-Haves — Product Completeness Audit

Judged as if real users were arriving next month. Items already filed as blockers elsewhere are cross-referenced, not repeated.

---

## High-impact nice-to-haves

| Item | Why it matters | Notes |
|---|---|---|
| **Display names + avatars** | Usernames are the only identity; no display name, no avatar, no profile fields. Trust and recognizability suffer (compare UI-1). | Keep privacy-first: avatars could be client-encrypted like attachments; display names are server metadata — decide the trade-off explicitly. |
| **Safety-number / key-verification UX** | An E2EE messenger without a way to verify peer keys invites MITM-by-server concerns — the audience for a self-hosted Signal alternative *will* ask. | Design now alongside MLS work (`REMAINING-WORK.md` already replaces server-issued link verification with local SAS — extend the same idea to conversations). |
| **Message search (client-side)** | Documented as deferred pending decryption + encrypted local index. Restating: users consider a messenger without search broken. | `docs/search.md` exists; keep it on the roadmap's front page. |
| **Admin reset / re-invite flow for locked-out members** | Filed as logical L-13 (blocker). Restated here because it needs *product* design (who approves? what does the user see?), not just an endpoint. | |
| **Leave / kick / member list** | Filed as logical L-12 (blocker). Product spec needed: does leaving delete history? Do kicked users see a tombstone? | |
| **Multi-account / multi-server support in the app** | `account_picker.dart` exists but the store persists exactly one session; self-hosting communities means users will belong to 2+ instances. | The `_identity()` session-swap logic already wipes state on account change — a session list is the natural next step. |
| **iOS notification story** | Without APNs, iOS users get zero background notification (UnifiedPush is Android-only). Even pre-APNs, an in-app banner explaining this (UI-10) preserves trust. | APNs work is tracked; the honesty banner is cheap. |
| **Retry-After + client backoff on 429** | Server rate limits exist but responses lack `Retry-After`, and the mobile client treats 429 like any error. | Small change, prevents accidental self-DoS from sync loops. |

## Product polish

- **Invite UX**: invites are codes only — add a shareable `veritra://` invite URI + QR (device linking already has this pattern in `deviceLinkPayload`).
- **Conversation muting UI** (server support exists; UI-10).
- **Drafts**: composer text is lost on navigation; persist per-conversation drafts locally.
- **Message timestamps grouping**: present (day separators) — add "sending…"→"sent" tick states once delivery states exist.
- **Empty-state CTAs**: chat-list empty state could deep-link to "invite someone" for owners (currently text-only).
- **Connect screen**: remember last-used instance URL (it does via session, but only after successful auth); autofill from QR scan for join/invites too.
- **Web client**: the server is browser-hostile today (no CORS, cookie-less bearer auth) — deliberate, but a read-only admin web UI would relieve UI-13 without touching E2EE.
- **In-app "What's my role / storage usage"**: quota errors (`storage_quota_exceeded`) surface with no way to see usage; expose per-account usage (admin store already computes it).

## Developer experience improvements

- **Schema-touch test harness** (testing T-2) — one migrated in-memory DB exercising every store method; the single highest-leverage test in the repo.
- **OpenAPI spec** for the HTTP API; generate the Dart client to kill contract drift (T-7). The route table in `api.go` is already clean enough to annotate.
- **`docs/api.md`** — there is no endpoint reference at all; contributors reverse-engineer from handlers.
- **Makefile targets** beyond the current minimal one (`make test`, `make lint` exist via scripts; add `make e2e`, `make fuzz`).
- **Structured error catalogue**: error codes (`invalid_enrollment`, …) are string literals scattered across handlers; centralize with comments so client authors have one list.
- **Coverage gate in CI** (already planned in `REMAINING-WORK.md`).
- **Devcontainer / `flake.nix`** for contributors without Docker.
- **Delete dead code** listed at the bottom of `logical-issues.md`.

## Architecture / stack recommendations

- **Keep** the modular monolith + SQLite + single-binary shape — it matches the self-hosting audience and the code respects the module boundaries (`AGENTS.md` rules are actually followed).
- **Replace the bespoke WebSocket parser** with `github.com/coder/websocket` (MIT) or fuzz it hard (security S-2). This is the one place the "boring, small" rule was broken.
- **Mobile local persistence**: move cache/outbox from a single secure-storage JSON value to an encrypted SQLite DB (fixes logical L-3 + performance P-6 in one refactor). Keep only keys/session in Keychain/Keystore.
- **Sync events**: add a typed `subject_account_id` column instead of `json_extract` visibility filtering (performance P-5) *before* the table accumulates history — it's a painless migration now.
- **Postgres/S3 adapters**: agree with the ADR to defer; the `uploads.Store` interface and `dbRouter` seam are already in the right shape for it.
- **Consider NATS/embedded queue — not needed.** The hub + durable-sync-event design is the right call; resist adding infrastructure.

## Future roadmap ideas

- Encrypted link previews (client-generated, envelope-embedded).
- Voice notes as encrypted attachments (streaming UI later).
- Moderation tooling for communities: report message (envelope reference without content), member freeze — designable without breaking E2EE if reports are client-initiated re-encryption to moderators.
- Federation is explicitly out of scope in ADR-0001; revisit only after single-instance product-market fit.
- Import from Signal/WhatsApp export formats into the encrypted local store (client-side only).
- Post-quantum readiness note: MLS ciphersuite is pinned (`MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`) in three places (Rust, Go const ×2) — centralize before adding suites.
