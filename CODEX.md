# Veritra Deep Audit Report

Status note, 2026-07-04: this is a historical audit from 2026-05-30. Some
findings have since been fixed or superseded. Use `WORK_IN_PROGRESS.md` and
`docs/TODO.md` for current tracking.

Date: 2026-05-30
Scope: full repo: Go server, Flutter mobile shell, Rust crypto boundary, docs, CI, deployment.

## Verification Status

- Source audit completed by reading current repo files.
- `scripts/test.ps1` and `scripts/lint.ps1` could not complete here.
- Reason: local Go, Cargo, and Flutter are not installed; Docker CLI exists, but Docker Desktop daemon is not running.
- Docker check observed: client `28.4.0`; daemon pipe `//./pipe/dockerDesktopLinuxEngine` missing.
- Existing `WORK_IN_PROGRESS.md` says prior lint/test/govulncheck were clean, but I did not verify that claim locally.

## Strong Parts

- Server schema and API are consistently ciphertext-first.
- Plaintext message field rejection exists before decode for message mutations.
- Sync log stores compact message refs, not ciphertext bodies.
- Audit log comments explicitly forbid content/secrets.
- SQLite now has a single writer plus bounded reader pool.
- Device-link consume is one-shot and claim token is header-based in code.
- Push payload contract is generic and tested.

## Critical Blockers

### B1 - Production crypto is absent

Impact: the product is not a working E2EE messenger yet.

Evidence:
- `mobile/lib/main.dart:14` wires `UnavailableCryptoService`.
- `mobile/lib/crypto/crypto_service.dart:8` throws for key package and encryption.
- `mobile/lib/core/app_state.dart:77` owner setup needs `createDeviceKeyPackage`.
- `mobile/lib/core/app_state.dart:126` sending needs `encrypt`.
- `mobile/lib/core/app_state.dart:182` device-link claim needs `createDeviceKeyPackage`.
- `server/internal/cryptoapi/cryptoapi.go` and `crypto/rust/src/lib.rs` are fail-closed stubs.

Fix:
- Implement real client crypto and key storage first.
- Keep server ciphertext-only.
- Wire production crypto in `main.dart`; keep test crypto test-only.

### B2 - First-run setup paths are broken or non-production

Impact: a normal user cannot safely create a real first device.

Evidence:
- Mobile owner creation fails because B1 throws before the API call.
- Web setup has inline JS at `server/websetup/index.html:37`.
- CSP blocks inline scripts: `server/internal/app/app.go:139` has `script-src 'self'` with no nonce/hash/`unsafe-inline`.
- If CSP is fixed, web setup still posts a placeholder key package at `server/websetup/index.html:43`.

Fix:
- Either make setup static form-based or add a CSP nonce/hash.
- Do not create production owners with placeholder device key packages.
- Prefer mobile/desktop setup only after real crypto exists.

### B3 - Password login is not a valid cryptographic device model

Impact: a fresh client can receive a session for a device whose private key it does not own.

Evidence:
- Mobile login sends username/password only: `mobile/lib/core/api_client.dart:36`.
- `Session` stores only base URL and token: `mobile/lib/core/models.dart:113`.
- Server chooses an existing device when `device_id` is omitted: `server/internal/storage/sqlite.go:398`.
- Device selection is "most recently active": `server/internal/storage/sqlite.go:407`.

Fix:
- Require a local device ID plus local private key for login reuse.
- For a new device, force device-link flow or create a new key package with explicit approval.
- Store account/device IDs and crypto key handles locally.

### B4 - Client cannot read messages

Impact: even with crypto fixed, the app cannot show a conversation.

Evidence:
- `mobile/lib/features/chat/chat_screen.dart:26` renders only an icon in the message area.
- `mobile/lib/core/api_client.dart` has `sendEnvelope`, but no `listMessages`.
- No client decrypt/render path exists.

Fix:
- Add `ApiClient.listMessages`.
- Add local message model/cache.
- Decrypt and render message pages with pagination.

### B5 - Realtime recovery is missing on the client

Impact: dropped or missed events are not reliably recovered.

