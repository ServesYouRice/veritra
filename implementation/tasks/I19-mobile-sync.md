# I19 — Fix mobile sync, history, and outbox

Goal: mobile state converges incrementally and one failed action does not block unrelated work.

Read:

- `mobile/lib/core/app_state.dart`
- `mobile/lib/sync/sync_service.dart`
- `mobile/lib/storage/local_store.dart`
- chat list/screen and API client

Do:

1. Apply typed events to affected rows, with a bounded full-resync fallback.
   **Remaining — needs I09's local database.**
2. ~~Add stable backward pagination and preserve scroll position.~~ Done
   2026-07-29: `listMessagePage` keeps `next_before`, `loadOlderMessages`
   appends to the reversed list so visible messages do not move.
3. Persist outbox attempts and classify retryable, terminal, and auth
   failures. **Remaining — needs I09's local database.**
4. ~~Replace global busy/error with operation-scoped state.~~ Done 2026-07-29
   for send, members, blocks, and mute via `Ops`/`_runScoped`; the remaining
   auth and setup flows still use the global pair deliberately.
5. Test duplicate/out-of-order events, poison outbox entries, restart, and
   offline catch-up. **Partly done** — pagination, dedupe, and scoped-failure
   tests landed; poison-entry and restart cases follow items 1 and 3.

Done when: old history is reachable, later sends pass a terminal failure, and unrelated UI actions remain usable.

Verify:

```powershell
Push-Location mobile; flutter analyze; flutter test; Pop-Location
```
