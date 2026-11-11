# K1: automatic backups

**Status: proposed (2026-11-07), not built.** Builds on
[K0](K0-long-lived-key.md) and [K0 recovery enrollment](K0-recovery-enrollment.md),
under D02/D27, D49, D55, D71, D73, D77, D78 and D79. It is a recovery and
credential change, so it needs an independent review before code, and the
owner's answers to the questions at the end.

## Goal (STATE.md K1)

After saving one recovery key (RK) once, the app backs up every day without
a tap and replaces the old copy. It asks now and then to confirm the key,
and it can keep a second copy where the user picks.

## Where things stand

- **I45 backups** (`mobile/lib/crypto/backup_service.dart`, VBK2) use a
  random key carried in a recovery code `v1.<origin>.<token>.<key>`. The
  server releases one to that token for 15 minutes only
  (`RecoveryCapabilityLifetime`, `server/internal/storage/content_store.go`).
  D78 O1 keeps that window until K1.
- **The plaintext** (`LocalStore.exportBackup`, format 6) no longer holds a
  token, a device secret or MLS state (D71, D73).
- **K0 pieces already built:**
  - RK generate, encode, decode and derive `{rk_pub, rk_id, rk_auth_pub}`
    (ABI 11, `crypto/rust/src/recovery.rs`);
  - `PUT/GET /api/v1/account/recovery-key` (`account_recovery_keys`,
    migration 0045);
  - the VHC1 bundle (kind 2) in `crypto/rust/src/history.rs`;
  - the K2 history-only importer (`mobile/lib/storage/history_snapshot.dart`).
- **Missing pieces:**
  - VHC1 kind 1 (sealed to `rk_pub`) does not exist;
  - `saveRecoveryKey` wipes `rk_pub` instead of storing it
    (`app_state_recovery.dart`).
- **Server today:**
  - every upload adds a row and nothing replaces the old one;
  - a lower `state_counter` is refused;
  - any session of the account may delete any backup (`backupSubroute`);
  - a device revoke only sets `revoked_at`, so its backups stay
    (`backup_blobs.device_id` is `ON DELETE SET NULL`, and devices are
    never deleted).

## Design

### What a backup is

- **The container.** A VHC1 container, kind 1, exactly as K0 specifies:
  - HPKE base mode seals `FK || nonce_prefix` to `rk_pub`, with
    `info = "veritra-k0-seal-v1" | lp(account_id)` and `aad = H0`;
  - the content is the chunked AES-256-GCM container under FK;
  - the header binds `account_id`, `source_device_id`, `created_at_ms`,
    `counter` and `rk_id`.
- **The plaintext** is the K2 history snapshot (the same one a bundle
  carries), not export format 6, so K1 and K2 share one importer. Its
  contents:
  - conversations, decrypted history and reactions;
  - attachment manifests;
  - DM verification records;
  - C7 channel history keys;
  - contacts;
  - user-visible settings.
- **What it leaves out:**
  - **Disappearing messages.** No message with an expiry, whether it has
    expired yet or not (research round 2 follow-up). A restore must never
    bring back what the sender asked to vanish.
  - **Credentials and transient state.** The session, the device secret, MLS
    state, outboxes and the pending enrollment (as today).
  - **Everything `k1.*`** (below).
  - **The search index**, which is rebuilt after an import (K0).
  - The D01 key.
- **Padding.** The plaintext is padded inside the container to the
  attachment size buckets (`attachment_crypto.dart`, Signal buckets) with a
  1 MiB floor, so the daily size tracks activity only coarsely. The cap
  stays 64 MiB (`MAX_PADDED_HISTORY`). Above that, the app warns and keeps
  the last good copy. It never sends a cut-down backup silently.

### What a device stores (encrypted local DB, D01)

Settings keys, so no local schema change is needed:

| Key | Holds |
|---|---|
| `k1.rk_pub`, `k1.rk_id` | Stored only after the user typed RK on this device (setup, confirm, restore), or a SAS-bound K2 hand-off delivered them (K0) |
| `k1.counter` | Last counter this device used; strictly increasing |
| `k1.last_success_at`, `k1.last_attempt_at`, `k1.last_error` | Schedule and status (error kind only) |
| `k1.confirm_due_at`, `k1.confirm_misses` | Key-confirmation schedule |
| `k1.second_copy` | The second-copy target (platform handle) and its last write |

