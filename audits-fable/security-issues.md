# Security Issues — Veritra Audit (audits-fable)

Authorization, authentication, abuse resistance, and privacy findings. The codebase already has an unusually strong security baseline for an MVP (constant-time login, hashed tokens, fail-closed crypto boundary, checksummed migrations, origin-checked WebSockets, trusted-proxy-aware rate limiting). These findings are what remains.

**Context:** Prior audits (`OPUS.md`, `CODEX.md`, `FABLE.md`) were largely addressed; this reflects the current tree at `c939f26`.

> **Historical snapshot:** findings and severities describe `c939f26`, not the
> current tree. Use [`../audits-codex/README.md`](../audits-codex/README.md) for
> current release status.

---

## Summary table

| ID | Title | Severity | Blocker |
|---|---|---|---|
| SEC-1 | Conversation role demotion via member re-add upsert | High | Yes |
| SEC-2 | `typing` endpoint has no membership check | Medium | Yes |
| SEC-3 | Anyone can add anyone to conversations; nonexistent-ID errors form an account oracle | Medium | Yes |
| SEC-4 | No storage quotas: unlimited 50–100 MB uploads per account | High | Yes |
| SEC-5 | Static 30-day bearer tokens; no rotation, no inactivity timeout | Medium | No |
| SEC-6 | Account deletion is soft and leaves messages, attachments, backups, username | Medium | No |
| SEC-7 | Account deletion / device revoke need no password re-confirmation | Medium | No |
| SEC-8 | Push subscription endpoint stores arbitrary URLs (future SSRF surface) | Low | No |
| SEC-9 | `/metrics` is unauthenticated when enabled | Low | No |
| SEC-10 | No per-account WebSocket connection cap | Low | No |
| SEC-11 | Rate-limiter saturation locks out *new* clients first | Low | No |
| SEC-12 | Unlimited communities/conversations/invites per account (metadata spam) | Low | No |
| SEC-13 | Verification-code compare is constant-time but approval attempts are not specially limited | Info | No |
| SEC-14 | Exact-match username search is an intentional, documented enumeration primitive | Info | No |

---

## SEC-1 — Conversation role demotion via member re-add upsert

- **Severity:** High
- **Location:** `server/internal/storage/sqlite.go:890-900` (`AddConversationMember` uses `ON CONFLICT(account_id, conversation_id) DO UPDATE SET role = excluded.role`), guarded only by `server/internal/httpapi/api.go:573-586`
- **Description:** The members endpoint checks that the caller can manage members and cannot grant a role **above** their own — but "adding" an existing member silently **overwrites** that member's role via the upsert. Granting a role *below* your own is always allowed. So a `moderator` of a group can re-add the group's `owner` with `role: member`, demoting them. The demoted owner (instance-level `member`) loses `CanManageMembers`/retention rights in that conversation, and the attacker becomes the effective top rank.
  - Concrete replay: Alice (conv owner, instance member) creates a group and promotes Bob to moderator. Bob calls `POST /conversations/{id}/members {"account_id": "<alice>", "role": "member"}`. Check `RoleRank("member")=1 > RoleRank("moderator")=2` is false → allowed → Alice's membership row is updated to `member`. Bob now outranks everyone.
  - Instance owners/admins are shielded only because `effectiveConversationRole` takes the max of instance and conversation role — ordinary users who own groups are not.
- **Why it matters:** This is a working privilege-escalation path in shipped, functional code (membership management does not depend on the missing crypto). It also enables member-role griefing at scale.
- **Recommended fix:** Split "add" from "change role": make `AddConversationMember` use `DO NOTHING` (or reject with `409 already_member`), and add an explicit role-change path that additionally requires the caller to outrank the *target's current* role (standard rule: you may only modify members strictly below you). Add a regression test: moderator attempts to demote owner → 403.
- **Blocker:** Yes.
- **Related risks:** The same handler is the place to fix SEC-3; do them together.

## SEC-2 — `typing` endpoint has no membership check

