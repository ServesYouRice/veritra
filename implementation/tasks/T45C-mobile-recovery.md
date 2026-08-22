# T45C — Reviewed mobile backup/recovery workflow

| Field | Contract |
|---|---|
| Consensus source | I45 client scope; NTH-04; U18/H1 |
| Initial eligibility | Blocked under D02 |
| Risk | High release blocker |
| Executor | Strong |
| Advisor | Required on key ownership, recovery capability and destructive reset UX |
| Depends on | T29, T39, T45A |
| Blocks | G24 restore matrix |
| Parallel safety | One owner for backup service, recovery state and settings UI |

## Objective

Replace dead recovery UI with a reviewed encrypted backup creation/restore flow
that clearly distinguishes recovery, relink and destructive reset.

## Read first

- `docs/audit-consensus.md` I45 plus I29/I39 boundaries.
- NTH-04, Opus U18/H1.
- `mobile/lib/crypto/backup_service.dart`, storage/recovery state, settings UI,
  API client and server backup endpoints.

## Invariants

- User-held decryption material never reaches server/logs.
- Capability handling follows T29; key failure follows T39.
- Destructive reset is explicit, confirmed and never presented as recovery.

## Work

1. Specify backup creation, capability storage/transfer and restore state machine.
2. Implement status, age, create/rotate and restore UI.
3. Integrate interruption/resume and typed errors.
4. Add wrong key, corrupt backup, missing blob and process-restart tests.

## Acceptance

- Mobile backup and clean-device restore pass without server plaintext/key access.
- Interrupted/corrupt/wrong-key cases preserve original state and explain recovery.
- G24 can execute the complete two-device restore flow.

## Required checks

```sh
cd mobile && flutter test test/app_state_test.dart test/encrypted_local_store_test.dart test/ui_actionable_test.dart
```

