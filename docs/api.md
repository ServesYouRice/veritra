# API

Base path: `/api/v1`

## Operations

- `GET /livez` reports process liveness. `GET /healthz`, `GET /readyz`, and `GET /api/v1/health` require database migrations and blob storage to be ready.
- `GET /metrics` is available only on the separate management listener when `PRIVATE_MESSENGER_ENABLE_METRICS=1`.

## Setup

- `GET /setup` serves a static notice. Browser owner setup is disabled until a client can generate production device key packages.
- `GET /api/v1/setup/status` returns whether setup is required.
- `POST /api/v1/setup/owner` atomically creates the first owner, device, and session. Remote setup requires `X-Veritra-Setup-Token` to match `PRIVATE_MESSENGER_SETUP_TOKEN`; without a configured token, setup is accepted only from a loopback peer. A real `device_key_package` is always required.
- `POST /api/v1/setup/owner/enrollment` reserves the final account/device IDs
  and returns a short-lived, domain-separated signing challenge before the MLS
  credential is generated.

## Auth and Invites

- `POST /api/v1/auth/login` returns a bearer token for a known local `device_id`. New devices must use device linking instead of password-only login.
- `POST /api/v1/auth/reauth` verifies the password plus device secret and grants five minutes of recent-auth status.
- `POST /api/v1/account/password` rotates the password after recent authentication and revokes other sessions.
- `POST /api/v1/auth/logout` revokes the caller's current session token. Returns `204`.
- `POST /api/v1/auth/logout-all` revokes every session for the account except the caller's current one (sign out other/lost devices). Returns `204`.
- `POST /api/v1/register` consumes an invite and creates account, device, and session.
- `POST /api/v1/register/enrollment` validates the invite and reserves the
  final IDs and enrollment challenge.
- `POST /api/v1/invites` creates invite codes for owner/admin users.
- `GET /api/v1/invites` lists active invites created by the authenticated owner/admin.
- `DELETE /api/v1/invites/{id}` revokes an invite created by the caller. Invites default to one use and a seven-day expiry.

## Devices

- `GET /api/v1/devices/me?limit={n}&after={device_id}` lists the account's devices with a stable cursor.
- `DELETE /api/v1/devices/{id}` revokes one of the caller's devices, deletes its sessions, and disconnects that device's active sync sockets. Returns `204`, or `404` if the device is not the caller's.

## Device Linking

- `POST /api/v1/device-links` creates a short-lived one-time QR/link code from an authenticated existing device.
- `GET /api/v1/device-links/{id}` returns the authenticated account's current link state for approval UX.
- `POST /api/v1/device-links/claim-enrollment` reserves the new device ID and
  returns an account/device-bound enrollment challenge before key generation.
- `POST /api/v1/device-links/claim` verifies the signed key-package enrollment
  proof and lets the new device submit the code and device name. It returns a
  claim token, but not a session.
- `POST /api/v1/device-links/{id}/approve` must be called by an already authenticated device on the same account before the new device is trusted. Body: `{"verification_code":"123456"}`.
- `GET /api/v1/device-links/{id}/claim-status` lets the new device poll for approval using `X-Veritra-Claim-Token`. Once approved, the server creates a device-scoped session and consumes the link.

The verification code returned to both devices must be compared in the client UX before approval. The server stores only public device key-package metadata and never receives private keys.

Owner and invite registration finalization includes the enrollment reservation
ID, public Ed25519 credential key, challenge signature, and key package. The
server verifies the signature and atomically consumes the reservation, binding
the credential to the reserved account/device IDs and preventing replay.

### MLS key packages

- `POST /api/v1/devices/me/key-packages` publishes up to ten signed, expiring MLS 1.0 key packages for the authenticated device. Packages are opaque to the server and limited to the required ciphersuite.
- `POST /api/v1/conversations/{id}/key-packages/claim` atomically consumes one package for every other active device in the conversation. The whole claim fails when any device has no package, preventing partial roster creation or package reuse.

## Communities

- `POST /api/v1/communities` creates a community owned by the caller.
- `GET /api/v1/communities` lists communities visible to the caller.
- `POST /api/v1/communities/{id}/channels` atomically creates a channel and its unique backing conversation.
- `GET /api/v1/communities/{id}/channels` lists channels for a community member.
- `GET /api/v1/communities/{id}/members` lists scoped community membership.

## Messaging

