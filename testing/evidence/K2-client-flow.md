# K2 client flow — 2026-10-31

Status: two client slices built and tested; the end-to-end transfer is
**not** wired and K2 is not usable yet. No commit pushed, no release step.
Production messaging stays off (`main.dart` unchanged).

## What was built

**Read-only view of copied conversations** (`features/chat/copied_history_screen.dart`,
`AppState.historyOnlyConversations` / `historyOnlyMessages` /
`refreshCopiedHistory`). Conversations that exist only in the copied-history
namespace (`local_history_conversations`) appear behind a "Copied history"
action in the chat list, shown only when there is at least one. They open
read-only from the encrypted local store:

- no composer, no message actions, no reactions, no attachment download
  (attachments read "Attachment, not downloaded on this device"), no profile
  lookup or mention tap; other senders read "Another member" because the
  snapshot carries no sender labels; own rows read "You";
- hidden, deleted, sender-hidden and expired rows are left out (expiry is
  applied at read time);
- a descriptor is never history-only while the live list is unknown, while
  the server lists that conversation, or while its community is joined, and
  `historyOnlyMessages` refuses a live conversation, so this path never
  becomes a second way into live chats or a membership source;
- descriptors are loaded with the session (`_tryRestoreSession`, which the
  I45 restore also uses) and cleared on sign-out. An importer must call
  `refreshCopiedHistory()` after its transaction commits. The descriptors
  are assigned only after the session-generation check, so a sign-out during
  the read cannot bring another account's titles back; community channels
  wait until the community list is known.

Choice the design left open, safest option taken: history-only chats are
listed in a separate screen, not mixed into the live chat list, so a copied
chat cannot be mistaken for one that can receive messages.

**Transfer transport** (`core/history_transfer_client.dart`, new file;
`api_client.dart` untouched). Implements the reviewed wire in
`docs/designs/K2-transfer-resource.md` against the field spellings in
`server/internal/storage/device_history_transfer_store.go`:

- upload: the source first GETs the transfer. A receipt for exactly this
  metadata is returned without resending (the Go handler answers a retry
  after reading only the metadata part and may close mid-body, which a
  client would see as a socket error); a different receipt is refused; only
  404 leads to the POST. The POST streams `multipart/form-data`, exactly
  `metadata` (`application/json`) then `ciphertext`
  (`application/octet-stream`), exact `Content-Length`; a source stream of
  the wrong length aborts; the reply must match the sent metadata. A refusal
  of a first large upload may still surface as a transport error;
- status: strict receipt decoding; `handoff` decoded only when present;
- download: into a ciphertext file, resuming with `Range` + `If-Range` pinned
  to `"sha256-<digest>"`; a 200 restarts from zero; a wrong ETag, wrong
  `Content-Range`, wrong length or extra bytes deletes the partial file; a
  cut connection keeps its prefix. The caller must pass the native
  whole-ciphertext digest check (`verifyDigest`); it runs on every complete
  file and a failure deletes the file, so a bad prefix behind a matching
  ETag is never resumed (no SHA-256 in Dart, no new dependency);
- acknowledge: only `{protocol_version, transfer_id, ciphertext_sha256}`,
  and the reply must say `acknowledged`; its doc says to call it only after
  the import transaction and import ledger commit;
- cancel: idempotent DELETE, never unlinks a device;
- auth: ordinary session or the canonical 32-byte `X-Veritra-Claim-Token`;
  **redirects are never followed**, so no token is forwarded; the
  constructor refuses any origin the `TransportPolicy` refuses (HTTPS only
  unless the demo entry point passes its loopback policy).