Evidence:
- Server intentionally drops full socket buffers: `server/internal/realtime/hub.go:28`, `server/internal/realtime/hub.go:65`.
- Contract says recover through `/sync/events`: `server/internal/realtime/hub.go:50`.
- Client only listens to the WebSocket: `mobile/lib/sync/sync_service.dart:31`.
- `onDone` is empty: `mobile/lib/sync/sync_service.dart:39`.
- App reacts by refreshing conversations only: `mobile/lib/core/app_state.dart:221`.

Fix:
- Persist last seen event ID.
- Replay `/api/v1/sync/events?after=...` on connect/reconnect.
- Add reconnect/backoff and stream error handling.

## Security Findings

### S1 - High - Authenticated users can enumerate all accounts

Evidence:
- `SearchMetadata` scopes communities/channels by membership.
- Account search is global: `server/internal/storage/sqlite.go:1230`.
- It uses `username LIKE ?`: `server/internal/storage/sqlite.go:1231`.

Risk:
- Any member can scrape usernames by probing common substrings.

Fix:
- Return account results only for shared conversations/communities, or exact username lookup only.
- Add a regression test for unrelated account invisibility.

### S2 - High - No logout/session/device revocation

Evidence:
- Sessions are 30 days: `server/internal/httpapi/api.go:138`, `:174`, `:226`.
- No logout route exists.
- No device revocation route exists, though `devices.revoked_at` exists.
- Account deletion is the only session wipe: `server/internal/storage/sqlite.go:1456`.
- `PrincipalByTokenHash` does not join `devices` or check `revoked_at`: `server/internal/storage/sqlite.go:424`.

Risk:
- Lost device or leaked token cannot be revoked without deleting the whole account.

Fix:
- Add logout current session.
- Add revoke session, revoke device, and logout all devices.
- Make auth reject revoked devices.
- Disconnect active WebSockets for revoked accounts/devices.

### S3 - High - Disappearing-message retention is metadata only

Evidence:
- Conversation retention is stored: `server/internal/storage/sqlite.go:847`.
- `disappearing_policies` exists: `server/migrations/0001_init.sql:135`.
- Messages accept client-provided `expires_at`: `server/internal/httpapi/api.go:642`, `:681`.
- No message pruning exists; only sync/audit pruning exists: `server/internal/storage/sqlite.go:1135`, `:1144`.
- `ListMessages` does not filter expired envelopes: `server/internal/storage/sqlite.go:1053`.

Risk:
- Users may believe messages disappear, but ciphertext remains indefinitely.

Fix:
- Enforce server-side expiry for envelope rows and blob references.
- Bound message `expires_at` by conversation retention.
- Filter expired rows and add a pruning job.

### S4 - Medium - Device-link approval lacks enforced verification

Evidence:
- Claim submits key package and optional signing key.
- Approval creates the device without requiring a confirmed verification code.
- The docs say the client UX must compare the code, but server does not enforce it.

Risk:
- A user can approve an attacker-controlled claimed device by mistake.

Fix:
- Require approver to submit the verification code or key fingerprint.
- Add QR/fingerprint UX before production.

### S5 - Medium - Conversation membership rules are too loose

Evidence:
- `member_account_ids` can include arbitrary accounts: `server/internal/httpapi/api.go:455`, `:483`.
- `community_channel` creation does not verify caller membership in the community/channel: `server/internal/httpapi/api.go:471`.
- Storage inserts supplied community/channel IDs directly: `server/internal/storage/sqlite.go:783`.
- Initial member adds happen after conversation creation and are not atomic: `server/internal/httpapi/api.go:483`.

Risk:
- Users can be added without consent.
- Conversations can point at communities/channels the creator should not control.
- Partial conversation creation can happen on member-add failure.

Fix:
- Validate relationship and consent rules.
- Validate channel belongs to community.
- Make conversation plus initial members one transaction.

### S6 - Medium - Attachment upload can orphan large blobs

Evidence:
- Blob is written before `X-Crypto-Metadata` validation: `server/internal/httpapi/api.go:835`, `:840`.
- Invalid metadata returns after the file is already stored: `server/internal/httpapi/api.go:844`.
- No blob cleanup API exists in `uploads.Store`.
- DB record failure also leaves the blob.

