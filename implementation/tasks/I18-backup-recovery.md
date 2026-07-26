# I18 — Encrypted backup and recovery

Blocked by: D02 and D01.

Goal: create and restore client-encrypted backups without admin recovery or key escrow.

Read:

- backup server/storage/CLI code
- mobile database and MLS state code
- `implementation/archive/2026-07-26/docs/recovery.md`
- `implementation/archive/2026-07-26/docs/threat-model.md`

Do:

1. Encode the user-approved recovery flow with a user-held secret or verified device.
2. Encrypt and authenticate the complete client state before upload.
3. Restore into staging, verify account/device/group binding and rollback counters, then switch atomically.
4. Keep old state on any failure.
5. Test wrong key, truncation, rollback, process death, and clean-device recovery.

Done when: a clean supported device restores usable state without the server/admin learning keys or plaintext.

Verify: mobile tests plus an end-to-end backup/upload/download/restore drill.