All `k1.*` keys are skipped by `exportBackup` and by the history snapshot.
A test like `backup_no_credentials_test.dart` scans both outputs for them.
`rk_pub` lets anyone forge a backup that restores, so it must never ride
inside one.

### Setup (D49: on by default)

1. Onboarding offers "Save your recovery key", which can be skipped. A
   skip shows a Settings badge and asks again after 3 days.
2. The app generates RK and shows it once. The user types it back (the
   K0-R screen).
3. With recent auth, the app sends `PUT /account/recovery-key` (built).
   Then it stores `k1.rk_pub` and `k1.rk_id`.
4. The first backup runs at once.

**Other devices of the account** have no `rk_pub`. They see the server's
`rk_id` through `GET /account/recovery-key` or the `account.recovery_key.set`
event, show "Type your recovery key to turn on backups here", and back up
nothing until the user does. `rk_pub` never moves between existing devices.

### The daily run

**When it runs.** One rule on every platform: run when the last success is
more than 24 h old and the device is idle or the app was just opened. The
guaranteed path is in-process:

- **Phones.** Opening or resuming the app starts the run when it is due.
- **Desktop.** The app keeps running in the tray (W4), so a timer checks
  every hour.
- **Background runs on phones are best effort, and only after D52's cold
  start is safe.** Two conditions:
  - root must query bootstrap before storage opens;
  - the D01 key must be readable while the phone is locked.
- **Android.** A periodic JobScheduler job (the API D52 already uses, no
  new plugin), with charging and unmetered network required.
- **iOS** promises nothing. `BGProcessingTask` runs when iOS decides, often
  overnight on charge, sometimes never for an app the user rarely opens. The
  UI must not claim "daily" there. It shows the last backup date and warns
  after 7 days.
- **Review.** This is a platform-policy point, so it needs review.

**What one run does.** It runs under the existing `_serial` and sync lease,
so it never races a sync pass:

1. **Check the key.** `GET /account/recovery-key`. If the `rk_id` differs
   from `k1.rk_id`, pause and ask for the new RK (K0 rotation step 4).
   Nothing is uploaded.
2. **Build.** Export the snapshot, pad it, seal it with
   `counter = k1.counter + 1`, and write it to a temporary file. A
   ciphertext file only, as today.
3. **Commit the counter.** Persist `k1.counter` before the upload. On a
   crash the next run uses a higher counter, so gaps are fine and a reuse
   cannot happen.
4. **Upload.** `POST /api/v1/backups` with `{kind:1, rk_id, counter}` in
   the metadata, and no recovery token.
5. **Second copy.** If one is set, write the same ciphertext there (below).
6. **Finish.** Wipe FK and the plaintext buffers, and delete the temporary
   file.

**Failures.** A failed run backs off (1 h, 4 h, then the next day) and
shows the error kind in Settings. The app warns once a week has passed with
no success. A backup never blocks sending or sync.

### Server changes

1. **Durable backups.** A kind-1 upload carries no recovery token and never
   expires. The 15-minute token route and VBK2 creation retire (owner
   question 1).
2. **Upload checks**, in one transaction:
   - the `rk_id` must equal the account's current one, or 409
     `recovery_key_changed`;
   - the counter must be above this device's last one, or 409
     `backup_counter_stale` (today a bare 400);
   - a device without a session device id cannot upload kind 1.
3. **Replacing the old copy.**
   - **On success,** in the same transaction: insert the new row, and mark
     this device's previous current copy `superseded_at = now`.
   - **The next upload** deletes rows superseded more than 24 h ago, and
     their blobs go through `reconcileBlobDeletions`.
   - **So a device holds at most two copies:** the current one, and for one
     day the one before.
   - **Why the day's overlap.** The authenticated download
     (`GET /backups/{id}`, ranges up to 64 MiB) gets a 24 h grace, so a
     restore that is under way is not broken by a replacement. A lease
     would cost more state for the same result.
4. **Quota.**
   - **The check:** `usage - superseded copies of this device + new size`.
   - **The cap:** one current copy per device with at most 10 devices
     (D38), so 640 MiB at worst, which is above the 512 MiB account quota.
     Owner question 3 picks between a separate backup allowance and the
     shared quota.
   - **A refusal** answers the existing storage-quota error, and the app
     says "backup space full".
5. **Revoked devices' copies stay.** That copy is what a user who lost a
   phone restores from (K0-R revokes every old device). Retention for
   them:
   - each revoked device keeps its newest copy for 90 days after
     `revoked_at` (owner question 4), then the prune deletes it;
   - the account keeps at most 3 revoked-device copies, newest first.
