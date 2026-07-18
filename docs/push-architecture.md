# Privacy-preserving push contract

Status: server Web Push provider and Android UnifiedPush connector implemented.

Push is optional and is only a wake-up hint. Delivery never carries message content, sender identity, conversation identity, attachment metadata, ciphertext, or durable sync data.

## Payload

The decrypted application payload is the fixed versioned object:

```json
{"version":"v1","event":"new_encrypted_event_available"}
```

Receiving it only schedules authenticated `/api/v1/sync/events` catch-up. Notification UI uses generic local copy such as “New activity available.”

## Provider boundary

- Android first supports the official UnifiedPush connector and user-selected distributor.
- The application server sends RFC 8291 encrypted Web Push messages to capability endpoints. It never sends an unencrypted webhook body.
- VAPID keys are instance-scoped operator secrets, never committed or logged.
- APNs and FCM are separate optional adapters. They receive only the same generic encrypted/wake payload and are disabled unless explicitly configured.
- Provider failures do not fail message delivery. Invalid/expired endpoints are disabled after typed terminal responses.

## Endpoint safety

- Subscription creation accepts an allowlisted provider, HTTPS endpoint up to 1000 bytes, and the required public authentication material.
- Capability URLs and push keys are treated as secrets: never logged, exported in plaintext diagnostics, or returned to other devices.
- Direct endpoint delivery uses a dedicated HTTP client with strict connect/response deadlines, response-size limits, no ambient proxy credentials, and controlled redirects.
- Operators should isolate push egress. Arbitrary generic webhook delivery is forbidden because it creates SSRF and plaintext-notification risks.

## Mobile lifecycle

- Each account/device has a distinct registration token and endpoint.
- Startup re-registers the account with the selected distributor as required by the UnifiedPush lifecycle.
- Endpoint rotation replaces the server subscription atomically; logout/device revocation unregisters and disables it.
- Background receipt acknowledges the distributor message when required, performs bounded sync catch-up, and exposes no decrypted content to platform notification services.
- When the UI engine is absent, Android starts a short-lived headless Flutter engine, reads the authenticated session from platform-encrypted storage, applies at most 1,000 sync events, commits the ciphertext snapshot and cursor atomically, then destroys the engine.

## Implemented server boundary

- RFC 8291 encryption and VAPID delivery through the `push.Provider` interface.
- All-or-none operator VAPID configuration and fail-closed startup validation.
- HTTPS endpoint/key validation, public-network-only DNS-pinned dialing, no redirects or ambient proxy, strict deadlines, bounded response reads, and terminal endpoint disablement.
- Fixed generic wake payload and best-effort delivery after durable message commit.

## Remaining provider work

- Complete platform entitlement and battery-behavior review before enabling Android delivery by default.
- Add optional APNs and FCM adapters only after their credential handling and privacy boundaries are reviewed.