- **Severity:** Medium
- **Location:** `server/internal/httpapi/api.go:618-625` (`conversationSubroute`, `typing` case)
- **Description:** Any authenticated user can `POST /api/v1/conversations/{any-id}/typing`. The handler fetches the member list and publishes a `typing.updated` event to all members without verifying the caller belongs to the conversation. This permits spoofed typing signals in arbitrary known conversations. The original audit also called this a conversation-ID existence oracle; that part was incorrect because an unknown ID produced an empty member list and the same 204 response.
- **Why it matters:** Cross-conversation event injection breaks the isolation model, and it's the only conversation-scoped route without the guard — clearly an oversight, cheap for an attacker to find.
- **Recommended fix:** Add the same `IsConversationMember` check used by `MarkRead` before publishing; return 403 otherwise. One test.
- **Blocker:** Yes (trivial fix).

## SEC-3 — Unconsented adds + account-ID validity oracle

- **Severity:** Medium
- **Location:** `server/internal/storage/sqlite.go:816-900` (`CreateConversation` member loop, `AddConversationMember`), `server/internal/httpapi/api.go:506-535`, `:554-592`
- **Description:** Two related problems:
  1. **No consent:** any user can create a conversation naming any account IDs, or add accounts to conversations they moderate. Targets are joined instantly with no invitation/accept step and (per LOG-4) not even a notification. In an invite-only single instance this is bounded, but it is the harassment/spam primitive of the platform.
  2. **Identifier-validity oracle:** membership rows FK-reference `accounts(id)`. A guessed/nonexistent account ID makes the insert fail → `500 storage_error`, while a valid ID yields 200/201. Account IDs contain 128 random bits so guessing is impractical, but IDs leak through legitimate channels. This distinguishes an existing row from an unknown ID; it does **not** reliably reveal deletion status because account deletion was soft and retained the row.
- **Why it matters:** For a privacy-first messenger, "anyone can silently put you in a room" is a product-level privacy defect; the oracle is a lesser but free fix.
- **Recommended fix:** Validate member IDs inside the creation transaction and return `404 account_not_found` uniformly (fixes the 500 and narrows the oracle to what search already reveals). Product-level: add an invitation/accept model, or at minimum only allow initial members on `dm` (single counterpart) and require joins-by-invite for groups. Skip adding `deleted_at IS NOT NULL` accounts.
- **Blocker:** Yes for consistent validation/error handling; the consent model can be a fast-follow with LOG-13.

## SEC-4 — No storage quotas on uploads

