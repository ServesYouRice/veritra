# FABLE.md — Deep Audit Report

**Date:** 2026-06-10
**Status note, 2026-07-04:** this is a dated audit report, not live status. Use
`WORK_IN_PROGRESS.md` and `docs/TODO.md` for current tracking.

**Scope:** Full repo — Go server, Flutter client, Rust crypto boundary, schema, deploy, CI, docs.
**Method:** Static read of every source file. No toolchain was available on this machine (no Go, Cargo, Flutter, or Docker daemon), so tests/lints were **not** executed as part of this audit.
**Prior audits:** OPUS.md (2026-05-29) and CODEX.md (2026-05-30). Most of their findings landed in commits `39277d1`…`ff81b59`. This report focuses on what is **still open or newly found**; confirmed-fixed items are not repeated.

---

## Executive summary

The server is a carefully hardened ciphertext-envelope relay with a genuinely good privacy posture. The product around it is still not functional: crypto is a stub, and three *additional* missing pieces (key distribution, attachment download, client decrypt) mean the E2EE path can't work even after OpenMLS is wired. Two newly found defects will bite immediately in real deployment: the WebSocket ping/pong interop bug (realtime flaps every 30 s) and the missing trusted-proxy config in the shipped compose file (rate limiter throttles the whole instance as one client).

Top items by impact:

| # | Finding | Severity |
|---|---------|----------|
| B5 | Server never answers WS pings → Dart client drops the socket every 30 s, forever | Blocker |
| B6 | Compose + Caddy profile lacks `PRIVATE_MESSENGER_TRUSTED_PROXIES` → 10 logins/min **per instance**, not per IP | Blocker |
| B2 | No API to fetch another user's device key packages → E2EE unimplementable even with crypto wired | Blocker |
| B3 | Attachments and backups are write-only (no download/list endpoint) | Blocker |
| H1 | SQLite PRAGMAs applied to one pooled connection only → readers lack `busy_timeout`, writer can silently lose `foreign_keys=ON` | High |
| H2 | Idempotent message send has a check-then-insert race → retries can 500 | High |
| H5 | Account deletion retains username, email, key packages, messages, blobs indefinitely | High |
| D1 | `WORK_IN_PROGRESS.md` claims `last_seen_at` stamping landed — no code writes it | Drift |

---

## 1. Blockers

### B1 — E2EE crypto still entirely stubbed (known, tracked)
`main.dart:14` wires `UnavailableCryptoService`, which throws on `createDeviceKeyPackage()` and `encrypt()`. Owner setup, login-after-link, device-link claim, and send all fail before any network call. Server (`cryptoapi/cryptoapi.go`) and Rust (`crypto/rust/src/lib.rs`) are fail-closed stubs. Honestly disclosed in `docs/TODO.md` / `WORK_IN_PROGRESS.md` Tier 3. Everything below assumes this is the top of the queue.

### B2 — No key-distribution API (new finding, not in TODO.md)
To encrypt to a conversation, a sender must fetch the **other members' device key packages**. The only key endpoint is `GET /api/v1/devices/me` (`httpapi/api.go:42`). There is no `GET /accounts/{id}/key-packages`, no conversation-members-with-keys endpoint, and conversation creation returns no key material. Even with OpenMLS fully bound on the client, there is no way to establish a group. This is a missing API surface that should be designed alongside the crypto work — add it to `docs/TODO.md`.

### B3 — Attachments and backups are write-only
- `POST /api/v1/attachments` stores a blob; **no download route exists**. `uploads.LocalStore.Open` (`uploads/local.go:59`) is dead code. Recipients can never fetch attachment ciphertext.
- `POST /api/v1/backups` stores a backup; there is no list/get endpoint, so the recovery flow described in `docs/recovery.md` cannot be implemented client-side.
- Consequence: orphaned blobs also have no GC (see H4/H5).

### B4 — Client crypto interface has no decrypt
`CryptoService` (`mobile/lib/crypto/crypto_service.dart`) declares only `createDeviceKeyPackage()` and `encrypt()`. There is no `decrypt()`. The chat read path now exists (fixed since OPUS B2 — `listMessages`, `selectedMessages`, `ChatScreen` render), but it renders envelope metadata only and can never render content with this interface. Mirror the server's `cryptoapi.ClientCrypto` shape (encrypt + decrypt + key package).

