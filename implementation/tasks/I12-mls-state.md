# I12 — Commit MLS state and cursor together

Goal: processing one event cannot persist MLS state without its sync cursor, or the cursor without state.

Read:

- `crypto/rust/src/mls/state.rs`
- `mobile/lib/storage/local_store.dart`
- `mobile/lib/sync/sync_service.dart`, `mobile/lib/push/background_push.dart`

Do:

1. Define the transaction joining sealed MLS state, rollback counter, affected ciphertext rows, and cursor.
2. Serialize per-group transitions across foreground/background execution.
3. Fail closed on corrupted state, rollback, epoch gaps, or incomplete writes.
4. Add crash/failure injection around each transaction boundary.

Done when: restart tests prove exactly one of old-state/old-cursor or new-state/new-cursor survives every injected failure.

Verify: Rust state tests and focused Flutter storage/sync tests, then full Flutter tests.

Never place MLS secrets in logs, fixtures, or unencrypted storage.
