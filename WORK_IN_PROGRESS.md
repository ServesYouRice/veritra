# WORK IN PROGRESS

Audit findings + progress log from the 2026-05-29 security/quality pass.

## Status at a glance

- **Tier 1 (hardening):** 14 items + 11 audit findings landed. Closed.
- **Tier 2 (spec gaps named in Plan.md):** 6 items landed. Closed.
- **Tier 3 (largest Plan.md commitments):** open — each item is weeks of work.
- **Tier 4 (scale & ops):** open — small but not urgent.

All `go test`, `go vet`, `gofmt`, `flutter test`, `flutter analyze` clean
at HEAD. See git log for the commit boundaries between tiers.

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
  into the DB. This is the single biggest remaining item.

- [ ] **QR rendering + scanning + key continuity** on top of the
  existing device-link API. The server side (claim → approve → consume
  with one-shot claim token) is done; what's missing is the camera
  pipeline on mobile and a verification step that compares the new
  device's key fingerprint against the approver's expectation before
  the session is issued.

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
  client-side encryption path is unbuilt.

---

## Open — Tier 4: scale & ops

Smaller, well-bounded, and safe to defer.

- [ ] **M. Single SQLite connection serializes all I/O.**
  `storage.Open` sets `SetMaxOpenConns(1)`. Correct for write safety,
  but WAL mode allows concurrent readers. For the documented
  small-instance target this is fine; for scale, separate reader and
  writer connection pools and switch readers to deferred transactions.

- [ ] **H. Schema migrations have no integrity check.**
  `migrationApplied()` only looks at `schema_migrations.version`.
  Add a content checksum column so silent edits to applied SQL files
  are detected on next startup.

- [ ] **N. `Hub.Publish` drops events on full client buffer.**
  Recovery via DB-backed `/sync/events` exists. Document the contract
  in `realtime/hub.go` so the drop semantics aren't a surprise.

- [ ] **Dependabot alerts.** GitHub flagged 2 moderate alerts on
  `ServesYouRice/Veritra` after each push. Triage them; bump or pin
  affected transitive deps.

---

## Done

### 2026-05-29 — Tier 2 (spec gaps) — commit `f6f844d`

- **L. Login device attribution.** When no `device_id` is provided,
  `LoginRecord` now picks the most-recently-active device
  (`COALESCE(last_seen_at, created_at) DESC`) instead of the oldest.
  Combined with the `last_seen_at` stamping from Tier 1, login attaches
  to the device a user actually used last.
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
- **`devices.last_seen_at`** stamped on each authenticated request,
  throttled to one write per device per minute.
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
