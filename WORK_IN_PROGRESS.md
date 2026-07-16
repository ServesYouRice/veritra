# WORK IN PROGRESS

Audit findings + progress log from the 2026-05-29 security/quality pass.

## Status at a glance

- **Tier 1 (hardening):** 14 items + 11 audit findings landed. Closed.
- **Tier 2 (spec gaps named in Plan.md):** 6 items landed. Closed.
- **Tier 3 (largest Plan.md commitments):** open — each item is weeks of work.
- **Tier 4 (scale & ops):** closed.

Corrections since this log was written: password login now requires an
explicit `device_id`, and current code does not stamp `devices.last_seen_at`.

Current verification: Dockerized `scripts/lint.ps1`, `scripts/test.ps1`,
and `govulncheck` are clean after the Tier 4 follow-up.

---

## Open — Tier 3: largest unfinished commitments from Plan.md

These are the MVP commitments that the Plan calls out explicitly and that
are still scaffolds. They are weeks of work each and require external
choices (which crypto library, which push provider stack, etc.).

- [ ] **Production E2EE crypto.** Bind a real implementation to
  `cryptoapi.ClientCrypto` (OpenMLS preferred for group, libsignal as
  fallback). Replace `UnavailableProductionCrypto` in the wiring and
  keep `TestOnlyCryptoService` strictly in tests. Server already
  refuses plaintext at the boundary; tests assert no sentinel leaks
  into the DB. This must include key-distribution APIs, local private-key
  storage, and client decrypt/render support. This is the single biggest
  remaining item.

- [ ] **Production key continuity** on top of the existing device-link API.
  QR rendering and scanning are implemented, including the iOS camera usage
  declaration, and manual code entry remains available. The server side
  (claim → approve → consume with one-shot claim token) is done; what's
  missing is a production verification step that compares the new device's
  key fingerprint against the approver's expectation before the session is
  issued.

- [ ] **Push providers.** Implement `push.Provider` for APNs, FCM, and
  UnifiedPush. Mandatory: payloads must carry no message text and no
  sender name (`push.GenericPayload` is the contract). Add provider
  tests that fail if forbidden fields appear in any rendered payload.

- [ ] **WebRTC media + 1:1 calls** behind `webrtc.SignalingService`.
  Call signaling records and events exist; media path does not. Pion
  or LiveKit are the candidate self-hosted options per Plan.md.

- [ ] **Mobile encrypted-attachment upload UX** and encrypted-backup
  restore UX. Server side accepts ciphertext blobs with the
  `X-Private-Messenger-Encrypted: 1` header; the mobile picker /
  client-side encryption path is unbuilt. Ciphertext list/download
  endpoints are also needed before recipients or restoring devices can
  fetch stored blobs.

---

## Done

### 2026-05-29 - Tier 4 (scale/ops) + dependency follow-up

- **M. SQLite read/write pools.** `storage.Open` now creates a single
  serialized writer connection and a bounded WAL reader pool. Existing
  `Exec`/transaction call sites route to the writer; `Query` call sites
  route to the reader pool, where SQLite read transactions remain
  deferred by default.
- **H. Migration checksums.** `schema_migrations` records a
  `checksum_sha256` for every SQL migration. Startup now rejects an
  already-applied migration whose file content changed, and a storage
  test covers the mismatch path.
- **N. Realtime drop contract.** `realtime.Hub.Publish` now documents
  that full client buffers drop only the best-effort socket copy, and
  clients recover durable events through `/sync/events`.
- **Dependabot alerts.** `golang.org/x/crypto` was bumped from
  `v0.36.0` to `v0.52.0`, `golang.org/x/sys` from `v0.31.0` to
  `v0.45.0`, and the Go toolchain/Docker/CI references were moved to
  Go 1.25 because those fixed module versions require it. `govulncheck`
  now reports no vulnerabilities across the scanned server module set.

### 2026-05-29 — Tier 2 (spec gaps) — commit `f6f844d`

- **L. Login device attribution (superseded).** Current code now requires
  an explicit `device_id` for password login, which is safer for the
  device-key model. The older most-recently-active fallback described in
  this log is no longer current behavior.
- **Q. Settings: hidden non-functional push toggle.** Replaced the dead
  `SwitchListTile` with explicit "coming soon" disabled tiles for
  Recovery / Calls / Privacy so the UI no longer implies features that
  don't exist.
