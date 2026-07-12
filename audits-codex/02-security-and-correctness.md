# Security and correctness

Release-gate security findings R-01, R-06, R-07, R-08, R-09, R-10, R-11, and R-14 are detailed separately in [01-release-gates.md](01-release-gates.md).

## SEC-01 — Moderators can demote conversation owners (High)

- **Evidence:** `AddConversationMember` is an upsert that overwrites an existing role (`server/internal/storage/sqlite.go:890-899`). The handler checks only that the *new* role is not above the caller (`server/internal/httpapi/api.go:573-587`), not the target's current role.
- **Impact:** a moderator can re-add an owner as `member`, taking over or destabilizing conversation governance.
- **Fix:** separate add-member from change-role; load target/current roles in the same transaction; require the target to rank strictly below the actor; preserve at least one owner.

## SEC-02 — Typing events bypass conversation membership (High)

- **Evidence:** the typing route lists members and publishes immediately (`server/internal/httpapi/api.go:618-625`) without calling `IsConversationMember` or `ConversationMemberRole` for the sender.
- **Impact:** any authenticated user with a conversation ID can inject presence events and use responses/timing as a conversation-existence oracle.
- **Fix:** authorize membership first, rate-limit per account/conversation, and avoid durable/logged typing state.

## SEC-03 — Device-bound login proves no possession of the device key (High)

- **Evidence:** login accepts username, password, and `device_id` (`server/internal/httpapi/api.go:157-194`). `LoginRecord` only matches those database fields (`server/internal/storage/sqlite.go:387-403`); there is no nonce signature/challenge.
- **Impact:** a stolen password plus a discoverable device ID creates a session attributed to a key the attacker does not own. The attacker can impersonate metadata and submit arbitrary ciphertext as that device.
- **Fix:** require proof-of-possession over a server nonce plus password/reauth, or treat a new installation as a separately approved device-link flow.

## SEC-04 — WebSocket authorization is a one-time snapshot (High)

- **Evidence:** authentication happens only during upgrade (`server/internal/httpapi/api.go:1091-1099`). Logout/device revocation explicitly disconnects clients (`api.go:1112-1159`), but account deletion does not (`api.go:1082-1089`), and session expiry is not rechecked.
- **Impact:** deleted accounts and expired sessions can remain subscribed until the transport happens to close.
- **Fix:** bind connection lifetime to session expiry; disconnect by account on deletion/logout-all; revalidate privileged state or use a revocation generation.

## SEC-05 — There is no password change or recovery path (High)

- **Evidence:** the route table at `server/internal/httpapi/api.go:31-64` has login/logout but no password update, reset, or offline owner recovery operation.
- **Impact:** a leaked password cannot be rotated, and a forgotten password can permanently strand an account/instance.
- **Fix:** design password change with recent-password/device proof; design privacy-preserving recovery explicitly; document what recovery can and cannot restore under E2EE.

## SEC-06 — Sensitive account actions require no recent reauthentication (High)

- **Evidence:** account deletion, logout-all, device revocation, invite creation, and device-link approval rely on any bearer session (`server/internal/httpapi/api.go:38-45,58`) without a recent-auth or second-factor check.
- **Impact:** a stolen 30-day token can destroy or expand account access without knowing the password or possessing the device key.
- **Fix:** introduce short-lived sudo/recent-auth grants backed by password plus device proof for destructive and trust-expanding actions.

## SEC-07 — Invites can be permanent but cannot be listed or revoked (High)

- **Evidence:** the UI offers “Never” expiry (`mobile/lib/features/settings/invite_screen.dart:66-83`). The schema has `revoked_at`, but the API exposes only invite creation and registration (`server/internal/httpapi/api.go:40-41`); there is no list/revoke route. Account deletion does not revoke outstanding invites.
- **Impact:** a copied invite can remain a long-lived, unmanageable instance-entry credential.
- **Fix:** default to short expiry and one use; add list/revoke/audit; revoke on owner deletion or compromise; cap active invites.

## SEC-08 — Identity fields are not validated at the API boundary (Medium)

- **Evidence:** owner/registration validate password, device name, and key-package presence but not username or email (`server/internal/httpapi/api.go:102-135,206-235`). Username normalization only trims/lowercases (`server/internal/domain/types.go:223-225`).
- **Impact:** empty/oversized/control-character names and malformed email reach SQLite; uniqueness/check failures become generic 500s and inconsistent UI behavior.
- **Fix:** define Unicode normalization, length/character policy, reserved names, and optional-email syntax; map uniqueness to 409; test byte and grapheme limits.

## SEC-09 — Conversation shape and membership invariants are incomplete (High)

- **Evidence:** the handler validates only the kind and retention (`server/internal/httpapi/api.go:506-525`). It does not require exactly two distinct DM members, bound title/member-list sizes, forbid community/channel IDs on other kinds, or prevalidate active target accounts. Storage checks only part of the `community_channel` shape (`server/internal/storage/sqlite.go:831-879`).
- **Impact:** malformed conversations, accidental mass requests, deleted/nonexistent participants, foreign-key 500s, and ambiguous DM semantics become persistent state.
- **Fix:** encode per-kind invariants in an application service and database constraints where possible; cap/deduplicate members before opening a transaction.

## SEC-10 — Replies and threads can reference another conversation (High)

- **Evidence:** `reply_to_id` and `thread_root_id` are foreign keys only to message IDs (`server/migrations/0001_init.sql:97-98`). Message creation forwards them without same-conversation validation (`server/internal/httpapi/api.go:717-728`).
- **Impact:** a message in conversation A can reference an ID from B, leaking identifiers and corrupting thread/reply integrity.
- **Fix:** load referenced envelopes and enforce matching `conversation_id` inside the message transaction; reject deleted/expired references as defined by protocol.

