# Audit Plan — Veritra Production-Readiness Audit

Date: 2026-07-19
Auditor role: senior engineer / production-readiness reviewer
Scope: full repository at branch point `main` (b1c5a66). **Audit only — no production code was modified.**

## 1. Stack identified

| Layer | Technology | Notes |
|---|---|---|
| Server | Go 1.25/1.26 modular monolith, stdlib `net/http` (Go 1.22 pattern routing), custom WebSocket implementation | Single binary: `server/cmd/messenger-server` |
| Database | SQLite via `modernc.org/sqlite` (pure Go, CGO-free), WAL mode, 1 writer / N reader pools | 17 SQL migrations with checksum verification |
| Blob storage | Local filesystem (`server/internal/uploads`), encrypted blobs only | S3 deferred by design |
| Client | Flutter (Android/iOS), `ChangeNotifier` state (`AppState`), `flutter_secure_storage` persistence | No plaintext rendering yet — crypto fail-closed |
| Crypto | Rust crate (`crypto/rust`) — fail-closed OpenMLS boundary, ABI v2; `UnavailableCryptoService` on mobile | Production E2EE intentionally not wired |
| Push | Web Push (VAPID) server-side; UnifiedPush on Android; APNs/FCM deferred | Generic wake-only payloads |
| Deploy | Docker (scratch image, distroless-style), Docker Compose + Caddy, systemd unit | CI: GitHub Actions (Go race tests, Rust, Flutter, compose smoke, release artifacts) |
| Auth | bcrypt passwords + per-device secret, SHA-256-hashed bearer session tokens (30-day), Ed25519 enrollment proofs, invite-only registration | Recent-auth (5 min) gate for sensitive ops |

## 2. Core user flows

1. **Instance setup** — operator boots server → `/setup` notice page → owner enrollment reservation → Ed25519-signed owner creation (loopback or setup-token gated).
2. **Registration** — invite code → enrollment reservation → challenge signature → account+device+session.
3. **Login** — username + password + device ID + device secret (device must be pre-linked).
4. **Device linking** — QR/link code → claim → enrollment proof → out-of-band verification code → approval → claim-status polling → session.
5. **Messaging** — encrypted envelope POST (idempotency-keyed) → durable sync event → WebSocket fan-out → push wake → client catch-up via `/sync/events` cursor.
6. **Conversations** — DM / group / community channel creation, membership management, retention (disappearing messages), read receipts, reactions, typing.
7. **Attachments/backups** — encrypted blob upload/download with quota; client-encrypted backup blobs.
8. **Admin** — account list/suspend, invite revocation, audit-event browsing.
9. **Account lifecycle** — password change, logout-all, device revocation, export, deletion.

## 3. Audit method

- Read every Go file in `server/` (handlers, stores, app wiring, realtime, push, uploads, config, main/CLI) — ~11,300 lines.
- Read Flutter core (`app_state`, `api_client`, `local_store`, `sync_service`, crypto boundary, push) and every screen with UX significance (connect, chat list, chat, conversation details, new-conversation sheet, shell).
- Read all 17 migrations' schema surface (table inventory cross-checked against queries).
- Read deploy artifacts (Dockerfile, compose, Caddyfile, systemd unit), CI workflows, release gate scripts.
- Skimmed Rust crypto boundary (fail-closed by design; deep protocol review out of scope and already flagged in `REMAINING-WORK.md` as needing independent review).
- Cross-checked every SQL table reference against the migration schema (this caught the `conversation_members` bug).
- Traced proxy topology assumptions (RemoteAddr vs X-Forwarded-For) across rate limiter, WebSocket hub, and setup authorization.

## 4. Deliverables

| File | Contents |
|---|---|
| `ui-issues.md` | UI/UX findings + Recommended UI Priorities Before Production |
| `logical-issues.md` | Logic/data/async findings + Production Blockers section |
| `nice-to-haves.md` | Product/DX/architecture improvements, tiered |
| `security-issues.md` | Security-specific findings |
| `performance-issues.md` | Performance and scalability findings |
| `production-readiness.md` | Go/no-go checklist and fix ordering |
| `testing-gaps.md` | Test coverage gaps |
| `deployment-risks.md` | Deploy/ops-specific risks |

Severity scale: **Critical** (breaks core function or trust) > **High** (must fix before launch) > **Medium** (fix before or shortly after launch) > **Low** (schedule) > **Nice-to-have**.

## 5. Context that shapes every finding

The repository is explicit (README, `REMAINING-WORK.md`) that **production message crypto is not wired** and production is intentionally blocked behind fail-closed gates (`UnavailableCryptoService`, `PM_CRYPTO_UNAVAILABLE`, `scripts/release-readiness.sh`). This audit treats that as the known, documented Blocker #0 and focuses on everything *else* that must be true when the crypto lands — several of which are currently broken in ways the existing test suite does not catch.