- **R. `ListMessages` cursor pagination.** Added
  `storage.ListMessagesOptions` (`Limit`, `BeforeID`, `AfterID`).
  `GET /api/v1/conversations/{id}/messages` accepts `before`/`after`
  query params and returns `next_before` when more older messages may
  exist. Cursor is `(created_at, id)` so messages with identical
  timestamps still page correctly. New `TestListMessagesCursorPagination`
  walks three pages to verify the contract.
- **S. `ExportAccount` paginated.** New `ExportAccountOptions` (Limit,
  BeforeID), default 1000 with a cap of 5000. Endpoint surfaces
  `next_before` when more messages exist so truncation is no longer
  silent. Account, devices, and conversations are still returned in
  full on every page; only messages paginate.
- **P. Mobile insecure-URL confirmation.** `ConnectScreen._submit` now
  shows a confirmation dialog when the user submits an `http://` URL
  whose host is not local (`localhost`, `127.0.0.1`, `::1`, `*.local`,
  `*.localhost`, RFC 1918 ranges). Cancel aborts the submission;
  Continue Anyway proceeds.
- **O. Encrypted local session store.** Added `flutter_secure_storage`
  dependency and `SecureLocalStore` that persists the session as JSON
  to the platform keystore (Android Keystore-backed
  EncryptedSharedPrefs, iOS Keychain `first_unlock_this_device`).
  `main.dart` uses it by default and calls
  `AppState.tryRestoreSession()` on cold start so the user is no
  longer kicked out on every app launch. Tests continue to use
  `MemoryLocalStore`.

### 2026-05-29 — Tier 1 (hardening) — commit `39277d1`

Initial 14-item fix pass + 11 follow-up audit items, bundled with the
pre-existing device-link MVP work.

- **Username-enumeration timing.** Login runs bcrypt against a dummy
  hash when the lookup fails so response time is constant across
  existent/non-existent usernames.
- **Conversation privilege escalation.** Callers can no longer grant a
  role above their own effective rank
  (`RoleRank` + `effectiveConversationRole` helper).
- **Session token in URL.** Dropped query-param fallback; Authorization
  header only; mobile sends `Authorization` header on WebSocket
  connect. Bearer scheme matched case-insensitively per RFC 7235.
- **`claim_token` in URL.** Moved from query string to
  `X-Veritra-Claim-Token` header so it never lands in access logs.
- **WebSocket hardening.** Origin check rejects browser cross-origin
  upgrades; client frames must be masked (RFC 6455 §5.1); 1 MiB frame
  cap; http.Server deadlines cleared after Hijack.
- **HTTP server.** ReadTimeout / WriteTimeout / IdleTimeout set; rate
  limiter is now trusted-proxy aware
  (`PRIVATE_MESSENGER_TRUSTED_PROXIES`), has a separate 10/min auth
  bucket, a bounded buckets map, and a periodic cleanup goroutine.
- **Security headers.** Added X-Frame-Options, COOP, CORP,
  Permissions-Policy, conditional HSTS, and CSP on `/setup`.
- **Validation.** `retention_seconds` ∈ [0, 10y]; `idempotency_key`
  ≤128 chars; `crypto_protocol` ≤64 chars; community/channel names
  non-empty and ≤64 chars; invite `expires_at` must be future and
  ≤90d; `max_uses` ≤10000.
- **Read receipts cannot rewind.** SQL `WHERE` on `ON CONFLICT DO
  UPDATE` compares message `created_at`.
- **`devices.last_seen_at` (not current).** This log originally claimed
  authenticated requests stamped `last_seen_at`, but the current code only
  reads the field. Treat this as open follow-up if lost-device review UX
  needs reliable last-seen data.
- **Push de-registration.** `DELETE /api/v1/push/subscriptions/{id}`
  sets `disabled_at` on rows owned by the caller.
- **`audit_events` wired.** Metadata-only rows for `owner.created`,
  `account.registered`, `session.login`, `invite.created`,
  `device_link.approved`, `conversation.member.added`,
  `conversation.retention.updated`, `account.deleted`. Never
  ciphertext or password hashes.
- **`sync_events.payload_json` no longer duplicates ciphertext.**
  Persisted payload is the compact message reference; realtime WS
  payloads still carry the full envelope for connected clients.
- **`sync_events` / `audit_events` retention sweep.** Background
  goroutine deletes rows older than 30 days (override via
  `PRIVATE_MESSENGER_SYNC_EVENT_RETENTION_DAYS`).
- **Atomic backup.** CLI `backup` uses SQLite `VACUUM INTO` for a
  single consistent file.
- **Safer restore.** CLI `restore` probes the `-wal` companion for an
  exclusive open before touching anything, and removes leftover
  `-wal`/`-shm` companions before copying so SQLite cannot replay a
  stale journal.