### B5 — WebSocket ping/pong interop bug: realtime channel flaps every 30 s
- Server: `drainClientFrames` (`realtime/websocket.go:147-201`) reads client ping frames and **discards them without replying with a pong**. RFC 6455 §5.5.2 says a peer MUST answer a ping with a pong.
- Client: `sync_service.dart:61` sets `socket.pingInterval = 30s`. Dart's `WebSocket` closes the connection when a ping is not answered by a pong within the interval.
- Net effect: every connection dies ~30 s after connect, the client reconnects after backoff, repeats forever. Realtime appears to "work" in short manual tests and is permanently unstable in production — plus battery/network churn on mobile.
- Fix: in `drainClientFrames`, on opcode `0x9` read the payload and write a pong frame (`0x8A` + payload, masked-from-client payload unmasked before echo); coordinate writes with the sender goroutine (mutex or pong-request channel into the write loop).
- Also missing: close-frame echo before TCP close (clean close handshake), continuation-frame handling. Consider replacing the hand-rolled implementation with `github.com/coder/websocket` — this file is exactly the kind of protocol code where a maintained library earns its dependency.

### B6 — Shipped Caddy deployment breaks the rate limiter for all users
`deploy/docker-compose.yml` (caddy profile) does not set `PRIVATE_MESSENGER_TRUSTED_PROXIES`. Behind Caddy every request arrives from the proxy's container IP, so the limiter (`app/app.go:331`) buckets the **entire instance** as one client: 240 req/min total, **10 auth requests/min for everyone combined**. Two users logging in at once can start failing; one attacker can lock out all logins with 10 requests/min. Fix: set `PRIVATE_MESSENGER_TRUSTED_PROXIES` to the compose network subnet in the compose file, and document it loudly in `docs/deployment.md`. Same applies to the systemd + external-proxy path.

---

## 2. High-severity correctness/security

### H1 — SQLite PRAGMAs only apply to a single pooled connection
`storage.Open` (`storage/sqlite.go:78-117`) runs `PRAGMA foreign_keys=ON; busy_timeout=5000` via `ExecContext` — that executes on **one** connection from the pool. `journal_mode=WAL` persists in the DB file, but `foreign_keys` and `busy_timeout` are per-connection:
- Reader pool (4–16 conns): all but one connection have `busy_timeout=0` → spurious `SQLITE_BUSY` failures under write load (checkpoints), exactly when traffic is high.
- Writer (1 conn): if `database/sql` ever replaces that connection (driver error, ping failure), the replacement has `foreign_keys=OFF` → FK enforcement silently disappears on all subsequent writes.

Fix: encode pragmas in the DSN so every new connection gets them — modernc.org/sqlite supports `file:path?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)`. Add a regression test that opens >1 reader conn and asserts the pragma on each.

### H2 — Message idempotency is check-then-insert, races to a 500
`SaveMessageEnvelope` (`storage/sqlite.go:1020-1069`) does: prune expired → SELECT existing by `(sender_device_id, idempotency_key)` → INSERT. The read goes to the reader pool, the insert to the writer — no transaction spans them. Two concurrent retries (the precise scenario idempotency keys exist for: timeout + retry) both miss the SELECT, one INSERT hits `UNIQUE(sender_device_id, idempotency_key)` (`0001_init.sql`) and surfaces as 500 `storage_error`. Fix: catch the SQLite constraint-violation error code on insert and re-read the existing row as `duplicate=true`, or do the whole sequence on the writer in one transaction.

### H3 — `typing` endpoint has no membership check
`conversationSubroute` case `"typing"` (`httpapi/api.go:618-625`) publishes a typing event with the caller's account ID to all members of **any** conversation ID without verifying the caller is a member. Every sibling action (read-receipts, retention, messages, reactions, calls) checks membership. Conversation IDs are 128-bit random so blind abuse is impractical, but any ex-member or anyone who ever learned an ID can spoof presence indefinitely. One `IsConversationMember` call fixes it.

### H4 — Sessions, device links, and invites are never pruned
The sweeper (`app/app.go:110-146`) prunes messages, sync events, audit events — but:
- expired `sessions` rows accumulate forever (token hashes retained);
- expired/consumed `device_links` retain **claimed key packages and signing keys** indefinitely;
- expired invites and their codes persist.

Add all three to the sweep. For device links, null out `claimed_key_package`/`claimed_signing_key` on consume/expiry rather than waiting for row deletion.