6. **RK swap** (the existing `PUT /account/recovery-key`, in its
   transaction):
   - delete every backup row whose `rk_id` is not the new one, **except
     revoked devices' copies inside their retention window** (change 5).
     A user who just recovered still holds the old RK and needs exactly
     those copies (see Restore, "Order after a recovery");
   - queue their blobs;
   - emit `account.recovery_key.set` (already sent), which the other devices
     read as "pause backups, ask for the new RK".
7. **Deleting backups.**
   - A device's own copy: `withAuth`.
   - Another device's copy: `withRecentAuth`.
   - Recovery-key setup and status stay as built.
8. **Listing.** `GET /api/v1/backups` adds `kind`, `rk_id`, `counter` and
   `superseded`. The restore screen shows device name, date and size.
9. **Columns.** These become real columns, not JSON:
   - `kind` (0 legacy, 1 K1), `rk_id`, `counter`, `superseded_at`;
   - an index on `(account_id, device_id, superseded_at)`.

   The I45 recovery columns stay readable until the token route is
   removed.

### Restore

Restore now needs an enrolled device first. Under K1 the download is
authenticated, so the order flips from today's "restore, then finish by
link".

- **With another device.** Link (L0, K2), then restore if the K2 transfer
  was skipped.
- **With no device left.** K0-R recovery enrollment (password + RK, with the
  wait), then restore.

Then:

1. The app lists the account's backups. The user picks one (by default the
   newest current copy of the device with the most recent backup) and types
   RK.
2. Rust derives `rk_sk` from the entropy and opens the header seal.
   Restores refuse:
   - a container whose `account_id` is not the session's;
   - a `source_device_id` that differs from the row's `device_id`;
   - an `rk_id` that differs from the typed key's.
3. The download is checked chunk by chunk (as today), then merged by the K2
   history-only importer. Restored rows are marked restored. Existing newer
   messages are kept (merge, not replace).
4. The typed RK also sets `k1.rk_pub` and `k1.rk_id` here.

**Order after a recovery.** Built K0-R forces a new RK before chats open
(K0-R step 6), and an RK swap deletes old-key copies. If nothing changed,
the forced swap would delete the lost phone's copy before the user could
restore it. Two guards, both built:

- **Client order (changes built K0-R).** After a K0-R completion the forced
  follow-up becomes `reauth`, then **restore** (or an explicit skip that
  warns "older backups will become unusable"), then the new RK, then the new
  password. The follow-up step is persisted, so after a crash it resumes at
  the restore step. After that, the first backup is sealed to the new key.
- **Server keep rule.** The RK swap never deletes a revoked device's copy
  inside its retention window (server change 6). Those copies still open
  with the old RK, which the user typed moments ago and still holds. So a
  client that gets the order wrong still leaves them restorable for 90
  days.

**Effect on K0-R.**

- K0-R's "start from the restored session" entry and the banner restore
  action go away. A user who lost every device starts at "Lost all your
  devices?" (K0-R R4), and K0-R's honesty note about history becomes
  "history comes back from the newest backup".
- **The account check moves.** Today a backup made before the reservation
  must name the same account. After K1 the session's account is checked
  against the container's `account_id`.

### Confirming the key now and then

- **The check is local.** The user types RK, the app derives `rk_pub` and
  compares it with `k1.rk_pub`. Nothing leaves the device (K0).
- **Schedule:** 3 days after setup, 14 days after that, then every 90 days.
  "Not now" postpones by 7 days.
- **After three misses or postpones,** a Settings badge stays until the key
  is confirmed.
- **On a mismatch,** the app offers "I lost my key: make a new one" (K0
  rotation, with recent auth). It never says which characters were wrong.
- **Wiping.** The prompt is a full screen with paste allowed. The typed
  text is wiped from Dart buffers on a best-effort basis (K0).

### Second copy where the user picks

The second copy is the same ciphertext file, saved outside the server. It
opens with RK alone; it needs no password and no account.

| Platform | How |
|---|---|
| Windows, Linux, macOS | User picks a folder (`file_selector`, already a dependency). Each run replaces `veritra-backup-<account>-<device>.vhc` by writing a temporary file and renaming it |
| Android | User picks a folder with `ACTION_OPEN_DOCUMENT_TREE`; the app keeps the persistable permission and replaces the file each run. Native channel, no plugin |
| iOS | No silent writes to user folders. "Save a copy" exports through the share sheet or document picker by hand; Settings shows its date |

