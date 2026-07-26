# I03 — Make mutations and events atomic

Goal: never commit durable state without its matching sync event.

Read:

- `server/internal/storage/message_store.go`
- `server/internal/httpapi/conversation_handlers.go`
- `server/internal/httpapi/call_sync_handlers.go`
- `server/internal/httpapi/auth_handlers.go`

Do:

1. Inventory edit/delete, reactions, receipts, retention, calls, and device events.
2. Add focused failure-injection tests for the shared transaction pattern.
3. Move each state mutation and event insert into one storage transaction.
4. Publish realtime only after commit; never publish event ID `0`.

Done when: forced event-write failure rolls back state and emits no realtime event.

Verify:

```powershell
Push-Location server; go test ./internal/storage ./internal/httpapi; Pop-Location
```

Preserve idempotency and ciphertext-only payloads.
