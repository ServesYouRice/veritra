# Logical and Implementation Issues

**Audit date:** 2026-07-21  
**Application-logic verdict:** No-go

## Findings

### LOG-01 — Conversation key-package claiming queries a nonexistent table

| Field | Detail |
| --- | --- |
| Severity | Critical |
| Location | `server/internal/storage/key_package_store.go:70-90`; migrations `0001`–`0017` |
| Blocker before production | **Yes** |

**Description:** `ClaimConversationKeyPackages` queries and joins `conversation_members`, but the schema defines conversation membership in `memberships`. No migration creates `conversation_members`.

**Why it matters:** `POST /api/v1/conversations/{id}/key-packages/claim` returns a storage failure for every real conversation. MLS group creation/add-device flows cannot obtain recipient key packages.

**Recommended fix:** Change both queries to the authoritative `memberships` table, preserve the all-or-nothing claim transaction, and add a migration-backed integration test that creates a conversation with multiple devices and claims exactly one package per other active device.

**Risks/dependencies:** This sits directly on the crypto roster path. Verify revoked devices, missing packages, duplicate claims, concurrent claimers, expiry, blocking, and rollback semantics.

### LOG-02 — Production crypto is not connected to application state

| Field | Detail |
| --- | --- |
| Severity | Critical |
| Location | `mobile/lib/main.dart:19`; `mobile/lib/crypto`; `crypto/rust/src/ffi.rs`; `scripts/release-readiness.sh` |
| Blocker before production | **Yes** |

**Description:** The Rust crate has tested MLS primitives and ABI v2 operations, but the Flutter app uses the fail-closed service. Native libraries are not packaged, group state is not orchestrated, and encrypt/decrypt/group membership is not connected to sync/outbox behavior.

**Why it matters:** Core messaging cannot work, and a partial integration could create epoch rollback, key reuse, or false device-removal claims.

**Recommended fix:** Implement the documented crypto contract end to end: native packaging, handle lifecycle, protected state-key handling, restore/seal with monotonic counter, key-package replenishment, create/join/add/remove/update/commit processing, authenticated payload validation, and atomic state/cursor commits.

**Risks/dependencies:** Requires protocol interoperability vectors, multi-device/offline convergence tests, secure storage redesign, mobile platform review, and independent cryptographic review. Keep the release gate until all are complete.

### LOG-03 — Mobile persistence has lost-update races and unsafe record size

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `mobile/lib/storage/local_store.dart:146-354`; foreground `AppState`; `mobile/lib/push/background_push.dart` |
| Blocker before production | **Yes** |

**Description:** Session, cursor, snapshot, outbox, and sealed crypto state share one JSON value in `FlutterSecureStorage`. Every method independently reads, mutates, and rewrites it without serialization. Foreground sync, sends, and headless push can overwrite each other's changes. The record can also contain 20 conversations × 200 ciphertext envelopes plus a 32 MiB sealed-state allowance, far beyond appropriate keychain/preference value sizes. A JSON decode error deletes the entire record.

**Why it matters:** Normal concurrency can lose queued messages, roll back cursors/crypto state, or erase the session. Oversized keychain writes can fail or become extremely slow. Crypto rollback is a security failure, not only a cache miss.

**Recommended fix:** Store only a non-exportable/wrapped database key and minimal credentials in secure storage. Move snapshots, outbox, and sealed group state to an encrypted transactional local database. Serialize all mutations and atomically commit crypto counter/state with the processed sync cursor.

**Risks/dependencies:** Requires schema migration, crash recovery, background-isolate coordination, rollback detection, corrupt-state UX, and concurrency tests. Never silently reset cryptographic state on decode failure.

### LOG-04 — Many durable mutations are not atomic with their sync event

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `server/internal/httpapi/conversation_handlers.go:280-546`; `call_sync_handlers.go`; `auth_handlers.go`; `Store.SaveSyncEvent` |
| Blocker before production | **Yes** |

**Description:** Message creation correctly commits its sync event transactionally. Edits, deletes, reactions, receipts, retention changes, calls, and some device events update state first and call `saveSyncEvent` afterward. That helper logs and swallows insert failure, publishes realtime with event ID `0`, and still returns success.

**Why it matters:** Offline devices can permanently miss a mutation. A missed encrypted delete marker is especially harmful because users may believe content was removed while another device never learns the new state.

**Recommended fix:** Add store/service methods that commit each durable mutation and its durable event in one transaction and return the event/recipients. If event persistence fails, roll back and return an error; publish only after commit with a valid positive ID.

