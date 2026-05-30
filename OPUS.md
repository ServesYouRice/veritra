# Veritra — Deep Audit Report

**Date:** 2026-05-29
**Scope:** Full repository — Go server (`server/`), Flutter client (`mobile/`), Rust crypto boundary (`crypto/rust/`), deployment + CI.
**Method:** Read of all source in the three components plus infra and the project's own status docs (`WORK_IN_PROGRESS.md`, `docs/TODO.md`, `Plan.md`).

This audit is deliberately blunt. The codebase is described by its own docs as an "MVP foundation," and that framing is accurate: the *server* is a thoughtfully-hardened metadata/envelope relay, but the *product* (an end-to-end encrypted messenger) does not yet exist as a working system. The single most important fact below is in **Blocker B1**.

---

## Executive Summary

- **B1 — There is no working messaging path, end to end.** The entire E2EE layer is an unimplemented stub on all three platforms (`cryptoapi.UnavailableProductionCrypto`, Dart `UnavailableCryptoService`, Rust `pm_crypto_available() == -1`). `main.dart` wires `UnavailableCryptoService()`, whose `createDeviceKeyPackage()` *throws*. That means **owner creation and login throw before any network call** — the shipped app cannot even register, let alone send a message. This is acknowledged in the docs but it makes the client non-functional today, not merely incomplete.
- **B2 — The client has no message read path at all.** [chat_screen.dart](mobile/lib/features/chat/chat_screen.dart) renders a single lock icon; there is no message list, no fetch of `/conversations/{id}/messages`, no decryption, no rendering. Even with real crypto, you could not see a conversation.
- **B3 — Realtime is fire-and-forget with silent loss, and the client never falls back to polling.** `Hub.Publish` drops events when a client buffer is full ([hub.go:59-62](server/internal/realtime/hub.go#L59-L62)); the only client `SyncService` ([sync_service.dart](mobile/lib/sync/sync_service.dart)) listens to the websocket and never calls `/api/v1/sync/events`, has no reconnect, and no keepalive. Dropped or missed events are lost until an app restart.
- **S1 — Any authenticated user can enumerate the entire user directory.** `SearchMetadata` queries `accounts` globally with `LIKE '%term%'` ([sqlite.go:1103-1113](server/internal/storage/sqlite.go#L1103-L1113)) with no relationship scoping — a privacy leak in a product whose entire value proposition is privacy.
- **Scale ceiling is hard-coded.** `SetMaxOpenConns(1)` ([sqlite.go:46](server/internal/storage/sqlite.go#L46)) serializes *all* DB I/O, and the realtime hub is in-process, so the design is permanently single-node. Fine for the stated self-host target; a wall for anything beyond it.

What is genuinely good (so this isn't all negative): the server's privacy posture is real and well-enforced — plaintext-key rejection middleware, ciphertext-only schema with `CHECK(length(ciphertext) > 0)`, metadata-only audit log, no ciphertext in the sync log, constant-time login, trusted-proxy-aware rate limiting, atomic backup via `VACUUM INTO`, and a careful device-linking state machine. The bones are good. The body isn't built yet.

---

## Critical Blockers

### B1 — E2EE crypto is entirely unimplemented; the client cannot register or send
- Server: [cryptoapi.go:28-40](server/internal/cryptoapi/cryptoapi.go#L28-L40) — every method returns `ErrProductionCryptoUnavailable`.
- Mobile: [crypto_service.dart:8-18](mobile/lib/crypto/crypto_service.dart#L8-L18) — `UnavailableCryptoService` throws `StateError` on both methods.
- Rust: [lib.rs:9-11](crypto/rust/src/lib.rs#L9-L11) — `pm_crypto_available()` returns `-1`; there are no MLS bindings, no FFI surface.
- Wiring: [main.dart:15](mobile/lib/main.dart#L15) injects `UnavailableCryptoService()`.

Consequence chain: `AppState.createOwner` / `login` call `cryptoService.createDeviceKeyPackage()` *first* ([app_state.dart:77](mobile/lib/core/app_state.dart#L77), [app_state.dart:182](mobile/lib/core/app_state.dart#L182)). That throws, is caught by `_run`, and surfaces as an error string. **The real app cannot complete setup or sign in.** Only `TestOnlyCryptoService` (test-only, emits a sentinel ciphertext) actually produces output, and it is not wired into `main.dart`. This is honestly disclosed in `WORK_IN_PROGRESS.md` (Tier 3) and `docs/TODO.md`, but it is the gating item for the product existing at all. Everything else in this report is secondary to it.

### B2 — No client read/display path for messages
[chat_screen.dart](mobile/lib/features/chat/chat_screen.dart) has a composer and a lock icon — no `ListView` of messages, no call to the messages endpoint, no decrypt step. `ApiClient` has `sendEnvelope`, `sendReaction`, `markRead`, but **no `listMessages`** method at all ([api_client.dart](mobile/lib/core/api_client.dart)). The server-side `GET /conversations/{id}/messages` with cursor pagination is implemented and tested, but nothing on the client consumes it. The client is send-only and display-nothing.

### B3 — Realtime delivery is lossy with no client recovery
- `Hub.Publish` uses a 32-deep per-client buffer and a non-blocking `select`/`default` that silently discards on overflow ([hub.go:28](server/internal/realtime/hub.go#L28), [hub.go:57-64](server/internal/realtime/hub.go#L57-L64)). The documented recovery is `/api/v1/sync/events`.
- But the client never uses it: `WebSocketSyncService` only listens to the socket, `onDone: () {}` is a no-op, there is no reconnect/backoff, and `AppState._startSync` just calls `refreshConversations()` on *any* event — it never applies the event payload and never replays missed events ([sync_service.dart:35-39](mobile/lib/sync/sync_service.dart#L35-L39), [app_state.dart:214-223](mobile/lib/core/app_state.dart#L214-L223)).
- There is also **no websocket keepalive / ping-pong**. `ServeWebSocket` clears all deadlines after hijack ([websocket.go:49](server/internal/realtime/websocket.go#L49)) and `drainClientFrames` only returns on read error or a close frame ([websocket.go:118-167](server/internal/realtime/websocket.go#L118-L167)). A NAT/idle timeout silently half-opens the connection and the client never notices.

Net effect: even after B1/B2 are fixed, realtime sync would be unreliable.

---

## Security Vulnerabilities (ordered by severity)

### S1 (High) — Global user enumeration via metadata search
`SearchMetadata` scopes communities and channels to the caller's memberships, but `accounts` is queried with no scoping: `FROM accounts WHERE deleted_at IS NULL AND username LIKE ? ESCAPE '\'` ([sqlite.go:1112-1113](server/internal/storage/sqlite.go#L1112-L1113)). Any authenticated user can walk the substring space (`a`, `b`, …) and dump every username on the instance. For a self-hosted private messenger this is a meaningful metadata disclosure. At minimum, gate account results behind an existing relationship (shared conversation/community) or require an exact-username match for cross-user lookup.

### S2 (High) — No logout, no session revocation, no device revocation
Sessions are created with 30-day TTLs ([api.go:138](server/internal/httpapi/api.go#L138), [api.go:174](server/internal/httpapi/api.go#L174)) but:
- There is **no logout / `DELETE /session` endpoint**. `SecureLocalStore.clear()` exists but no flow calls it.
- There is **no device-revocation endpoint** despite `devices.revoked_at` existing in the schema and being checked everywhere. A lost/stolen device cannot be cut off short of `DELETE /api/v1/account` (which nukes the whole account).
- Only full account deletion clears sessions ([sqlite.go:1338](server/internal/storage/sqlite.go#L1338)). There's no "log out my other devices" or per-session expiry/rotation. For a security-focused product this is a core gap, not a nicety.

### S3 (Medium) — Device-link approval has no enforced key-continuity check
The linking state machine is careful (claim → approve → one-shot consume), but approval ([api.go:353-372](server/internal/httpapi/api.go#L353-L372)) trusts the claimed `key_package` as-is. The `verification_code` is shown to both sides but the server never requires the approver to confirm it, and there is no fingerprint/key-continuity verification (acknowledged as missing in `WORK_IN_PROGRESS.md` Tier 3). A malicious or coerced claim can register an attacker-controlled device key if the human blindly approves. Until QR + continuity verification lands, the linking flow is the weakest point in the trust model. Document it as such and consider requiring the approver to type back the verification code.

### S4 (Medium) — Conversation membership can be assigned without consent / community check
- `createConversation` accepts arbitrary `member_account_ids` and adds them with no consent and no relationship check ([api.go:483-490](server/internal/httpapi/api.go#L483-L490)). Anyone can pull any account into a conversation.
- For `kind == "community_channel"`, the caller's membership in `CommunityID` is never verified ([api.go:471-482](server/internal/httpapi/api.go#L471-L482)); a user can mint a conversation pointing at a community they don't belong to.
- The member-add loop runs *after* the conversation is committed and is not atomic ([api.go:483-490](server/internal/httpapi/api.go#L483-L490)) — a mid-loop failure leaves a half-populated conversation plus a 4xx/5xx to the caller.

### S5 (Low) — bcrypt 72-byte truncation; password has min length but no max
`HashPassword` enforces ≥12 chars ([auth.go:16-25](server/internal/auth/auth.go#L16-L25)) but no upper bound. bcrypt silently truncates at 72 bytes, so very long passwords lose entropy beyond byte 72 and a passphrase manager's long secret is partly ignored. Add a sane max (e.g. reject > 72 bytes, or pre-hash with SHA-256 before bcrypt).

### S6 (Low) — Constant-time login regresses if the dummy hash failed to build
`VerifyPasswordOrDummy` only runs the dummy bcrypt when `dummyHash` is non-empty ([auth.go:47-52](server/internal/auth/auth.go#L47-L52)). If `GenerateFromPassword` ever errored during the `sync.Once`, the empty-hash path returns `false` immediately, reopening the username-enumeration timing channel the function exists to close. Low likelihood, but the fail-safe should panic or retry rather than silently degrade.

### S7 (Low) — Deployment template ships insecure placeholders
[Caddyfile](deploy/caddy/Caddyfile) hard-codes `admin@example.com` and `messenger.example.com`; [docker-compose.yml](deploy/docker-compose.yml) publishes `8080:8080` directly (the `caddy` profile is opt-in, so the default `docker compose up` exposes plain HTTP to the host network with no TLS). An operator who copies the defaults gets a cleartext deployment. Add a healthcheck and make TLS the default path, not a profile.

---

## Performance & Scalability Issues

### P1 — `SetMaxOpenConns(1)` serializes every request
[sqlite.go:46](server/internal/storage/sqlite.go#L46). Correct for write-safety on a single SQLite file, but it makes *all* I/O strictly serial — a single slow query (e.g. the unindexed search in P3, or a large export) blocks health checks and every other request. WAL already permits concurrent readers; splitting a read pool (deferred transactions) from a single writer would remove most of the contention. Acknowledged (Tier 4 M).

### P2 — Every authenticated request issues a write
`PrincipalByTokenHash` runs `UPDATE devices SET last_seen_at …` on each call ([sqlite.go:321-325](server/internal/storage/sqlite.go#L321-L325)). The throttle lives in the `WHERE` clause, so even when it updates 0 rows it still takes the write lock — and under P1 that serializes behind every other operation. Consider stamping `last_seen_at` asynchronously / out of the request path, or batching.

### P3 — Metadata search is a full scan with leading-wildcard `LIKE`
`SearchMetadata` uses `'%' + term + '%'` ([sqlite.go:1102](server/internal/storage/sqlite.go#L1102)) across three `UNION ALL` branches. A leading wildcard cannot use any index → full scans of `accounts`, `communities`, `channels` on every keystroke-driven search, all serialized through the single connection. Consider FTS5 or at least prefix-only matching with a real index.

### P4 — `ListSyncEvents` uses a correlated subquery per poll
[sqlite.go:1064-1073](server/internal/storage/sqlite.go#L1064-L1073): `conversation_id IN (SELECT … FROM memberships WHERE account_id = ?)` combined with an `OR account_id = ?`. The `OR` defeats the `idx_sync_events_account` index, so this degrades toward a scan of `sync_events` filtered only by `id > ?` as the table grows. The 30-day retention sweep bounds growth, but the query shape is the wrong one for a hot polling endpoint.

### P5 — In-process hub blocks horizontal scaling
`Hub` holds subscribers in a process-local map ([hub.go:18-21](server/internal/realtime/hub.go#L18-L21)). Two server replicas would not see each other's `Publish` calls, so realtime fan-out only works single-node. Combined with single-file SQLite, the system is single-node by construction. State that constraint explicitly; a second replica would silently drop cross-node events.

### P6 — Websocket writer can block indefinitely
With all deadlines cleared ([websocket.go:49](server/internal/realtime/websocket.go#L49)) and no write timeout around `rw.Flush()` ([websocket.go:67-71](server/internal/realtime/websocket.go#L67-L71)), a stalled TCP peer pins that connection's goroutine forever. Add a per-write deadline and a periodic ping with a pong deadline to reap dead peers.

---

## Code Quality & Best Practices

### Q1 — Latent timestamp-ordering bug: lexicographic compare of `RFC3339Nano`
All timestamps are stored as `time.RFC3339Nano` strings and compared lexicographically in SQL (`created_at < ?`, `expires_at > ?`, cursor pagination). `RFC3339Nano` **trims trailing zeros** in the fractional part, so its width is variable: `…05Z` (whole second) vs `…05.5Z` (half second). Lexicographically `'.'` (0x2E) < `'Z'` (0x5A), so a *later* whole+fraction time sorts *before* an earlier whole-second time. Between two fractional timestamps the order is correct (positional digits), so this only bites when a value lands exactly on a second boundary (nanos == 0) — rare, but real, and it silently corrupts cursor pagination ordering ([sqlite.go:960-986](server/internal/storage/sqlite.go#L960-L986)) and any `expires_at` boundary check. Fix by storing fixed-width timestamps (always-padded nanos) or integer epoch-nanos. This is fragile by construction and will eventually surprise someone.

### Q2 — Pervasive silent error-swallowing on writes
Sync/audit writes are discarded throughout: `eventID, _ := a.Store.SaveSyncEvent(...)`, `members, _ := a.Store.ListConversationMemberIDs(...)` ([api.go:599-601](server/internal/httpapi/api.go#L599-L601), and ~8 other sites), `RecordAuditEvent` ignores all errors by design ([sqlite.go:1037-1046](server/internal/storage/sqlite.go#L1037-L1046)), and `last_seen_at` uses `_, _ =`. For a product that markets an audit log, dropping audit/sync writes with no log line is a contradiction — at least `Log.Warn` on failure.

### Q3 — Near-zero server-side observability
The slog logger emits only `server_starting` and prune counts ([app.go:78](server/internal/app/app.go#L78), [app.go:101-108](server/internal/app/app.go#L101-L108)). There is **no request logging, no request IDs, no error logging in handlers** (handler errors become a JSON code to the client and vanish), no `/metrics`, no tracing. `doctor` advertises "telemetry: disabled" as a feature ([main.go:129](server/cmd/messenger-server/main.go#L129)). An operator debugging a 500 has nothing to go on. Add structured access logging and surface 5xx causes to logs (not to clients).

### Q4 — Mobile networking has no timeouts and leaks error detail to the UI
`ApiClient` uses a bare `HttpClient` with no connection/idle timeout ([api_client.dart:8](mobile/lib/core/api_client.dart#L8)); a hung server hangs the app indefinitely. Errors surface as `error.toString()` → users see `ApiException(401)` raw ([app_state.dart:231-232](mobile/lib/core/app_state.dart#L231-L232)). The parsed error code from the server body is discarded. Add timeouts, retry/backoff, and human-readable error mapping.

### Q5 — Sync stream errors are unhandled on the client
`WebSocketSyncService` forwards socket errors into the broadcast controller ([sync_service.dart:39](mobile/lib/sync/sync_service.dart#L39)), but `AppState._startSync` subscribes with only an `onData` callback ([app_state.dart:221](mobile/lib/core/app_state.dart#L221)). An unhandled error on a broadcast stream is dropped (or, depending on Flutter version, escalates). Either way there is no reconnect and no user feedback.

### Q6 — Inconsistent routing idioms
`/push/subscriptions/{id}` uses Go 1.22 path values ([api.go:49](server/internal/httpapi/api.go#L49)), while `conversationSubroute`/`communitySubroute`/`messageSubroute`/`deviceLinkSubroute` hand-roll `strings.Split` parsing with manual auth re-checks ([api.go:331-401](server/internal/httpapi/api.go#L331-L401), etc.). The manual parsers are more error-prone (trailing-slash and segment-count edge cases) and duplicate the auth logic that `withAuth` already centralizes. Migrate them to typed `{id}` patterns.

### Q7 — Dockerfile copies `go.mod` without `go.sum` before `go mod download`
[Dockerfile:4-6](server/Dockerfile#L4-L6) copies only `go.mod`, runs `go mod download`, then copies the rest. Without `go.sum` present at download time, module checksum verification is weakened and the build-cache layering benefit is partial. Copy both `go.mod` and `go.sum` before `go mod download`.

### Q8 — CI conflates fmt and vet failures
[ci.yml:17](.github/workflows/ci.yml#L17): `test -z "$(gofmt -l .)" && go vet ./...` short-circuits — if `gofmt` reports files, `go vet` never runs, and the two failure modes are indistinguishable in logs. Split into separate steps. Also there is no `golangci-lint`, no `go test -race`, no Dart formatting check, and Flutter `channel: stable` is unpinned (non-reproducible).

### Q9 — Minor server-side hygiene
- `BackupTo` builds `VACUUM INTO '<path>'` via string interpolation ([sqlite.go:77-78](server/internal/storage/sqlite.go#L77-L78)). Justified (filename literal can't bind, operator-supplied) and quote-escaped, but it's the one raw-SQL-construction site and worth a comment-flag for future linters.
- `rateLimiter.cleanupLoop` runs for the process lifetime with no shutdown hook ([app.go:171](server/internal/app/app.go#L171)), unlike `runRetentionSweeper` which honors `ctx`. Harmless (process exit) but inconsistent.
- `writeJSON` sets status then encodes ([api.go:1208-1212](server/internal/httpapi/api.go#L1208-L1212)); an encode failure mid-stream yields a 200 with a truncated body. Standard Go caveat; acceptable but worth knowing.

---

## Missing Tests & Observability

Server HTTP happy-paths and authorization are reasonably covered ([api_test.go](server/internal/httpapi/api_test.go): plaintext rejection with DB-sentinel scan, ciphertext lifecycle, membership-gated writes, device-link flow, cursor pagination). Gaps:

- **No test for the timestamp-ordering edge case (Q1)** — pagination tests use timestamps that all carry fractional seconds, so the whole-second boundary bug is invisible.
- **No test that search metadata is scoped** — i.e., nothing asserts a user *cannot* enumerate unrelated accounts (S1 would be caught by such a test).
- **No tests for the rate limiter, websocket framing/upgrade, or `Hub.Publish` drop semantics.**
- **No concurrency / `-race` testing**, and no test for concurrent owner-setup races.
- **Rust has one trivial test** ([lib.rs:17-20](crypto/rust/src/lib.rs#L17-L20)) asserting the stub fails closed — appropriate for now, but there is no crypto to test.
- **Mobile coverage is thin** (`app_state_test.dart` against `MemoryLocalStore`); no widget tests for the (missing) message view, no test that `main.dart`'s wiring actually permits registration (which would have caught B1's UX impact).
- **Observability**: see Q3 — there is effectively none. Before any real deployment, add structured access logs, error logs for 5xx, and a basic metrics endpoint.

---

## Architecture Concerns

- **The privacy boundary is the strongest part of the design and should be preserved exactly as-is**: server-side plaintext-key rejection ([api.go:1095-1128](server/internal/httpapi/api.go#L1095-L1128)), ciphertext-only columns with `CHECK(length(ciphertext) > 0)`, metadata-only audit rows, and the sync log storing message *references* not bodies ([api.go:801-816](server/internal/httpapi/api.go#L801-L816)). This is genuinely well thought through.
- **The product is ~15–20% of a working messenger.** Missing, per the project's own Tier 3 list and confirmed by this read: production crypto (B1), client message display (B2), reliable sync (B3), push providers, WebRTC media, attachment encryption UX, backup/restore UX, QR + key continuity. Each is substantial.
- **Single-node by construction** (P1 + P5). That's an acceptable, even reasonable, choice for the documented "small self-hosted instance" target — but it should be stated as a deliberate boundary, not discovered later. PostgreSQL/S3/Redis-fanout adapters are correctly deferred in `docs/TODO.md`.
- **Trust model leans on the human** for device-link verification (S3). Until key continuity is enforced, the E2EE guarantee is "as strong as the user's diligence in comparing a 6-digit code," which is weaker than the marketing implies.

---

## Prioritized Action Plan

### Short term (make it real / stop the bleeding)
1. **B1** — Integrate a real crypto implementation behind `cryptoapi.ClientCrypto` / `CryptoService` (OpenMLS via Rust FFI per the plan), and wire it into `main.dart`. Nothing else matters until this exists.
2. **B2** — Build the client message read path: `ApiClient.listMessages`, a message list view, decrypt + render.
3. **S1** — Scope `SearchMetadata` account results to existing relationships (or require exact username). Add a regression test.
4. **S2** — Add logout + session revocation + device revocation endpoints (the `revoked_at` columns already exist).
5. **Q1** — Switch timestamps to a sortable representation (fixed-width or epoch-nanos) before this bug ships to anyone.

### Medium term (make it reliable / honest)
6. **B3 / P6 / Q5** — Client websocket reconnect with backoff, `/sync/events` replay on (re)connect, and server-side ping/pong + write deadlines.
7. **S3** — Enforce verification-code confirmation on device-link approval; ship QR + key-continuity.
8. **S4** — Add consent/relationship checks to conversation membership and validate community membership for `community_channel`; make member-add atomic with conversation creation.
9. **Q2 / Q3** — Stop swallowing audit/sync write errors (log them); add structured access + error logging and a metrics endpoint.
10. **Q4** — Mobile HTTP timeouts, backoff, and human-readable error mapping.

### Long term (make it scale / production-grade)
11. **P1 / P2 / P3 / P4** — Split read/write SQLite pools (or move to Postgres), move `last_seen_at` off the request path, replace `LIKE '%…%'` search with FTS5, and reshape `ListSyncEvents` to be index-friendly.
12. **P5** — If multi-node is ever a goal, externalize hub fan-out (Redis pub/sub or NATS).
13. **Push, WebRTC media, attachment/backup UX** — the remaining Tier 3 product surface.
14. **CI** — `golangci-lint`, `go test -race`, `dart format --set-exit-if-changed`, pinned Flutter version, and triage the open Dependabot alerts noted in `WORK_IN_PROGRESS.md`.

---

*Caveat on scope: this report reflects a careful read of the source, not a running deployment. The crypto-stub status (B1) means much of the client could not be exercised end-to-end even if run. Severity ratings are my judgment for the stated self-hosted threat model.*