Risk:
- Authenticated users can waste disk with invalid 50 MB uploads.

Fix:
- Validate metadata before writing.
- Add delete/cleanup for failed records.
- Add per-account quotas and orphan sweeper.
- Return 413 for size limit failures, not generic 500.

### S7 - Low - bcrypt password max length is missing

Evidence:
- Minimum length only: `server/internal/auth/auth.go:16`.
- bcrypt truncates after 72 bytes.

Fix:
- Reject passwords over 72 bytes, or pre-hash intentionally with documented reasoning.

### S8 - Low - Random/rate-limit fail-open edges

Evidence:
- Rate limiter salt ignores `rand.Read` error: `server/internal/app/app.go:170`.
- Invalid trusted proxy CIDRs are silently ignored: `server/internal/config/config.go:38`.

Fix:
- Fail startup or log loudly on these failures.

## Performance And Scaling

### P1 - Search does leading-wildcard scans

Evidence:
- `containsPattern := "%" + escapeLike(query) + "%"`: `server/internal/storage/sqlite.go:1220`.
- Query spans accounts, communities, channels: `server/internal/storage/sqlite.go:1221`.

Impact:
- Full scans as data grows.

Fix:
- Use FTS5 or prefix-only indexed search.
- Debounce client search.

### P2 - Sync event query shape will age poorly

Evidence:
- `ListSyncEvents` uses `OR` plus subquery: `server/internal/storage/sqlite.go:1182`.
- Index only covers `(account_id, id)`: `server/migrations/0001_init.sql:195`.

Impact:
- Hot polling endpoint trends toward scanning by `id`.

Fix:
- Split account and conversation event queries with `UNION ALL`.
- Add indexes for `(conversation_id, id)` and `(id)`.

### P3 - `last_seen_at` writes happen in auth path

Evidence:
- Every authenticated request calls `PrincipalByTokenHash`.
- It attempts a throttled write: `server/internal/storage/sqlite.go:442`.

Impact:
- Even no-op updates contend for the single SQLite writer.

Fix:
- Batch or async-update device presence.

### P4 - WebSocket lifecycle can leak stale connections

Evidence:
- Deadlines are cleared: `server/internal/realtime/websocket.go:49`.
- Writes flush with no write deadline: `server/internal/realtime/websocket.go:70`.
- No ping/pong heartbeat exists.

Impact:
- Half-open TCP peers can pin goroutines and subscriptions.

Fix:
- Add ping/pong and read/write deadlines.
- Consider a maintained WebSocket library after license review.

### P5 - Single-node by design

Evidence:
- Realtime hub is in-process map: `server/internal/realtime/hub.go:18`.
- SQLite is local file storage.
- Blob store is local disk.

Impact:
- Multiple server replicas silently miss cross-node realtime events.

Fix:
- Document single-node as a v1 constraint.
- Add Postgres/S3/Redis or NATS only if multi-node becomes a goal.

## Architecture And Best-Practice Gaps

### Q1 - HTTP handlers own too much product orchestration

Evidence:
- `httpapi.API` depends on concrete `*storage.Store`, `*realtime.Hub`, and `uploads.Store`: `server/internal/httpapi/api.go:24`.
- Handlers create sessions, audit events, sync events, membership mutations, and storage records directly.

Risk:
- Harder to test domain behavior without HTTP.
- Module boundary rule is only partially met.

Fix:
- Add small application services for auth, conversations, messages, devices, sync.
- Keep storage, realtime, upload behind interfaces.

### Q2 - Many durable side effects silently drop errors

Evidence:
- Audit writes ignore DB errors: `server/internal/storage/sqlite.go:1163`.
- Sync event writes often ignore errors: `server/internal/httpapi/api.go:369`, `:599`, `:688`, `:796`, `:934`.
- Member lookup errors for publish are ignored: `server/internal/httpapi/api.go:600`, `:689`, `:797`, `:935`.

Risk:
- Operators cannot trust audit/sync completeness.

