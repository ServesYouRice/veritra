# Audit plan

Written **before** the findings, as the record of what was inspected and how.

---

## 1. What this project is

Veritra is an AGPL-3.0-or-later, self-hostable, privacy-first messenger. One
product, one repository, three components.

### Stack inventory

| Layer | Technology | Version pin | Size |
| --- | --- | --- | --- |
| Server | Go modular monolith | `go 1.25.12` (go.mod); Docker builds `golang:1.26.4` | 15.3k LOC, 63 `.go` files |
| Database | SQLite via `modernc.org/sqlite` (pure Go, no cgo) | WAL, 1 writer conn / 4–16 reader conns | 23 forward migrations |
| Blob storage | Local filesystem, flat directory | — | `internal/uploads/local.go` |
| Realtime | **Hand-rolled** RFC 6455 WebSocket over `http.Hijacker` | no external WS library | `internal/realtime/` (~520 LOC) |
| Mobile | Flutter | SDK `>=3.4.0 <4.0.0`, CI pins Flutter 3.44.0 | 20.5k LOC Dart (16k hand-written + 4.5k generated) |
| Local DB | `drift` 2.34.3 + `sqlite3` 3.5.0 with the `sqlite3mc` hook, ChaCha20 | exact pins per decision **D01** | `storage/encrypted_database.dart` |
| Key storage | `flutter_secure_storage` ^10.3.1 | 256-bit random hex DB key | `storage/local_store.dart` |
| Crypto | Rust + OpenMLS `=0.8.1`, ciphersuite `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` | Rust 1.90.0, C ABI v4 | 2.3k LOC, 5 source files |
| Calls | `flutter_webrtc` 1.6.0, DTLS-SRTP, operator TURN | — | `calls/call_service.dart` |
| Push | WebPush (VAPID) / FCM / APNs, generic wake payload only | — | `internal/push/` |
| Deploy | Docker Compose (+ Caddy profile), systemd unit, scratch-base image | Caddy pinned by digest | `deploy/` |
| CI | GitHub Actions, 6 jobs, all actions SHA-pinned | — | `.github/workflows/` |

### Authentication model

Three-factor-ish and unusual, so worth stating explicitly because several
findings depend on it:

- **Password** (bcrypt, `DefaultCost`, 12–72 byte bound) — `internal/auth/auth.go`
- **Device secret** — a second 256-bit bearer secret issued at enrollment,
  required alongside the password on `POST /api/v1/auth/login`
- **Device key package + Ed25519 signing key** — bound into an enrollment
  challenge, verified server-side before an account or device can exist
- **Session token** — 256-bit random, SHA-256-hashed at rest, 30-day expiry
- **`withRecentAuth`** — a 5-minute re-authentication window gating destructive
  operations (device revoke, logout-all, password change, account delete,
  invite revoke, device-link approve)

There is no OAuth, no SSO, no email verification, and no password reset flow —
recovery is offline (`reset-owner-password`) or via capability-based encrypted
backup.

### The crypto gate

`main.dart:19` wires `UnavailableCryptoService()`; `crypto/rust/src/lib.rs` has
three legacy entry points returning `PM_CRYPTO_UNAVAILABLE`;
`scripts/release-readiness.sh` greps for both and exits 1. This is intentional
and must not be bypassed. It means:

- No message can actually be sent or read end-to-end today.
- Owner setup cannot complete from any shipped client (no real key package).
- Reply/edit/delete/reactions/attachments/safety-numbers are unreachable UI.

**Audit consequence:** the message *transport* path is fully reviewable
(envelopes, sync, outbox, storage) but the *decrypted rendering* path is not
exercisable. Findings about it are structural, not observed.

---

## 2. Core user flows identified

Traced from `ConnectScreen` → `AppShell` → server route table, and used to scope
the review.