### H5 — Account deletion retains nearly everything
`DeleteAccount` (`storage/sqlite.go:1586-1611`) deletes sessions and revokes devices, then soft-marks the account. Retained forever: username (also blocks re-registration of the name), email, device rows incl. key packages, all message envelopes, attachment rows + blobs on disk, backup blobs, push subscription endpoints (not even disabled), audit rows beyond the 30-day window. For a privacy-first product, "delete account" should at minimum: scrub email + username (replace with tombstone), disable push subscriptions, delete backup blobs and owned attachment blobs, and document what's retained and why (`docs/privacy.md` should match the behavior).

### H6 — Username and email are unvalidated
`register`/`createOwner` (`httpapi/api.go:102-255`) validate password, device name, key package — but not `username` (no length cap, no charset rule; a 900 KB emoji string within the 1 MB body limit is accepted and becomes a UNIQUE key) and not `email` (any string). Also, duplicate username registration surfaces as 500 `register_failed` instead of 409. Add: username `^[a-z0-9_.-]{2,32}$` (post-normalize), email RFC-shape check or drop the field entirely (it has no use — no verification, no recovery flow), and a distinct conflict error.

### H7 — Mobile sync catch-up fetches one page and stops
`_catchUpSyncEvents` (`app_state.dart:353-403`) fetches a single page (default limit 100) per trigger and does not loop while `events.length == limit`. After any offline period with >100 events, the client silently stays stale until enough *new* events trickle in to trigger more fetches. Compounded by the cursor being reset to 0 on every login (`app_state.dart:103,127`), so first sync replays all history 100 events at a time. Loop until a short page is returned.

### H8 — Offline cold start looks like logout
`tryRestoreSession` (`app_state.dart:64-90`) catches *any* failure — including plain network unavailability — and falls back to the connect screen. A user opening the app in airplane mode appears logged out. Distinguish auth failure (401 → clear) from transport failure (keep session, retry). Related: there is no local message cache at all (in-memory only), so the app is blank offline; if that's a deliberate privacy stance, document it — `docs/TODO.md` implies an encrypted cache is planned.

### H9 — `restore` safety probe doesn't work on Linux
`main.go:194-225`: the "is a server running?" check opens the `-wal` file `O_RDWR` and treats success as "not running". That's Windows sharing-violation semantics; on Linux (the actual Docker/systemd deploy target) the open **succeeds while the server runs**, and restore then deletes the live DB + WAL under it. Use a proper probe (e.g., `flock`/`LockFileEx` on a dedicated lockfile the server holds, or attempt `BEGIN IMMEDIATE` against the DB) or document restore as "container must be stopped" and remove the false reassurance.

---

## 3. Medium severity

| ID | Finding | Where |
|----|---------|-------|
| M1 | bcrypt `DefaultCost` (10); current guidance is cost ≥12 or argon2id (already available in `x/crypto/argon2`). The 72-byte cap is a bcrypt artifact argon2id would remove. | `auth/auth.go:29` |
| M2 | No per-account throttling or failed-login audit events — only per-IP 10/min. Distributed credential stuffing is unthrottled and invisible (no `session.login_failed` audit row). | `app/app.go`, `httpapi/api.go:163` |
| M3 | Static 30-day bearer tokens: no rotation, no idle timeout, no "list my sessions" endpoint (schema supports it). | `httpapi/api.go:149,189` |
| M4 | Rate-limiter saturation: when the 65,536-bucket map is full, **new** clients get 429 for up to a minute — an attacker with IP diversity (IPv6) can cheaply lock out fresh clients. Fixed-window also allows 2× burst at the boundary. Consider per-key LRU eviction + sliding window. | `app/app.go:297-363` |
| M5 | `ReadTimeout`/`WriteTimeout` 30 s vs 50 MB attachment / 100 MB backup uploads — slow links can't finish. Use per-route deadlines or rely on `ReadHeaderTimeout` + idle deadlines for upload routes. | `app/app.go:85-88` |
| M6 | No `Cache-Control: no-store` on API responses (tokens, invite codes, link codes traverse proxies). One line in `securityHeaders`. | `app/app.go:152` |
| M7 | `routeClass` doesn't normalize `/api/v1/devices/{id}` → raw device IDs land in request logs (privacy-safe-fields policy; also unbounded label cardinality). | `app/app.go:262-279` |
| M8 | Missing lifecycle endpoints the schema already supports: leave conversation / remove member, list conversation members, list+revoke invites (`invites.revoked_at` is write-never). | `httpapi/api.go` |
| M9 | `CreateChannel` kind is unvalidated in code; bad kind hits the DB CHECK and returns 500 `storage_error` instead of 400. | `storage/sqlite.go:783`, `httpapi/api.go:474` |
| M10 | `read_receipts.message_id` is `ON DELETE CASCADE` — pruning an expired message deletes the reader's cursor row entirely (read state regresses). Consider `SET NULL` + keeping `read_at`, or cursor-on-conversation. | `0001_init.sql` |
| M11 | Envelope responses/broadcasts expose `idempotency_key` and `sender_device_id` to all members — minor metadata, but neither is needed by recipients. | `domain/types.go:111` |
| M12 | `/metrics` is unauthenticated when enabled (counters only today, but it will grow). Bind-scope or token-gate it. | `app/app.go:73` |
| M13 | Mobile: no TLS pinning option; `HttpClient` defaults. For a self-hosted privacy product, offer optional SPKI pinning or at least surface cert details on first connect (TOFU). | `api_client.dart:8` |
| M14 | Sweeper reads `PRIVATE_MESSENGER_SYNC_EVENT_RETENTION_DAYS` directly via `os.Getenv` inside `app` instead of `config.Load` — config drift; `Config.InstanceName` is loaded and never used. | `app/app.go:112`, `config/config.go:29` |