Fix:
- Log privacy-safe warnings.
- Decide which side effects are required before returning success.

### Q3 - Observability is too thin for operations

Evidence:
- Server logs startup and prune counts, but no request IDs/access logs/5xx cause logs.
- `writeError` emits only JSON code: `server/internal/httpapi/api.go:1214`.

Fix:
- Add privacy-safe request logging.
- Add request IDs.
- Log internal 5xx causes without bodies/secrets.
- Add basic metrics.

### Q4 - JSON decoding accepts trailing data

Evidence:
- `decodeRawJSON` decodes once and does not check EOF: `server/internal/httpapi/api.go:1085`.

Fix:
- Decode once, then require EOF.

### Q5 - Manual routing is inconsistent

Evidence:
- Some routes use Go path params, e.g. push delete.
- Messages/conversations/communities/device-links use manual `strings.Split`: `server/internal/httpapi/api.go:331`, `:503`, `:704`.

Fix:
- Prefer typed `ServeMux` path patterns consistently.

### Q6 - Timestamp format is fragile for ordering

Evidence:
- `formatTime` uses variable-width `time.RFC3339Nano`: `server/internal/storage/sqlite.go:1749`.
- SQL compares timestamp strings in pagination and expiry checks.

Risk:
- Whole-second timestamps and fractional timestamps can sort incorrectly lexicographically.

Fix:
- Store epoch milliseconds/nanos or fixed-width UTC timestamps.

### Q7 - Mobile networking lacks production behavior

Evidence:
- Bare `HttpClient`: `mobile/lib/core/api_client.dart:8`.
- UI gets `err.toString()`: `mobile/lib/core/app_state.dart:232`.
- `ApiException.toString()` hides server code/body: `mobile/lib/core/api_client.dart:213`.

Fix:
- Set timeouts.
- Map server error codes to user-safe messages.
- Add retry/backoff where safe.

## Docs, CI, And Deployment

### D1 - API docs are stale

Evidence:
- Docs still mention `claim_token` query param: `docs/api.md:23`.
- Docs still mention WebSocket `?token=` fallback: `docs/api.md:63`.
- Code uses `X-Veritra-Claim-Token` and Authorization header only.

Fix:
- Update docs to match current security behavior.

### D2 - TODO/notice files are stale

Evidence:
- `docs/TODO.md` says "Implement production encrypted local mobile storage"; only session secure storage exists, while key/message storage is still absent.
- `flutter_secure_storage` is in `mobile/pubspec.yaml:12`.
- `THIRD_PARTY_NOTICES.md` does not list `flutter_secure_storage`.

Fix:
- Clarify TODO as key/message storage if that is what remains.
- Add exact direct/transitive license entries.

### D3 - License check is not a check

Evidence:
- CI runs `./scripts/license-check.sh`: `.github/workflows/ci.yml:50`.
- Script only prints files and instructions.

Fix:
- Use actual Go/Dart/Rust license scanning before release.

### D4 - Dockerfile misses `go.sum` in dependency layer

Evidence:
- Dockerfile copies `go.mod`, runs `go mod download`, then copies source: `server/Dockerfile:4`.

Fix:
- Copy `go.mod` and `go.sum` before `go mod download`.

### D5 - Public deployment defaults need hardening

Evidence:
- Compose publishes plain `8080:8080` by default.
- Caddy is opt-in profile.
- Caddyfile has placeholder domain/email.
- App sets HSTS only when `r.TLS != nil`; behind reverse proxy this is false: `server/internal/app/app.go:135`.

Fix:
- Make TLS path the normal production path.
- Add HSTS at Caddy.
- Add healthchecks and clearer production deployment docs.

## Highest-Value Fix Order

1. Implement production crypto and local key storage.
2. Fix setup: CSP plus no placeholder production key packages.
3. Fix device identity model for login/new devices.
4. Add message read/decrypt/render path.
5. Add sync catch-up and reconnect.
6. Add logout/session/device revocation.
7. Scope account search.
8. Enforce disappearing-message expiry.
9. Fix attachment orphaning and quotas.
10. Add privacy-safe observability.