| # | Flow | Entry point | Server routes | State |
| --- | --- | --- | --- | --- |
| F1 | **First-owner setup** | `ConnectScreen` (`AuthMode.owner`), `/setup` page | `/setup/status`, `/setup/owner/enrollment`, `/setup/owner` | Blocked by crypto gate |
| F2 | **Join with invite** | `ConnectScreen` (`AuthMode.join`) | `/register/enrollment`, `/register` | Blocked by crypto gate |
| F3 | **Sign in** | `ConnectScreen` (`AuthMode.signIn`) | `/auth/login` | Works, but needs a stored device secret — see [U3](ui-issues.md#u3) |
| F4 | **Link a second device** | `DeviceLinkScreen` + `QrScanScreen` | `/device-links*`, `/device-links/{id}/claim-status` | Works; SAS derived locally |
| F5 | **Start DM / group** | `NewConversationSheet` → `AccountPicker` | `/conversations`, `/search/metadata` | Works |
| F6 | **Send / receive** | `ChatScreen` composer → durable outbox | `/messages/envelopes`, `/sync/ws`, `/sync/events` | Envelope path works; bodies opaque |
| F7 | **History pagination** | `ChatScreen` reverse `ListView` | `/conversations/{id}/messages?before=` | Works |
| F8 | **Roster / moderation** | `ConversationDetailsScreen` | `/conversations/{id}/members*` | Works |
| F9 | **Block / mute / retention** | Details + settings | `/account/blocks*`, `/notifications`, `/retention` | Works |
| F10 | **Communities & channels** | `CommunityScreen` | `/communities*` | Works |
| F11 | **Invites** | `InviteScreen` | `/invites*` | Works |
| F12 | **Push wake → catch-up** | `PushService` → `_catchUpSyncEvents` | `/push/*`, `/sync/events` | Implemented; untested on hardware |
| F13 | **Attachments** | — | `/attachments*` | Server complete, **no client UI** |
| F14 | **Backup & recovery** | — | `/backups*`, `/recovery/{token}` | Server complete, **no client UI** |
| F15 | **Calls** | `CallService` | `/calls*` | Implemented, gated, platform config incomplete |
| F16 | **Admin** | — | `/admin/*` | Server-only; **no client UI at all** |
| F17 | **Operator lifecycle** | CLI | `serve`/`migrate`/`doctor`/`backup`/`restore` | Works |

Flows **F13, F14, F16** are server capabilities with no user surface. That is a
deliberate consequence of the crypto gate for F13/F14, but **not** for F16 —
admin is unblocked and simply unbuilt. See [nice-to-haves.md](nice-to-haves.md).

---

## 3. Method

Static review. No code executed, no toolchain run, no server started — the aim
was to inspect and reason, and the board already records a verified 2026-08-08
run of `flutter analyze`, `flutter test` (79 pass / 2 skip), `gofmt`, `go vet`,
and `go test ./...` against this exact tree.

Passes performed, in order:

1. **Orientation** — `README.md`, `AGENTS.md`, `docs/board.md`,
   `docs/overview.md`, `docs/design.md`, `docs/operations.md`, git history and
   working-tree state.
2. **Server surface** — full read of the route table (`httpapi/api.go`, 66
   routes), then every handler file, then middleware (`app/app.go`: rate limit,
   metrics, security headers, route timeouts, retention sweeper).
3. **Server data layer** — `storage/sqlite.go`, `message_store.go`, quota
   enforcement in `content_store.go`, `uploads/local.go`, all 23 migrations
   scanned for schema-level defaults and constraints.
4. **Concurrency** — `realtime/hub.go` and `realtime/websocket.go` read line by
   line for lock scope, goroutine lifetime, channel close discipline, and frame
   parsing.
5. **Mobile core** — `main.dart`, `app_shell.dart`, `core/app_state.dart` (1,916
   lines, read in full), `core/api_client.dart`, `storage/local_store.dart`,
   `storage/encrypted_database.dart` cap behaviour.
6. **Mobile UI** — every screen in `features/`, plus `ui/tokens.dart`,
   `ui/theme.dart`, `ui/format.dart` and the new shared widgets, read against
   `docs/design.md` §1–§8.
7. **Accessibility** — WCAG 2.1 contrast ratios recomputed by hand from the
   token hex values for both SC 1.4.3 (text) and SC 1.4.11 (non-text). Semantics
   annotations, tap targets, and text-scale behaviour reviewed per widget.
8. **Platform config** — `AndroidManifest.xml`, `Info.plist`, `pubspec.yaml`
   against the feature set the board says is in release scope.
9. **Crypto boundary** — `crypto/rust/` reviewed for FFI ownership and unwind
   safety only. **The MLS protocol itself was not audited** — see §5.
10. **Supply chain and release** — `.github/workflows/`, `scripts/`,
    `deploy/`, `Dockerfile`, toolchain pins, `THIRD_PARTY_NOTICES.md`.

### Verification standard

A finding is reported only if it is verifiable from a specific line of code.
Where a claim depends on runtime behaviour that was not executed, the finding
says so. Contrast ratios were computed from the sRGB relative-luminance formula
rather than asserted.

---

## 4. Deliberately excluded from the findings

These are known and correct, and are **not** reported as defects:

- **The crypto gate itself.** `PM_CRYPTO_UNAVAILABLE` and
  `UnavailableCryptoService` are working as designed.
- **Crypto-gated UI being unavailable** (reply, edit, delete, reactions,
  attachments, safety numbers, decrypted rendering). The board lists these.
- **Open cards I24, I25, I27.** Signing, hardware, TURN, push credentials, the
  upstream OpenMLS/HPKE advisories, and the independent reviewer are already
  tracked and externally blocked.
- **Explicit out-of-scope decisions**: federation, PostgreSQL, S3, NATS,
  multi-node, desktop (Phase 2), embedding (Phase 3).
- **Absence of golden tests** as a *design* choice — but the *risk* it creates
  for the uncommitted visual rebuild is reported in
  [production-readiness.md](production-readiness.md#r6).

Where a finding overlaps an open card, it says so and adds only the part the
card does not already cover.

---

## 5. Limits of this audit

State these before reading the findings:

- **This is not a cryptographic review.** MLS group semantics, the OpenMLS
  integration, the VAP1 payload format, key schedule handling, and the
  revocation protocol were **not** analysed for cryptographic soundness. That is
  card **I25** and requires a qualified independent reviewer. Nothing here
  should be read as clearing that gate.
- **Nothing was executed.** No test run, no build, no server start, no device.
  Findings about runtime behaviour (allocation, latency, lock contention) are
  reasoned from code, not measured. They say where to measure.
- **No rendering was observed.** The visual rebuild was reviewed as source and
  as computed colour values. `flutter test` proves the screens build; neither it
  nor this audit proves they *look* right. The board says the same.
- **No physical device.** Push wake, TURN traversal, CallKit, background
  lifecycle, TalkBack and VoiceOver were reviewed as configuration, not
  behaviour.
- **`docs/archive/` was not loaded** beyond confirming that two earlier audit
  passes (`audits-codex`, `audits-fable`) exist. Overlap with them is possible
  and was not deduplicated. Where a finding is still live in the current tree it
  is reported regardless of whether a prior pass also saw it.
- **Generated code** (`encrypted_database.g.dart`, 4,568 lines) was read only
  where a hand-written call site depended on its behaviour.

---

## 6. Severity scale

| Severity | Meaning |
| --- | --- |
| **Critical** | Silent data loss, or a security failure with no user-visible signal. Fix before any release. |
| **High** | A user or operator will hit this in normal operation and it will lose data, wedge a device, or break a release guarantee. Fix before general availability. |
| **Medium** | Degrades the product or costs real capacity; fixable in a normal cycle. |
| **Low** | Correct to fix, low consequence, safe to batch. |
| **Nice-to-have** | Product completeness, not a defect. |