---

## 4. Optimization notes

- **O1 — `containsPlaintextMessageKey` double-parses every message body** (`httpapi/api.go:693,1249`): full `json.Unmarshal` into `interface{}` then a second decode into the struct. At 1 MB bodies this doubles allocation on the hottest path. Cheaper: decode once into the typed struct with `DisallowUnknownFields` (which already rejects unknown top-level keys) and only deep-scan `crypto_metadata`/`attachment_refs` raw blobs.
- **O2 — Sync-event fan-out does 2 writes + 1 read per message** (`saveSyncEvent` + `RecordAuditEvent` + `ListConversationMemberIDs` on every send, all through the single writer). Fine at self-host scale; batch or cache member IDs (they change rarely) if throughput ever matters.
- **O3 — `PruneExpiredMessages` scans the whole table** every 6 h; there's no index on `expires_at`. Add partial index `WHERE expires_at IS NOT NULL`.
- **O4 — `ListMessages` cursor queries** use `(conversation_id, created_at)` index but order by `created_at, id` — fine today; make the index `(conversation_id, created_at, id)` to keep it covering.
- **O5 — Mobile rebuilds the whole MaterialApp** on any `notifyListeners` (single `AnimatedBuilder` at the root, `main.dart:34`). Fine for a shell; will need scoped listening (e.g. `ListenableBuilder` per screen or a state library) before real message volume.
- **O6 — `PutEncryptedBlob` doesn't fsync** before rename (`uploads/local.go:52`) — a crash can leave a DB record pointing at a missing/truncated blob. `file.Sync()` before close.

---

## 5. Best practices / modern patterns not respected

- **P1 — Hand-rolled WebSocket protocol** (see B5). The single riskiest "not-invented-here" spot in the repo, and it's also the one with **zero tests** (`realtime/` has no test file). If the no-dependency stance is firm, at minimum fuzz `drainClientFrames` and add a conformance test for ping/pong/close.
- **P2 — Inconsistent routing**: top-level routes use Go 1.22 method+pattern syntax (`GET /api/v1/devices/{id}`), while messages/conversations/communities/device-links use manual `strings.Split` subrouters (`httpapi/api.go:366,472,546,751`). Migrating to `mux.HandleFunc("POST /api/v1/conversations/{id}/typing", …)` removes ~80 lines of brittle parsing and the method-matching gaps.
- **P3 — `interface{}` everywhere instead of `any`** (~50 occurrences); Go 1.18+ codebase on Go 1.25.
- **P4 — AGENTS.md rule "storage … behind interfaces" is violated**: `httpapi.API` takes the concrete `*storage.Store`. Meanwhile `push.Provider`, `webrtc.SignalingService`, `cryptoapi.ClientCrypto` are interfaces **nothing implements or consumes** (dead until Tier 3). Either narrow per-handler interfaces for Store (helps the planned Postgres adapter) or amend the rule.
- **P5 — `decodeOptionalJSON` duplicates `readLimitedJSON`** body-reading logic (`httpapi/api.go:1219`); oversized bodies also return 400 `invalid_body` instead of 413 except on upload routes.
- **P6 — `parseTime` swallows parse errors** to zero time (`storage/sqlite.go:1876`) — corrupted rows become silent `0001-01-01` timestamps that still sort/paginate. Log or propagate.
- **P7 — Flutter lints**: `analysis_options.yaml` enables 3 ad-hoc rules; the standard is `package:flutter_lints` (or stricter `very_good_analysis`). Add it as a dev dependency.
- **P8 — Hardcoded device names** "Mobile device"/"Linked mobile device" (`app_state.dart:99,261`) — use the platform device model, or prompt.
- **P9 — CI gaps** (`.github/workflows/ci.yml`): no `permissions:` block (default token is write-capable), actions pinned by tag not SHA, no Go build cache, no `govulncheck`/`staticcheck`/`golangci-lint` despite `WORK_IN_PROGRESS.md` citing govulncheck cleanliness, no Docker image build check. Toolchain drift vs scripts: CI Rust `stable` / scripts `rust:1.82`; CI Flutter pinned `3.24.5` / scripts `flutter:stable`.
- **P10 — systemd unit** could add `ProtectHome=true`, `ProtectSystem=strict`, `CapabilityBoundingSet=`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `SystemCallFilter=@system-service`, `MemoryDenyWriteExecute=true`. Distroless Docker image is good; add `-trimpath -ldflags="-s -w"` and pin base images by digest.
- **P11 — Test blind spots**: no tests for rate limiter, security headers, request logger, realtime hub/websocket, retention sweeper, mobile `SyncService`, or concurrency (H2 would be caught by a parallel-send test). Server handler/storage tests that do exist are solid.