- `POST /api/v1/conversations` creates DMs, groups, or channel-backed conversations.
- `GET /api/v1/conversations?limit={n}&before={conversation_id}` lists visible conversations with a stable cursor.
- `POST /api/v1/conversations/{id}/members` adds members.
- `PUT /api/v1/conversations/{id}/retention` updates disappearing-message retention. New message expiries are capped by this value.
- `POST /api/v1/messages/envelopes` stores ciphertext-only message envelopes.
- `GET /api/v1/conversations/{id}/messages?limit={n}&before={message_id}` lists non-expired encrypted envelopes. `after` is also accepted, but `before` and `after` are mutually exclusive. Responses include `limit` and optional `next_before`.
- `POST /api/v1/conversations/{id}/typing` publishes a best-effort realtime typing event.
- `GET` and `PATCH /api/v1/conversations/{id}/notifications` read or update the caller's notification mute (`{"muted":true}`). Muted conversations do not generate push wakeups for that account.
- `POST /api/v1/messages/{id}/edit` stores an encrypted edit marker/envelope.
- `POST /api/v1/messages/{id}/delete` stores an encrypted delete marker and tombstones the server-held envelope.
- `POST /api/v1/messages/{id}/reactions` stores encrypted reaction payloads.
- `GET /api/v1/messages/{id}/reactions` retrieves encrypted reaction payloads.
- `DELETE /api/v1/messages/{id}/reactions` removes the caller's reaction and emits a tombstone event.
- `POST /api/v1/conversations/{id}/read-receipts` stores read receipt metadata.

Payloads must not include plaintext body fields. Message ciphertext is base64-encoded in JSON.

## Attachments, Backups, and Calls

- `POST /api/v1/attachments?conversation_id={id}` accepts encrypted blobs only when `X-Private-Messenger-Encrypted: 1` is present.
- `POST /api/v1/backups` accepts client-encrypted backup blobs with `X-Key-Derivation-Metadata`.
- `GET /api/v1/attachments` and `GET /api/v1/backups` list the caller's encrypted blobs.
- `GET` and `DELETE` on `/api/v1/attachments/{id}` and `/api/v1/backups/{id}` retrieve or delete authorized ciphertext.
- `POST /api/v1/push/subscriptions` records a `webpush` HTTPS endpoint plus RFC 8291 `public_key` and `auth_secret`. Delivery is enabled only when the operator configures VAPID; payloads remain generic encrypted wake signals.
- `DELETE /api/v1/push/subscriptions/{id}` disables one of the caller's push subscriptions.
- `POST /api/v1/calls`, `GET /api/v1/calls`, and the versioned call transition route provide bounded encrypted signaling with expiry.

Attachment and backup contents are opaque ciphertext to the server. Account and instance quotas are enforced before metadata commits.

## Search and Account Data

- `GET /api/v1/account/blocks` lists accounts blocked by the caller. `PUT /api/v1/account/blocks/{account_id}` blocks an account and `DELETE` removes the block. Blocks prevent new mutual conversation adds and suppress that account's messages, reactions, typing, calls, realtime events, and push wakeups for the blocker.
- `GET /api/v1/search/metadata?q={query}&limit={n}&offset={n}` searches account usernames, visible community names, and visible channel names. Accounts match on the **exact** (case-insensitive) username only; prefix/contains matching is deliberately not offered for accounts so the user directory cannot be enumerated by probing substrings. Communities and channels (which are scoped to the caller's memberships) use exact/prefix matching so the endpoint stays index-friendly. Pagination metadata includes `limit`, `offset`, and optional `next_offset`.
- `GET /api/v1/account/export?limit={n}&before={message_id}` exports account metadata, devices, visible conversations, and encrypted message envelopes. Message export is paginated and returns optional `next_before`.
- `DELETE /api/v1/account` requires recent authentication, revokes access, scrubs account-controlled metadata, removes private blob records/files, and retains only pseudonymous references needed by shared history.

Server-side message-content search is intentionally absent.

## Administration

These routes require an authenticated owner or admin. Status changes and global invite revocation also require recent authentication.

- `GET /api/v1/admin/accounts?limit={n}&after={account_id}` lists non-deleted accounts with username, role, status, device count, encrypted attachment/backup counts, and total encrypted storage bytes.
- `PATCH /api/v1/admin/accounts/{id}/status` accepts `{"status":"suspended"}` or `{"status":"active"}`. Suspension revokes sessions, disables push subscriptions, and disconnects active sync sockets. Administrators may act only on lower-ranked accounts and cannot act on themselves.
- `DELETE /api/v1/admin/invites/{id}` revokes any active invite.
- `GET /api/v1/admin/audit-events?limit={n}&after={event_id}` lists metadata-only operational audit events.

Administrative responses never include message or attachment contents, ciphertext, session tokens, device secrets, password data, or push endpoints/keys.

## Realtime

WebSocket endpoint: `/api/v1/sync/ws`

Clients authenticate with `Authorization: Bearer <token>`. Events are versioned and JSON encoded.

Catch-up endpoint: `GET /api/v1/sync/events?after={event_id}` returns durable sync events visible to the authenticated account. Expired cursors return a typed `full_resync_required` response with retained bounds and the current epoch.
