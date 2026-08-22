# T39 — Fail-closed encrypted database-key recovery

| Field | Contract |
|---|---|
| Consensus source | I39; SEC-05; L7 |
| Initial eligibility | Blocked by T32 |
| Risk | High release blocker |
| Executor | Strong |
| Advisor | Required on recovery/reset state machine and final diff |
| Depends on | T32 |
| Blocks | T45A/T45C |
| Parallel safety | Do not overlap T32/T45C encrypted-store lifecycle changes |

## Objective

Preserve an encrypted database when its key is missing/wrong/corrupt, enter
`recoveryRequired`, and allow only approved recovery or explicit destructive reset.

## Read first

- `docs/audit-consensus.md` I39.
- `docs/audits-codex/security-issues.md` SEC-05.
- `docs/audits-opus/logical-issues.md` L7.
- `mobile/lib/storage/encrypted_database.dart`, `local_store.dart`, T32 state,
  secure-storage initialization and encrypted-store tests.

## Invariants

- Never generate a replacement key over existing encrypted data.
- Never delete/reset without explicit informed confirmation.
- Key material is never logged or included in diagnostics.

## Work

1. Reproduce all secure-storage failure classes.
2. Disable reset-on-error and preserve DB/key metadata.
3. Map failures to typed `recoveryRequired` state.
4. Offer approved relink/backup path or explicit destructive reset.
5. Test wrong, missing, corrupt and interrupted recovery cases.

## Acceptance

- Every key failure preserves the original database.
- Recovery is required and reset needs explicit confirmation.
- No silent key replacement or plaintext/key logging occurs.

## Required checks

```sh
cd mobile && flutter test test/encrypted_local_store_test.dart test/app_state_test.dart
```