---

## 6. Documentation drift (docs say things the code doesn't do)

| ID | Claim | Reality |
|----|-------|---------|
| D1 | `WORK_IN_PROGRESS.md` Tier 1: "`devices.last_seen_at` stamped on each authenticated request, throttled to one write per device per minute" | **No code writes `last_seen_at`** — the column is only ever read (`storage/sqlite.go:504,722`). Either the feature regressed in `ff81b59` or never fully landed. Device list "last seen" will always be empty, which also weakens the lost-device review UX the field exists for. |
| D2 | `WORK_IN_PROGRESS.md` Tier 2: "when no `device_id` is provided, login picks the most-recently-active device" | Login now **requires** `device_id` (`httpapi/api.go:168`, test `TestPasswordLoginRequiresExplicitDeviceID`). The newer behavior is better; the log entry is stale and confusing. |
| D3 | `THIRD_PARTY_NOTICES.md`: modernc.org/sqlite "verify exact transitive notices during release" | Still unresolved; fine pre-release, but it's on the release checklist with no tracking issue. |
| D4 | `docs/recovery.md` / backup story | Server has upload-only backups (B3); the doc describes a flow that can't complete. |

Recommendation: add a "Reverted/changed since" section to `WORK_IN_PROGRESS.md` whenever a later commit alters a logged fix — two of its claims are now false, which undermines trust in the rest of the (otherwise excellent) log.

---

## 7. What's genuinely good (keep doing this)

- Ciphertext-first schema with `CHECK(length(ciphertext) > 0)`, plaintext-key rejection middleware, compact sync-event refs (no ciphertext duplication), metadata-only audit rows with explicit comments.
- Auth: hashed-only session tokens, constant-time dummy bcrypt on unknown users, explicit bcrypt-truncation rejection, device-bound sessions, revocation checked on every request.
- Device-link state machine: one-shot claim token via header, constant-time verification-code compare, sane TTL clamp, key material kept out of GET responses (`link.Code` cleared).
- Migration checksums with mismatch refusal; `VACUUM INTO` backups; fixed-width sortable timestamps; LIKE-escaping with `ESCAPE`; account search constrained to exact match with a clear rationale comment (the OPUS S1 enumeration fix is real and tested).
- Single-writer/reader-pool SQLite split is the right architecture for the self-host target (modulo H1).
- Mobile: secure-storage session, bearer-header WS auth, insecure-URL confirmation dialog, swallow-and-recover local-store corruption handling.

---

## 8. Suggested order of attack

1. **B5 + B6** — small fixes, immediately unbreak realtime + multi-user deployments.
2. **H1, H2, H3** — storage correctness trio; all are localized.
3. **H4 + H5** — data-retention sweep + real account deletion (privacy promise).
4. **H6–H9** — input validation, mobile sync loop, offline session, restore probe.
5. **B2/B3/B4 design** — key distribution + attachment download + client decrypt interface, designed together with the OpenMLS integration (B1) so the API isn't built twice.
6. Best-practice cleanups (P-series) opportunistically with the above.