- **Failure.** A second-copy failure never fails the backup. It shows its
  own warning.
- **RK swap.** The app warns that copies saved before still open with the
  old key, and should be deleted (K0).
- **Restoring from a file** uses the same flow, after enrollment, with a
  file instead of a download. The account and RK checks are the same, but
  the device check cannot be done against the server when that row is gone,
  so the screen names the source device from the header.

## Build notes (K1-2, K1-3)

Where the build differs from the text above, and why:

- **Server (K1-2, migration 0064).** A device holds at most two copies: an
  upload deletes the device's earlier superseded copy even inside its
  24-hour grace, so a loop of uploads cannot pile up copies the allowance
  does not count. Each device's highest counter is kept in
  `k1_backup_counters`, so a counter is never accepted twice, even after its
  copies were deleted. Owner decision 2026-11-11 (question 3b, migration 0078): backup
  space is shared per account. Copies count in the account's storage
  quota with attachments (`ACCOUNT_STORAGE_MIB`); the separate allowance
  and `BACKUP_ALLOWANCE_MIB` are gone. A replacement counts the copy it
  replaces for up to a day, as the design says.
- **One setting per identity.** The device state is one JSON setting,
  `k1.state|<server>|<account>|<device>`, instead of separate `k1.*` keys, so
  it is written at once and another account on the same device never
  overwrites it.
- **Snapshot version stays 1.** Only the contents change (no disappearing
  messages, and with them their reactions, pins and stars), so the K2
  importer needs no change. A reaction or edit that expires, on a message
  that does not, is still kept (as in K2).
- **A stale counter** (local state lost) jumps to
  `max(counter + 1, now in ms)` and retries once.
- **No sync lease.** The snapshot export is one database transaction, and
  runs happen in the foreground only. K1-6's background runs must revisit
  this.
- **Phones** say "when you open the app, at most once a day", never
  "daily" (D91).
- **Restore (K1-4, built).** Settings > Automatic backups > "Restore from a
  backup" lists the K1 copies of the account's other devices (own copies are
  left off: the importer refuses a source equal to the receiver). The typed
  key's `rk_id` is compared with the row's before any download; the first
  416 bytes are peeked (account, device, counter, `rk_id`) before the body;
  the body's size and SHA-256 are checked against the row; Rust opens it
  pinned to the row's device; the K2 importer merges it (`transferId` is the
  backup id, `digest` the SHA-256, so a repeat is a no-op). The importer
  context takes counter and time from the decoded snapshot (inside the
  authenticated container), not from the seal header: the snapshot keeps its
  own namespace counter. A typed key that is also the account's current key
  turns backups on here. Phones back up when the app opens or resumes (owner
  decision, so design question 7 is answered: no phone background jobs in
  this build).
- **Still to do:** the K0-R follow-up reorder (restore before the new key), the confirmation schedule and the second
  copy (K1-5), background runs and retiring VBK2 and the recovery-token
  route (K1-6, after K1-4, so a restore path always exists).

## Threats

| Adversary | Gets | Mitigation, or what is left |
|---|---|---|
| Server operator, DB or R2 leak | Ciphertext, padded sizes, upload times, `rk_id`, counters, device ids | Sealed to `rk_pub`, never on the server; a 240-bit RK leaves no offline guessing. A passphrase RK (after K1, D78) reopens offline guessing, warned per D63 |
| Malicious server forging a backup | Would need `rk_pub` | `rk_pub` comes only from typing RK or a SAS-bound hand-off; `k1.*` never leaves the device or rides in a backup |
| Malicious server rolling back or withholding | Can serve an older copy, or none | The header binds account, device, counter and time. The restore screen shows date and device. A fresh device cannot detect a rollback; accepted (K0) |
| Server deleting copies | Loss of the backup | The second copy; the app warns when the list misses its own copy |
| Stolen locked device | D01 DB with `rk_pub` | Cannot open a backup. It could forge one only after an unlock; the owner revokes it |
| Someone with the second-copy file and RK | The whole history | No password needed, by design. Advice to store the file and the key apart. An RK swap does not invalidate old files (K0) |
| Restore in progress while the owner device replaces the copy | Broken download | 24 h superseded grace |
| Background run on a locked phone | Key store not readable | Run deferred to the next unlock; never a weaker key store |
| Disappearing messages | Would outlive their timer | Left out of every backup |
| Lost phone's copy | Needed for recovery | Kept 90 days after revoke, also across the RK swap that K0-R forces; restore comes before that swap |