**Risks/dependencies:** Requires failure-injection tests and idempotency rules for every mutation. Best-effort typing can remain non-durable and should be clearly separated.

### LOG-05 — Realtime per-IP limits collapse behind the supported proxy

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `server/internal/httpapi/call_sync_handlers.go:202-215`; `server/internal/realtime/hub.go:16-66`; `deploy/docker-compose.yml` |
| Blocker before production | **Yes** |

**Description:** HTTP throttling resolves a trusted proxy chain, but `syncWebSocket` sends raw `r.RemoteAddr` to the hub. Behind Caddy, all users appear to come from the proxy container address and share the 20-connection IP cap.

**Why it matters:** The 21st active socket for an otherwise healthy instance is rejected and clients enter reconnect loops. This occurs on the documented public deployment path.

**Recommended fix:** Centralize trusted client-IP resolution and pass the same resolved value to HTTP and WebSocket limits. Add a test with a trusted proxy plus distinct `X-Forwarded-For` clients and a spoofed-header negative case.

**Risks/dependencies:** Do not trust forwarded headers from untrusted peers. Retain account/device caps as the primary authenticated controls.

### LOG-06 — A direct message can be expanded into a multi-user conversation

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `server/internal/storage/community_store.go:794-853`; `POST /api/v1/conversations/{id}/members` |
| Blocker before production | **Yes** |

**Description:** DM creation enforces exactly two accounts, but `ManageConversationMember` does not check conversation kind and can add a third account later.

**Why it matters:** Participants and clients may continue treating the thread as a two-party private channel while server routing now includes another account. That breaks a foundational privacy invariant.

**Recommended fix:** Reject member mutations for `kind='dm'`. If conversion is desired, create a new group with explicit user confirmation and a fresh MLS group/roster.

**Risks/dependencies:** Audit existing databases for DMs with more than two members and define a safe remediation that does not silently drop access or cryptographic state.

### LOG-07 — Conversation membership has no complete lifecycle

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `server/internal/httpapi/api.go`; conversation/community handlers and stores |
| Blocker before production | **Yes** |

**Description:** Conversation membership can be added/role-updated, but there is no scoped conversation-member list, remove/kick, or leave route. Community membership similarly lacks a complete removal lifecycle. Conversation/community deletion is absent.

**Why it matters:** Users cannot revoke future routing access, leave harassment, or administer stale groups. Server authorization and MLS membership cannot be reconciled.

**Recommended fix:** Define list/change/remove/leave semantics with last-owner rules, audit events, durable sync events, and explicit MLS commit acknowledgements. Treat server removal as routing revocation until clients complete cryptographic removal.

**Risks/dependencies:** Offline devices, failed MLS commits, owner transfer, blocked accounts, channel inheritance, and historical ciphertext access all need protocol decisions.

### LOG-08 — Durable sync references cannot reliably repair older messages

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `server/internal/storage/message_store.go:523-614`; sync payloads; `mobile/lib/core/app_state.dart:930-1002`; message API routes |
| Blocker before production | **Yes** |

**Description:** Durable message mutation events contain a message ID reference, but there is no authenticated `GET /messages/{id}` endpoint. Mobile catch-up refreshes only the newest page of the currently selected conversation; unselected/older messages are not repaired.

**Why it matters:** Edits/deletions outside the newest page can stay stale forever, even though the cursor advances past their event.

**Recommended fix:** Either include the complete authorized encrypted envelope/tombstone in durable events or add a member-authorized single-message fetch. Process events per conversation before advancing the cursor, and retain paginated history merge state.

**Risks/dependencies:** Block filtering, expiry, deletion tombstones, membership changes, and authenticated payload references must remain consistent.

### LOG-09 — Large authorized downloads are forced through a 30-second deadline

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `server/internal/app/app.go:151-173`; `server/internal/httpapi/content_handlers.go:166-209` |
| Blocker before production | **Yes** for backup/recovery claims |

**Description:** Only exact collection paths `/attachments` and `/backups` receive the 15-minute deadline. Item downloads under `/attachments/{id}` and `/backups/{id}` use the default 30-second context/write deadline.

**Why it matters:** Slow clients cannot reliably download allowed 50–100 MiB ciphertext, making backup recovery and attachments fail in normal network conditions.

**Recommended fix:** Classify subroutes explicitly, apply a suitable streaming deadline, support HTTP Range/resume, and test throttled large downloads through Caddy.

**Risks/dependencies:** Preserve authorization before streaming, bounded resources, cancellation, and rate/egress controls.

### LOG-10 — One poison outbox item blocks every later message

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `mobile/lib/core/app_state.dart:1064-1092` |
| Blocker before production | No, but fix before broad beta |

