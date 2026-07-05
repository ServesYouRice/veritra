# Veritra Production-Readiness Audit (audits-fable)

**Date:** 2026-07-05
**Auditor:** Claude (Fable 5), acting as senior engineer / production-readiness auditor
**Scope:** Full repository at commit `c939f26` (branch `main`, clean tree)
**Mode:** Inspection only — no production code was modified.

---

## 1. Stack identification

| Layer | Technology | Notes |
|---|---|---|
| Server | Go 1.25 modular monolith (`server/`), stdlib `net/http` (Go 1.22 pattern mux), single binary | Subcommands: `serve`, `init`, `migrate`, `backup`, `restore`, `doctor`, `healthcheck` |
| Database | SQLite via `modernc.org/sqlite` (pure Go, CGO-free), WAL mode, single-writer + bounded reader pool | Migrations embedded, SHA-256 checksummed |
| Realtime | Hand-rolled WebSocket server (`internal/realtime`) + DB-backed `sync_events` catch-up | Best-effort push, durable catch-up contract |
| Auth | Username + bcrypt password, opaque 30-day bearer tokens (SHA-256 hashed at rest), device-link claim/approve/consume flow | Invite-only registration; password login requires a pre-linked `device_id` |
| Crypto | **Intentionally absent.** `cryptoapi.UnavailableProductionCrypto` (server), `UnavailableCryptoService` (mobile), Rust stub that fails closed (`crypto/rust`) | Server stores ciphertext envelopes only and actively rejects plaintext-shaped payloads |
| Mobile | Flutter 3.24 client shell (`mobile/`), single dependency (`flutter_secure_storage`), ChangeNotifier state | **No `android/`/`ios/` platform folders exist** — not currently buildable for a device |
| Blobs | Local filesystem store (`internal/uploads`), encrypted-upload header contract | No download endpoints exist |
| Push | Interface only; `DisabledProvider` returns error | No APNs/FCM/UnifiedPush |
| Calls | Signaling records only (`call_sessions`); no media path | Pion/LiveKit named as candidates |
| Deploy | Dockerfile (distroless, nonroot), docker-compose + Caddy TLS profile, systemd unit | CI: Go test/vet/gofmt, cargo test/clippy, flutter test/analyze, license check |

## 2. Core user flows (as implemented)

1. **First-run setup** — operator starts server → `/setup` notice page → owner account must be created from a client that can generate a real device key package (currently impossible; see blockers).
2. **Invite → join** — owner/admin mints invite code → new user registers with invite + username + password + device key package.
3. **Sign in** — password login on an already-linked device (`device_id` required).
4. **Device linking** — existing device creates link code → new device claims → user compares 6-digit verification code → approve → new device polls claim-status for a session.
5. **Messaging** — create DM/group/community-channel conversation → send encrypted envelope → members receive via WebSocket + `/sync/events` catch-up → read receipts, reactions, edit/delete markers, disappearing-message retention.
6. **Communities** — create community → create channels → open channel conversations.
7. **Account lifecycle** — invites, device list/revoke, logout / logout-others, metadata search, account export, account delete.

## 3. Audit plan (executed)

1. Map repository structure; read all prior audit docs (`FABLE.md`, `OPUS.md`, `CODEX.md`, `Plan.md`, `WORK_IN_PROGRESS.md`) to understand what was already fixed — this audit reports the **current** state only.
2. Read the full server surface: route table (`httpapi/api.go`), storage layer (`storage/sqlite.go`), app wiring / middleware (`app/app.go`), auth, config, realtime hub + WebSocket implementation, uploads, push/webrtc/cryptoapi stubs, CLI (`main.go`), all four SQL migrations, embedded setup page.
3. Read the full mobile client: state (`app_state.dart`), API client, sync service, secure store, crypto stub, models, and every screen (connect, chat list, chat, details, new-conversation, communities, search, settings, invites, device link), plus theme/format helpers.
4. Read deployment artifacts (Dockerfile, docker-compose, Caddyfile, systemd unit) and CI workflow; count and skim tests.
5. Cross-check client ↔ server contracts (field names, enum values, status codes, pagination params) for mismatches.
6. Trace authorization on every mutating endpoint (who can call it, against which resource).
7. Classify findings by severity and write them to per-topic files (below), with a recommended fix order.

## 4. Audit files

| File | Contents |
|---|---|
| [ui-issues.md](ui-issues.md) | UI/UX findings + Recommended UI Priorities Before Production |
| [logical-issues.md](logical-issues.md) | Logic, async, state, data-handling findings + Production Blockers list |
| [security-issues.md](security-issues.md) | AuthZ/AuthN, abuse, privacy findings |
| [performance-issues.md](performance-issues.md) | Efficiency and scalability findings |
| [production-readiness.md](production-readiness.md) | Deployment, ops, backup/restore, observability readiness |
| [testing-gaps.md](testing-gaps.md) | Coverage analysis and missing test classes |
| [nice-to-haves.md](nice-to-haves.md) | High-impact nice-to-haves, polish, DX, architecture, roadmap |

Finding IDs are stable across files: `UI-n`, `LOG-n`, `SEC-n`, `PERF-n`, `OPS-n`, `TEST-n`, `NTH-n`.

## 5. Overall verdict

**The project is not production-ready, and — importantly — it is honest about that.** The engineering quality of what exists is well above typical MVP level (fail-closed crypto boundary, checksummed migrations, careful WebSocket hardening, constant-time auth paths). But three realities dominate:

1. **The product does not function end-to-end.** With `UnavailableCryptoService` wired into `main.dart`, a user cannot create an owner, register, link a device, or send a message from the shipped app. Every flow that needs a device key package or encryption throws. This is a deliberate boundary, but it means "production readiness" today is about the *foundation*, not the product.
2. **A handful of real defects exist in the working code** — a conversation role-demotion authorization hole (SEC-1), a client/server enum mismatch that breaks channel creation 100% of the time (LOG-1), a WebSocket keepalive protocol violation that makes the realtime connection churn (LOG-2), and a missing-membership check on typing events (SEC-2).
3. **Operational abuse controls are missing** — no storage quotas on 50–100 MB uploads, write-only blob storage, no per-account resource limits.

## 6. Recommended fix order

1. **SEC-1** — role demotion via member re-add upsert (small fix, real authz hole).
2. **SEC-2** — membership check on `typing` endpoint (one-line guard).
3. **LOG-1** — channel `kind` mismatch (`text` vs CHECK constraint) + server-side kind validation.
4. **LOG-2** — server must answer WebSocket pings with pongs (realtime stability).
5. **LOG-3 / SEC-4** — storage quotas + blob download endpoints (or disable upload endpoints until they exist).
6. **LOG-5** — 401 handling / session-expiry flow in the mobile app.
7. **UI-1..UI-4** — error-message hygiene, form validation, actionable search results, sync-driven member updates.
8. Then the **Tier-3 platform work** (production E2EE, push providers, QR linking, platform folders) tracked in `WORK_IN_PROGRESS.md` — these are the true launch gates and are weeks of work each.

Everything else in these files is ranked within its own document.
