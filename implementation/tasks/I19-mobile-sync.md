# I19 — Fix mobile sync, history, and outbox

Goal: mobile state converges incrementally and one failed action does not block unrelated work.

Read:

- `mobile/lib/core/app_state.dart`
- `mobile/lib/sync/sync_service.dart`
- `mobile/lib/storage/local_store.dart`
- chat list/screen and API client

Do:

1. Apply typed events to affected rows, with a bounded full-resync fallback.
2. Add stable backward pagination and preserve scroll position.
3. Persist outbox attempts and classify retryable, terminal, and auth failures.
4. Replace global busy/error with operation-scoped state.
5. Test duplicate/out-of-order events, poison outbox entries, restart, and offline catch-up.

Done when: old history is reachable, later sends pass a terminal failure, and unrelated UI actions remain usable.

Verify:

```powershell
Push-Location mobile; flutter analyze; flutter test; Pop-Location
```