## Packages and counters

Each counter is the next free one **at landing**. Today's free numbers are
ABI 13, server migration 0047 and local schema 19. Other packages may take
them first.

| Step | Work | Counter | Route |
|---|---|---|---|
| K1-1 Rust/ABI | VHC1 kind 1 seal and open (open takes the entropy and derives `rk_sk` inside Rust), padding, vectors `testing/vectors/k1-backup-v1.json` checked by Rust and Dart, `docs/crypto.md` change log | **crypto ABI +1** | Opus review |
| K1-2 Server | Columns and index, kind-1 upload checks, superseded grace and prune, quota, revoked-device retention, RK-swap deletes, recent auth for other devices' deletes, list fields, `docs/operations.md` | **server migration +1** | Opus review |
| K1-3 Client backup | Store `k1.*`, snapshot without disappearing messages or `k1.*`, the daily run on app open and on the desktop timer, status and warnings in Settings, onboarding prompt (D49) | none (settings keys); the snapshot format version moves up by one, a format number, not a reserved counter | Sonnet, Opus review |
| K1-4 Restore | Backup list, RK entry, open and import through the K2 importer, K0-R entry changes, the reordered K0-R follow-up (restore before the new RK, resumable) | none | Opus review |
| K1-5 Confirm and second copy | Confirmation schedule; desktop folder; Android tree URI; iOS manual export | none | Sonnet |
| K1-6 Background and retirement | Android job and iOS `BGProcessingTask` after D52's cold start; remove VBK2 creation and the token route (if owner question 1 is yes) | possibly a server migration +1 to drop the token columns | Opus review (platform policy) |
| K1-7 Review | Independent review of K1-1 to K1-6, demo e2e (back up, lose every device, recover, restore, chat), STATE | none | Opus |

## Tests (beyond each step's unit tests)

- **The container.**
  - A kind-1 container opens only with the right RK.
  - A header edit, a device swap or an account swap fails.
  - A wrong `rk_id` is refused before any download.
- **Upload rules.** The server refuses a stale `rk_id`, a lower counter and
  another device's delete without recent auth.
- **Replacement.** The superseded copy is still downloadable for 24 h and
  gone after the next upload past that.
- **Quota and RK swap.** The quota counts a replacement once. An RK swap
  deletes old-key copies in the same transaction.
- **Revoked devices.** A revoked device's copy survives K0-R completion and
  is pruned after 90 days.
- **Recovery, then the forced key change.** Recover with no device left,
  then force the new RK. The lost phone's old-key copy is still listed and
  opens with the old RK, or the restore already finished before the swap.
  A crash between the restore and the new RK resumes at the right step.
- **What a backup holds.** No `k1.*` key, credential or disappearing
  message is in any export.
- **Restore.** It merges and keeps newer messages.

## Open questions for the owner

1. **Retire VBK2 and the 15-minute recovery-token route when K1 lands?**
   Recommended yes. D55 is the precedent: no real users, so no
   compatibility path. Under K1, restore always follows enrollment.
2. **Backups need `PRIVATE_MESSENGER_PUBLIC_ORIGIN` today.** RK setup is
   offered only while `GET /account/recovery-key` says `available`, which
   needs the origin.
   - (a) Keep K1 off until the origin is set (recommended: one setting,
     and recovery and backups go together).
   - (b) Let RK setup for backups work without it, and turn on recovery
     enrollment later.
3. **Quota.**
   - (a) A separate backup allowance per account, for example 2 × 64 MiB,
     plus revoked-device copies (recommended: backups never crowd out
     attachments).
   - (b) Backups share the 512 MiB attachment quota (simpler, no new
     setting).
4. **Revoked-device copies.** Keep the newest copy for 90 days after a
   revoke, at most 3 per account? (Recommended.)
5. **Second copy on phones.**
   - (a) Android automatic to a picked folder, iOS manual export
     (recommended).
   - (b) Manual on both phones.
   - (c) No second copy on phones.
6. **Confirm schedule.** Day 3, day 14, then every 90 days? Or Signal's
   pattern of growing intervals?
7. **Phone background runs** wait for D52's cold start. Until then a phone
   backs up when the app is opened. Is that acceptable for the first
   build?