- **Severity:** High
- **Location:** `server/internal/httpapi/api.go:894-975` (`uploadAttachment` 50 MiB/req, `uploadBackup` 100 MiB/req), `server/internal/uploads/local.go`, `server/internal/storage/sqlite.go:1414-1437`, `:1538-1548`
- **Description:** Any authenticated account can upload unlimited numbers of attachment blobs (conversation membership only checked when `conversation_id` is supplied — omit it and the blob is an unscoped orphan) and unlimited 100 MiB "backups". There is no per-account byte quota, no per-account object count, no backup-count cap (old backups are never replaced or expired), and no global disk watermark. The general rate limit (240 req/min/IP) permits a theoretical maximum of about 23.4 GiB/min of 100 MiB backup uploads from a single IP, before protocol overhead and other bottlenecks.
- **Why it matters:** A single invited user — or one compromised session — can fill the server's disk in minutes. On a single-binary SQLite deployment, disk exhaustion takes down the database and the whole instance. This is the cheapest DoS in the system and requires no bugs, just intended APIs.
- **Recommended fix:** (1) Per-account storage quota (configurable, e.g. 1 GiB default) enforced transactionally against a maintained per-account byte total. (2) Keep only N most-recent backups per account/device, deleting older blobs. (3) Require `conversation_id` on attachments (or auto-expire unattached blobs after 24 h). (4) Optional global free-disk floor check before accepting uploads.
- **Blocker:** Yes — must land no later than the first release where uploads are reachable from a client.
- **Related risks:** LOG-3 (write-only endpoints), SEC-6 (deletion doesn't reclaim blobs).

## SEC-5 — Static 30-day bearer tokens

- **Severity:** Medium
- **Location:** `server/internal/httpapi/api.go:149,189,249,433` (fixed `30*24*time.Hour` at every session mint), `auth.NewToken`
- **Description:** Sessions are opaque 256-bit tokens (good), stored hashed (good), but: fixed 30-day validity, no sliding renewal, no refresh-token rotation, no inactivity expiry, and no way for a client to renew short of a full password login (which itself requires the linked device). Combined with LOG-5, every install dies every 30 days; combined with token theft, a stolen token is valid for up to 30 days unless the user notices and revokes.
- **Why it matters:** Session lifetime policy is the main blast-radius control for token compromise on mobile.
- **Recommended fix:** Sliding expiry (extend on use, absolute cap ~90 days) is the smallest change fitting the current schema; note it makes tokens hit the DB with a write, so batch (extend at most once/day). Alternatively adopt refresh rotation. Also stamp `devices.last_seen_at` here — it is currently read but never written (acknowledged in `WORK_IN_PROGRESS.md`), which undermines the device-review UI in Settings.
- **Blocker:** No (LOG-5 handles the UX cliff), but decide before the token format is load-bearing.

## SEC-6 — Account deletion is soft and incomplete

- **Severity:** Medium
- **Location:** `server/internal/storage/sqlite.go:1586-1611` (`DeleteAccount`: sessions deleted, devices revoked, account row marked deleted), `mobile/lib/features/settings/settings_screen.dart:159-162` (UI promises "Permanently removes your account and data")
- **Description:** Deletion leaves in place: all message envelopes (ciphertext, but with full sender/recipient/timing metadata), all attachment blobs and rows, all backup blobs (encrypted with the user's keys — pure dead weight plus metadata), memberships, read receipts, reactions, and the username itself (`UNIQUE` means it can never be re-registered, and it remains recoverable from the row). The mobile UI explicitly promises permanent removal of "your account and data".
- **Why it matters:** For a privacy-first product this is a trust and (in the EU) a GDPR Art. 17 problem. The gap between UI promise and behavior is the worst part — it's a documented misrepresentation.
- **Recommended fix:** Decide and document a deletion contract. Minimum viable: delete backup blobs + unscoped attachments + push subscriptions immediately; null out email/username (replace username with `deleted_<id>` to free it); optionally purge or tombstone authored envelopes after a grace window. Until then, fix the Settings copy to match reality.
- **Blocker:** No technically; yes reputationally if marketed as privacy-first.

## SEC-7 — Destructive account actions need no re-authentication

- **Severity:** Medium
- **Location:** `server/internal/httpapi/api.go:1082-1089` (`deleteAccount`), `:1147-1160` (`revokeDevice`), `:1131-1143` (`logoutAll`)
- **Description:** A bearer token alone irreversibly deletes the account, revokes devices, or kills all other sessions. Anyone who briefly holds an unlocked phone — or any token exfiltration — can destroy the account with one request. The mobile app shows a confirm dialog, but the API is the boundary.
- **Recommended fix:** Require the current password (or a fresh sudo-mode re-auth) in the request body for `DELETE /account`, and consider it for `revokeDevice` of *other* devices. Rate-limit these endpoints in the auth bucket.
- **Blocker:** No.

## SEC-8 — Push subscription endpoints are stored unvalidated (future SSRF)

- **Severity:** Low (today), Medium once push ships
- **Location:** `server/internal/httpapi/api.go:977-994`, `server/internal/storage/sqlite.go:1489-1496`
- **Description:** `provider` and `endpoint` are arbitrary strings. No provider allowlist, no URL parse, no scheme restriction, no length cap. Today nothing dereferences them (`DisabledProvider`), but the moment a UnifiedPush-style provider POSTs to stored endpoints, this becomes a server-side request forgery primitive (internal network probing via `http://10.0.0.1/...` endpoints).
- **Recommended fix:** Validate now: allowlist `provider ∈ {apns, fcm, unifiedpush}`, require `https` absolute URL, cap length (≤2 KB), and when implementing the sender: resolve-and-block private IP ranges, no redirects.
- **Blocker:** No (pre-positioning).

## SEC-9 — `/metrics` unauthenticated when enabled

- **Severity:** Low
- **Location:** `server/internal/app/app.go:73-75`
- **Description:** With `PRIVATE_MESSENGER_ENABLE_METRICS=1`, `/metrics` is served on the same listener as the public API with no auth. Contents are low-sensitivity (request counters), but it advertises server internals and will grow (operators will add richer metrics here first).
- **Recommended fix:** Bind metrics to a separate localhost-only listener or require a static bearer token; document that it must not be exposed through the reverse proxy (the sample Caddyfile currently proxies everything).
- **Blocker:** No.

## SEC-10 — No per-account WebSocket connection cap

- **Severity:** Low
- **Location:** `server/internal/realtime/hub.go:27-36`, `server/internal/httpapi/api.go:1091-1099`
- **Description:** Each `/sync/ws` upgrade registers a client with a goroutine and a 32-slot buffer; nothing caps connections per account/device. The 240 req/min/IP limiter throttles the *rate* of connects, not the standing count — a patient client can accumulate thousands of parked sockets/goroutines.
- **Recommended fix:** Cap concurrent sockets per account (e.g., 8 — one per device is the honest need) and/or per device (1, replacing the old on new connect).
- **Blocker:** No.

## SEC-11 — Rate-limiter map saturation locks out new clients first

- **Severity:** Low
- **Location:** `server/internal/app/app.go:297-346` (`maxRateLimitEntries = 65536`; when full, *unknown* keys get 429 while existing buckets keep working)
- **Description:** An attacker cycling ≥65k source IPs (IPv6 makes this trivial) fills the bucket map; from then until cleanup (≤1 min granularity), every *new* legitimate IP is rejected while the attacker's established buckets continue. The design fails closed for newcomers, open for the attacker.
- **Recommended fix:** Acceptable for MVP; note it in ops docs and prefer edge-level rate limiting (Caddy) for internet-exposed deployments. A future improvement is per-/64 IPv6 bucketing and LRU eviction instead of hard rejection.
- **Blocker:** No.

## SEC-12 — Unlimited metadata-object creation

- **Severity:** Low
- **Location:** `createCommunity`, `createConversation`, `createInvite` handlers (rate limit only)
- **Description:** Any member can create communities and conversations up to the general request-rate limit, with no aggregate per-account cap or cleanup of empty conversations. Invite creation is restricted to owners/admins; each invite is bounded to 1–10,000 uses, but the number of invite rows per authorized account is uncapped and non-expiring invites had no revoke endpoint. This is primarily DB-bloat and admin-surface risk; community/channel search remains membership-scoped.
- **Recommended fix:** Per-account creation caps (daily) and an admin-visible count; low priority on invite-only instances.
- **Blocker:** No.

## SEC-13 — Device-link approval brute-force bounds (informational)

- **Severity:** Info — currently acceptable
- **Location:** `server/internal/storage/sqlite.go:630-691`, `domain.NewVerificationCode` (6 digits)
- **Description:** The verification code has 10^6 space, compared in constant time, and the link expires ≤30 min. Approval attempts fall under the general 240/min bucket (auth bucket covers claim, not approve). Worst case ~7,200 guesses per link lifetime from one IP — 0.7% success; multi-IP raises it. Note also the approve path requires the *account owner's* token, so the attacker model is narrow (an authenticated attacker guessing at their own pending link gains nothing; the code protects the approver from confirming a substituted claim).
- **Recommended fix:** Optionally cap failed approvals per link (e.g., 5 then revoke the link). Cheap hardening, low urgency.
- **Blocker:** No.

## SEC-14 — Username exact-match search (documented tradeoff)

- **Severity:** Info
- **Location:** `server/internal/storage/sqlite.go:1358-1370` (comment documents the reasoning)
- **Description:** Any authenticated user can confirm whether an exact username exists. Substring enumeration was deliberately excluded, and this is required for starting DMs. Fine — flagged only so the tradeoff stays a decision, not an accident. Consider per-account search rate caps if invite scope ever widens.
- **Blocker:** No.

---

## Positive observations (no action needed)

- Login timing-equalized against username enumeration (`VerifyPasswordOrDummy`, eager dummy hash).
- Tokens/claim tokens stored only as SHA-256 hashes; claim token moved to a header to stay out of access logs.
- WebSocket: origin check, mandatory client masking, 1 MiB frame cap, handshake/write deadlines, read-deadline keepalive.
- Plaintext-persistence prohibitions enforced at API and schema level (`CHECK (length(ciphertext) > 0)`), tests assert no sentinel leaks.
- Security headers + `/setup` CSP; HSTS only when TLS is actually terminated locally (correct).
- bcrypt with 12-char minimum and explicit >72-byte rejection.
- Migration checksums block silent drift of applied migrations.
- No request-body or message-content logging; request logs use route classes, not raw paths.
