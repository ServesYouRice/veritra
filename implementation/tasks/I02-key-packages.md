# I02 — Fix key-package claims

Goal: claim key packages through the real membership schema, atomically and once.

Read:

- `server/internal/storage/key_package_store.go`
- `server/migrations/`
- `server/internal/httpapi/key_package_handlers.go`
- related storage/API tests

Do:

1. Add a migrated-database test that reproduces the nonexistent-table query.
2. Use the authoritative conversation/member tables and authorization rules.
3. Keep selection and consumption in one transaction.
4. Test non-member denial, requester-device exclusion, and double-claim behavior.

Done when: a member receives each eligible package once; unauthorized or repeated claims reveal nothing.

Verify:

```powershell
Push-Location server; go test ./internal/storage ./internal/httpapi; Pop-Location
```

Do not add a compatibility table or weaken single-use semantics.