## SEC-11 — Test cryptography is shippable and server-accepted (High)

- **Evidence:** `TestOnlyCryptoService` lives under production `mobile/lib` and emits `TEST_ONLY_DEVICE_KEY_PACKAGE` / `test-only-not-production` (`mobile/lib/crypto/crypto_service.dart:22-40`). The server rejects only one unrelated exact placeholder (`server/internal/httpapi/api.go:1316-1318`).
- **Impact:** an accidental wiring/build-flag error can register obviously fake key material and appear functional enough to reach production.
- **Fix:** move fakes under `test/`; reject all reserved test protocol/key markers; add release-mode assertions and an end-to-end production-crypto readiness check.

## SEC-12 — Account export omits material account data (Medium)

- **Evidence:** `ExportAccount` returns account, devices, conversations, and message pages only (`server/internal/storage/sqlite.go:1550-1583`). It excludes memberships/roles, invites, attachments/blobs, reactions, read receipts, push subscriptions, backup records, calls, and audit metadata.
- **Impact:** the endpoint cannot serve as a complete portability/privacy export and gives operators no completeness contract.
- **Fix:** define an export manifest/version, include every user-associated category or explicitly document exclusions, and stream/checksum large encrypted blobs.

## SEC-13 — Reactions are write-only to recipients (High)

- **Evidence:** reaction ciphertext is stored (`server/internal/storage/sqlite.go:1439-1456`), but the sync/realtime payload includes only message and account IDs (`server/internal/httpapi/api.go:783-815`). Message listing has no reactions, and there is no list/remove route.
- **Impact:** recipients learn that a reaction exists but cannot fetch/decrypt it; overwrite/removal semantics are unusable.
- **Fix:** define encrypted reaction retrieval and tombstones, include opaque ciphertext or a fetch reference in durable events, and test multi-device convergence.

## SEC-14 — Blob APIs are upload-only and have no storage budgets (High)

- **Evidence:** attachments and backups expose only POST routes (`server/internal/httpapi/api.go:49-50,59,894-975`). `uploads.Store.Open` exists but is not routed. There are per-request 50/100 MiB caps but no per-account, per-conversation, or global quota.
- **Impact:** features cannot be downloaded/restored, while any authenticated account can repeatedly fill the host disk. Unscoped attachments are accepted without a conversation ID.
- **Fix:** add authorized list/get/delete flows, resumable integrity-checked transfer, ownership/scope rules, atomic metadata/blob cleanup, quotas, disk reserve, and operator alerts.

## SEC-15 — Disappearing-message retention leaves attachment blobs behind (High)

- **Evidence:** expiry pruning deletes only `message_envelopes` (`server/internal/storage/sqlite.go:1254-1262`). Attachment references are JSON rather than relational ownership, and attachment rows/blobs have no expiry cascade.
- **Impact:** users can believe an expiring message disappeared while its encrypted attachment and metadata remain indefinitely.
- **Fix:** model message-to-attachment references relationally; assign expiry/refcounts; delete orphaned rows and blobs transactionally/retryably; disclose any backup exception.

## SEC-16 — Communities have no coherent multi-user authorization model (High)

- **Evidence:** community creation adds only the creator as a member (`server/internal/storage/sqlite.go:755-780`). There is no community member add/list route. Initial members of a channel-backed conversation are not required to be community members (`sqlite.go:831-879`).
- **Impact:** communities cannot be administered as shared spaces, and channel conversations can contain accounts outside the community boundary.
- **Fix:** define community membership/roles/invites, enforce community membership for channel conversations, and emit durable membership events.

## SEC-17 — Call signaling accepts arbitrary durable metadata and has no lifecycle (Medium)

- **Evidence:** `POST /calls` stores caller-controlled JSON and hardcodes state `ringing` (`server/internal/httpapi/api.go:1009-1025`; `server/internal/storage/sqlite.go:1515-1535`). There are no accept/reject/end/timeout routes or pruning.
- **Impact:** rows remain stuck forever; oversized/undefined metadata enters storage/sync; clients cannot converge on call state.
- **Fix:** version and bound signaling envelopes, make sensitive fields end-to-end encrypted, define a state machine with idempotent transitions and expiry, and prune terminal/abandoned calls.

## SEC-18 — Message idempotency races and duplicate retries emit new events (High)

- **Evidence:** `SaveMessageEnvelope` checks idempotency through the reader pool, then inserts separately through the writer (`server/internal/storage/sqlite.go:1020-1068`). Concurrent equal requests can both see no row; the second hits the unique constraint instead of returning the winner. Even a sequential duplicate still creates and publishes a fresh sync event because `duplicate` affects only HTTP status (`server/internal/httpapi/api.go:717-742`).
- **Impact:** concurrent network retries can become 500s, while successful retries fan out duplicate notifications/events for one envelope.
- **Fix:** perform insert-or-select atomically on the writer transaction, verify a reused key matches the original immutable request, and publish no new event for a duplicate.

## SEC-19 — Sensitive API responses do not explicitly prohibit caching (Medium)

- **Evidence:** security middleware sets referrer, MIME, frame, origin, permissions, HSTS, and setup CSP headers, but not `Cache-Control: no-store` (`server/internal/app/app.go:152-168`). Auth responses, devices, export, sync, and metadata routes return private data.
- **Impact:** browsers, embedded clients, or misconfigured intermediaries can retain credentials or sensitive metadata longer than intended.
- **Fix:** set `Cache-Control: no-store, private` (and compatible legacy controls where needed) on auth and authenticated API responses; test headers through Caddy.
