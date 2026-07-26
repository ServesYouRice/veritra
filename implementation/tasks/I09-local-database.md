# I09 — Encrypted local database

Blocked by: D01.

Goal: replace the single secure-storage record with the approved transactional database.

Read:

- `mobile/lib/storage/local_store.dart`
- `mobile/lib/core/app_state.dart`, `mobile/lib/sync/sync_service.dart`
- the D01 decision and approved package documentation

Do:

1. Add versioned schema/migrations for accounts, conversations, ciphertext envelopes, cursor, and outbox.
2. Keep the database key in Android Keystore/iOS Keychain, not in the database or logs.
3. Migrate the old record once, verify it, then remove it safely.
4. Make writes transactional and concurrency-safe across foreground/background isolates.
5. Test migration, restart, corruption, concurrent writes, and rollback.

Done when: no growing cache/outbox blob remains in secure storage and all local persistence tests pass on Android/iOS-compatible code paths.

Verify:

```powershell
Push-Location mobile; dart format --set-exit-if-changed .; flutter analyze; flutter test; Pop-Location
```

Update `THIRD_PARTY_NOTICES.md` for the approved dependency.