**Description:** `_flushOutbox` wraps the whole loop in one `try`. The first failure stops processing and marks all entries failed. Permanent 4xx errors are retained and retried on every reconnect.

**Why it matters:** One malformed or authorization-rejected envelope can indefinitely block valid later messages and cause repeated network load.

**Recommended fix:** Handle each envelope independently; classify terminal vs retryable errors; quarantine terminal items with a user-visible action; use bounded exponential backoff and continue with later independent messages where MLS ordering permits.

**Risks/dependencies:** MLS epoch ordering may require per-conversation queues even when different conversations can progress independently.

### LOG-11 — Shared global busy/error state creates cross-feature races

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `mobile/lib/core/app_state.dart:_run`; multiple Flutter screens |
| Blocker before production | No |

**Description:** Unrelated operations share one `busy` boolean and one `error` string. Concurrent calls can clear each other's error, re-enable controls while another operation is active, or show a failure in the wrong screen.

**Why it matters:** Real users perform overlapping refresh, send, settings, and sync actions; the UI can misreport outcome or permit duplicate submissions.

**Recommended fix:** Model operation-specific immutable states or scoped controllers, with per-resource loading/error/result values and idempotent submission guards.

**Risks/dependencies:** Avoid proliferating notifiers that trigger whole-app rebuilds; test interleaved operations.

### LOG-12 — Duplicate DMs and empty groups are valid server state

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `server/internal/storage/community_store.go:650-770`; `mobile/lib/features/search/search_screen.dart`; new-conversation sheet |
| Blocker before production | No, after DM identity is fixed |

**Description:** No uniqueness/canonicalization prevents multiple DMs for the same account pair. Search creates a new one on every account tap. Group creation accepts no title and no other members.

**Why it matters:** Duplicate indistinguishable threads fragment history, unread state, and future MLS groups; empty groups create clutter and undefined product behavior.

**Recommended fix:** Add a canonical unordered DM-pair identity with conflict-safe get-or-create semantics. Define and enforce minimum group title/member rules in both API and client.

**Risks/dependencies:** Existing duplicates need a non-destructive presentation/migration strategy; never merge MLS histories implicitly.

### LOG-13 — Enrollment reservation endpoints miss the stricter auth rate class

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `server/internal/app/app.go:511-519`; setup/register/device-link enrollment routes |
| Blocker before production | No |

**Description:** `isAuthEndpoint` includes final setup/register/claim calls but omits `/setup/owner/enrollment`, `/register/enrollment`, and `/device-links/claim-enrollment`. These unauthenticated routes use the much looser general limit while creating short-lived database reservations and performing validation.

**Why it matters:** Attackers can cause unnecessary DB growth/work and probe setup/invite/link state faster than intended.

**Recommended fix:** Put every unauthenticated enrollment/reservation route in an endpoint-specific strict limiter, cap outstanding reservations by source and parent token/invite/link, and return `Retry-After`.

**Risks/dependencies:** Limits must work behind trusted proxies and avoid locking out legitimate NATed self-hosted users.

### LOG-14 — Post-commit blob deletion failures have no reconciliation path

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | attachment/backup/account delete handlers; `app.runRetentionSweeper`; local blob store |
| Blocker before production | No |

**Description:** Database rows are deleted first, then files are removed. File failures are logged, but there is no durable cleanup queue or storage reconciliation command.

**Why it matters:** Ciphertext blobs can accumulate indefinitely, consume the volume, and remain in backups after users believe their account-controlled blobs were removed.

**Recommended fix:** Persist deletion work in the same DB transaction, retry idempotently, and add a privacy-safe doctor/reconcile mode that compares storage keys without logging content or secrets.

**Risks/dependencies:** Reconciliation must never delete files referenced by a committed row and needs backup/restore coordination.

## Production Blockers

- [ ] `LOG-01`: Repair key-package membership queries and prove atomic claims.
- [ ] `LOG-02`: Complete mobile MLS integration and independent review.
- [ ] `LOG-03`: Replace racy/oversized secure-storage persistence.
- [ ] `LOG-04`: Make every durable mutation atomic with its sync event.
- [ ] `LOG-05`: Resolve trusted client IPs consistently for realtime limits.
- [ ] `LOG-06`: Enforce the exactly-two-account DM invariant.
- [ ] `LOG-07`: Complete member list/leave/remove lifecycle with MLS coordination.
- [ ] `LOG-08`: Make durable sync able to repair any affected message.
- [ ] `LOG-09`: Make large encrypted downloads reliable.
- [ ] Restore green server/mobile baselines; see `testing-gaps.md`.

