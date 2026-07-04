# API

Base path: `/api/v1`

## Operations

- `GET /healthz` and `GET /api/v1/health` return storage health.
- `GET /metrics` exposes local aggregate HTTP counters when `PRIVATE_MESSENGER_ENABLE_METRICS=1`. It does not include user IDs, request bodies, tokens, message content, or ciphertext.

## Setup

- `GET /setup` serves a static notice. Browser owner setup is disabled until a client can generate production device key packages.
- `GET /api/v1/setup/status` returns whether setup is required.
- `POST /api/v1/setup/owner` creates the first owner account and device. It requires `X-Private-Messenger-Setup: 1` and a real `device_key_package`.

## Auth and Invites

- `POST /api/v1/auth/login` returns a bearer token for a known local `device_id`. New devices must use device linking instead of password-only login.
- `POST /api/v1/auth/logout` revokes the caller's current session token. Returns `204`.
- `POST /api/v1/auth/logout-all` revokes every session for the account except the caller's current one (sign out other/lost devices). Returns `204`.
- `POST /api/v1/register` consumes an invite and creates account, device, and session.
- `POST /api/v1/invites` creates invite codes for owner/admin users.

## Devices

- `GET /api/v1/devices/me` lists the account's devices.
- `DELETE /api/v1/devices/{id}` revokes one of the caller's devices, deletes its sessions, and disconnects that device's active sync sockets. Returns `204`, or `404` if the device is not the caller's.

## Device Linking

- `POST /api/v1/device-links` creates a short-lived one-time QR/link code from an authenticated existing device.
- `GET /api/v1/device-links/{id}` returns the authenticated account's current link state for approval UX.
- `POST /api/v1/device-links/claim` lets the new device submit the code, device name, and public key package. It returns a claim token, but not a session.
- `POST /api/v1/device-links/{id}/approve` must be called by an already authenticated device on the same account before the new device is trusted. Body: `{"verification_code":"123456"}`.
- `GET /api/v1/device-links/{id}/claim-status` lets the new device poll for approval using `X-Veritra-Claim-Token`. Once approved, the server creates a device-scoped session and consumes the link.

The verification code returned to both devices must be compared in the client UX before approval. The server stores only public device key-package metadata and never receives private keys.

## Communities

- `POST /api/v1/communities` creates a community owned by the caller.
- `POST /api/v1/communities/{id}/channels` creates a channel in a visible community.

There are no list-communities, list-channels, or list-members endpoints yet. The current mobile UI derives community/channel display from conversations plus items created in the current session.

## Messaging

- `POST /api/v1/conversations` creates DMs, groups, or channel-backed conversations.
- `GET /api/v1/conversations` lists visible conversations.
- `POST /api/v1/conversations/{id}/members` adds members.
- `PUT /api/v1/conversations/{id}/retention` updates disappearing-message retention. New message expiries are capped by this value.
- `POST /api/v1/messages/envelopes` stores ciphertext-only message envelopes.
- `GET /api/v1/conversations/{id}/messages?limit={n}&before={message_id}` lists non-expired encrypted envelopes. `after` is also accepted, but `before` and `after` are mutually exclusive. Responses include `limit` and optional `next_before`.
- `POST /api/v1/conversations/{id}/typing` publishes a best-effort realtime typing event.
- `POST /api/v1/messages/{id}/edit` stores an encrypted edit marker/envelope.
- `POST /api/v1/messages/{id}/delete` stores an encrypted delete marker and tombstones the server-held envelope.
- `POST /api/v1/messages/{id}/reactions` stores encrypted reaction payloads.
- `POST /api/v1/conversations/{id}/read-receipts` stores read receipt metadata.

Payloads must not include plaintext body fields. Message ciphertext is base64-encoded in JSON.

## Attachments, Backups, and Calls

- `POST /api/v1/attachments?conversation_id={id}` accepts encrypted blobs only when `X-Private-Messenger-Encrypted: 1` is present.
- `POST /api/v1/backups` accepts client-encrypted backup blobs with `X-Key-Derivation-Metadata`.
- `POST /api/v1/push/subscriptions` records push endpoints. Push payloads must remain generic.
- `DELETE /api/v1/push/subscriptions/{id}` disables one of the caller's push subscriptions.
- `POST /api/v1/calls` creates self-hosted call signaling sessions for conversation members.

Attachment and backup contents are opaque ciphertext to the server.
Download/list endpoints for stored attachment and backup ciphertext are still TODO.

## Search and Account Data

- `GET /api/v1/search/metadata?q={query}&limit={n}&offset={n}` searches account usernames, visible community names, and visible channel names. Accounts match on the **exact** (case-insensitive) username only; prefix/contains matching is deliberately not offered for accounts so the user directory cannot be enumerated by probing substrings. Communities and channels (which are scoped to the caller's memberships) use exact/prefix matching so the endpoint stays index-friendly. Pagination metadata includes `limit`, `offset`, and optional `next_offset`.
- `GET /api/v1/account/export?limit={n}&before={message_id}` exports account metadata, devices, visible conversations, and encrypted message envelopes. Message export is paginated and returns optional `next_before`.
- `DELETE /api/v1/account` soft-deletes the account, revokes devices, and removes sessions.

Server-side message-content search is intentionally absent.

## Realtime

WebSocket endpoint: `/api/v1/sync/ws`

Clients authenticate with `Authorization: Bearer <token>`. Events are versioned and JSON encoded.

Catch-up endpoint: `GET /api/v1/sync/events?after={event_id}` returns durable sync events visible to the authenticated account.
