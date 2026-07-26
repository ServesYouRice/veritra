# I05 — Add old-message repair

Goal: a client can repair any authorized message referenced by sync, not only the newest page.

Read:

- message/sync routes and handlers under `server/internal/httpapi/`
- `server/internal/storage/message_store.go`
- Flutter API and sync clients

Do:

1. Define one authorized single-envelope lookup or an equivalent complete event payload.
2. Test membership scope, deleted markers, missing IDs, and old messages outside the first page.
3. Update the Dart contract and sync consumer.
4. Keep message contents opaque ciphertext.

Done when: an old edit/delete event converges without refetching only the newest window.

Verify:

```powershell
Push-Location server; go test ./internal/httpapi ./internal/storage; Pop-Location
Push-Location mobile; flutter test; Pop-Location
```
