# Sync Protocol

Version: `v1`

The sync service fans out small-instance events over WebSocket and stores durable sync rows for reconnect/resync.

## Event Types

- `message.envelope.created`
- `message.marker.updated`
- `reaction.created`
- `read_receipt.updated`
- `typing.updated`
- `membership.updated`
- `invite.updated`
- `device.updated`
- `call.signaling`

## Reconnect

Clients maintain the last durable event ID they processed and call `GET /api/v1/sync/events?after=<id>` for catch-up. The endpoint returns conversation-scoped events only when the authenticated account is a member of that conversation, plus direct account-scoped events.

## Offline Sends

Clients generate idempotency keys. The server returns the existing envelope for duplicate `(sender_device_id, idempotency_key)` submissions.