Already covered before this round and rechecked: the history snapshot export
excludes the D52 notice outbox (`notice_outbox_test.dart`, "backups and K2
exclude device notice state").

## What remains, and why it was not built here

The old device sending one bundle to a newly linked device needs, in order:

1. **Encrypted pending-enrollment storage** (K2-native-state-migration
   slice 4). The receiver must durably hold the v3 link id, claim token,
   request hash, the native pending handoff and download progress across a
   crash between claim, completion, download, import and ACK. No such record
   exists; adding it is a local schema change (16) in generated Drift files,
   which the design gives to one coordinator. Without it a crash would lose
   the claim token or replay a promotion, so the AppState switch to v3 was
   not attempted.
2. **NativeCryptoService K2 orchestration** under its serial queue: source
   `k2SourceBegin`/write snapshot/`sourceFinish` with a durable ciphertext
   cache and persisted manifest+handoff before HTTP; receiver
   `k2ReceiveBeginBundle` (persist handoff first), stream the downloaded
   file, `receiveFinish`, decode, `importHistorySnapshot`, then ACK. This
   lives in `native_crypto_service.dart` and the ABI wrappers, which another
   agent is moving to ABI 9 this round; no new native call is needed by the
   transport, but the orchestration should be written against the final ABI.
3. **v3 link UI** (SAS confirm on the old device, claim/QR on the new one)
   replacing the v2 link screens, then removing the v2 clone path.
4. Device runs on two real devices, then independent review.

**Restore from backup into history** is blocked on K1 (history-only backup
format). I45 clone backups are deliberately never routed into the history
importer (design §"Do not feed I45 v1 clone backups").

**Retiring the old clone-restore path** (owner decision: after K2 works).
Removal needs: K2 steps 1–4 passing on devices; K1 history-only backups so
lost-device restore has a replacement; then delete
`AppState.restoreFromBackup`, `BackupService.recover`/`restoreBackup` clone
import (`local_store.restoreBackup`, `encrypted_database.restoreBackupState`
session/crypto/outbox replacement), the restore UI in
`features/settings/backup_screen.dart` and `SyncRecoveryChoice.restoreBackup`,
plus the server recovery download once no supported client uses it. Until
then the clone path stays as it is.

## Checks (Linux, pinned Flutter 3.44.0)

- `k2_copied_history_test.dart`: 8 passed (memory and SQLite: live/joined/
  unknown-list exclusion, expiry, rejoin; session ended during the restore
  read keeps nothing (fails without the fix); community channels wait for
  the community list; widget: list entry, read-only screen, no `TextField`,
  senders unnamed; no entry without copied chats).
- `k2_history_transfer_client_test.dart`: 10 passed against a loopback
  server (multipart order/fields/bytes, status-first lookup returns an
  existing receipt without a POST and refuses a different one, mismatched
  POST receipt, non-404 status stops before the POST,
  wrong-length source, redirects not followed for status/download/upload,
  claim header, malformed receipts, resume/restart/ETag/range/oversize,
  ACK body and state, cancel, client-side limits).
- `w8_ui_test`, `l10n_hardcoded_strings_test`, `l10n_locales_test`,
  `l10n_serbian_screens_test`: pass (63 with the copied-history tests).
  Serbian Latin regenerated from Cyrillic with `scripts/l10n-sr-latn.py`.
- `flutter analyze` on touched files: no issues. Full `scripts/test` and
  `scripts/lint` not run (shared host; brief limits to related tests).
- Not run: the transport against the real Go handler. The field names were
  read from the server code; an integration test against
  `device_history_transfer_handlers.go` should be added with the
  orchestration.

## 2026-11-01: pending-enrollment storage (local schema 17)

Built step 1 above, storage only (no flow uses the K2 kind yet).

- Tables `local_pending_enrollment` (one row: kind `k0_recovery` or
  `k2_link_v3`, canonical origin, account, device, kind-specific payload
  JSON holding the credentials, optional sealed MLS state: counter, key,
  root) and `local_pending_enrollment_records` (the state's record changes
  in seal order). Raw SQL in `storage/pending_enrollment_sql.dart`; no Drift
  regeneration.
- Rules (`LocalStore.savePendingEnrollment`): another kind, origin,
  account or device while one is pending is refused
  (`PendingEnrollmentConflict`); a stored MLS state is frozen (a different
  one is refused; a write without a state keeps it). Kept across sign-out
  with a kept device, an identity change and a backup restore, dropped by
  `clear()` — the same lifetime the K0 setting had. The in-memory store
  follows the same rules.
- K0: the waiting claim moved from the encrypted setting
  `k0.pending_recovery` into the table (the K0 design says to use K2's
  storage). The 16→17 upgrade moves it in the upgrade transaction using the
  K0 loader's own decoder; values the loader ignored (abandoned `''`,
  unreadable) are deleted and never echoed.
- Not in 17: K2 transfer progress (download offset, ciphertext path,
  handoff) and the promotion ledger. They belong with the orchestration,
  which writes them.

Checks: `k2_pending_enrollment_test.dart` 29 passed: fresh create; 16→17
with no claim; with a waiting claim and with a `needsLogin` claim (every
field, key, root and record compared); four unreadable values dropped while
the open succeeds; a crash after each upgrade statement leaves schema 16
with the setting byte for byte, then the next open moves it; 15→17; SQL
clear paths; memory and SQLite store rules; a sentinel claim absent from
`exportBackup` and `exportHistorySnapshot` bytes. Disabling the move fails
12 of them. K0 recovery tests now read the table.

The NativeCryptoService orchestration was not started: its receiver half
begins at the v3 claim, which the v3 link screens drive, and it needs the
transfer-progress tables above.
