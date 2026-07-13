# Privacy-preserving push contract

Status: provider implementation pending.

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

## Work required to enable

- Review and pin the official Android connector dependency and license.
- Implement connector selection, registration, rotation, message acknowledgement, and background execution.
- Implement RFC 8291/VAPID delivery behind the server `push.Provider` interface.
- Add operator configuration for VAPID/APNs/FCM secrets and readiness without logging them.
- Complete platform entitlement and battery-behavior review before enabling by default.
