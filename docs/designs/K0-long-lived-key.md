# K0: one long-lived key

**Status: proposed, not yet built.** Revision 2 (2026-10-24), after an
independent review, against `main` at `dbce0f2`. It needs the owner's yes on
the open questions at the end and a second review (AGENTS.md: recovery and
credential decisions) before K1 or K2 starts.

## Summary

- **The recovery key (RK).** The user keeps it. No device stores it, and
  the server never sees it.
- **The recovery key pair.** RK yields a key pair. A device keeps its
  public half (`rk_pub`) only if it got it in one of two ways: the user
  typed RK into it, or a hand-off bound to the device-link safety code
  (SAS) delivered it. Every backup is sealed to `rk_pub`. So no device, not
  even a stolen or revoked one, can open a backup; only the person holding
  RK can.
- **`rk_pub` is an integrity secret.** HPKE base mode has no sender
  authentication, so anyone holding `rk_pub` could make a backup that
  restores. That is why `rk_pub` never goes to the server, and never
  reaches a device by a path the server controls.
- **Fresh keys for live transfers.** A history bundle for a newly linked
  device uses a fresh key per transfer. The key is sealed to a
  transfer key that the device-link SAS checks, and signed with the old
  device's credential key.
- **One container format** for K1 backups and K2 bundles. Only the
  source of the file key differs.
- **Nothing extra for C7 and W10.** C7 channel history keys travel inside
  that container. The W10 search index stays in the encrypted local
  database (D01).
- **A hard rule for K1.** A long-lived backup never holds MLS state, the
  session token or the device secret. A restore creates a new device
  (see [Why not restore the MLS state](#why-not-restore-the-mls-state)).

Revision 2 drops the hidden account-devices MLS group from revision 1.
Its membership was server-controlled: the reconcile adds every device
`mlsPendingChanges` lists, and `stage_membership_commit` checks only the
account and device id, not the signing key. A device the server inserted
would have received every bundle key, or installed its own `rk_pub`.

## What exists today

- **The I45 backup** (`mobile/lib/crypto/backup_service.dart`) uses a
  random 32-byte key per backup and the chunked AES-256-GCM container. The
  recovery code `v1.<origin>.<token>.<key>` carries the key itself.
- **The backup plaintext** (`LocalStore.exportBackup`, format 2) holds:
  - the session (token and device secret) and the sealed MLS provider state;
  - the outboxes;
  - the conversations and the decrypted history.
- **The 15-minute window.** The server releases a backup to anyone with
  the token, but only for 15 minutes after upload
  (`RecoveryCapabilityLifetime`, `server/internal/storage/content_store.go`).
  Today it is a "move to a new phone now" tool, not a disaster backup.
- **Password login** needs an existing device id and device secret (`login`
  in `auth_handlers.go`). A new device joins only by device link or by
  cloning a backup.
- **The device link** binds both devices' signing keys in a transcript.
  The user compares its 8-digit SAS on both devices
  (`derive_device_link_verification`, `crypto/rust/src/mls.rs`;
  `claimDeviceLink` and `refreshActiveDeviceLink`, `app_state.dart`).
- **Late joiners.** Every device is its own MLS leaf, and the server
  withholds messages from epochs before a device joined (`joined_epoch`).
- **Backup deletes.** Any session of the account can delete any of its
  backups (`backupSubroute` DELETE in `content_handlers.go`, `DeleteBackup`).

## Key hierarchy

```
RK entropy (30 random bytes; only the user keeps it)
 └─ PRK = HKDF-Extract(SHA-256, salt = "veritra-k0-v1", ikm = entropy)
     ├─ HKDF-Expand(PRK, "veritra-k0 recovery-hpke", 32)
     │    └─ DeriveKeyPair (DHKEM X25519) → rk_sk (never stored), rk_pub
     ├─ HKDF-Expand(PRK, "veritra-k0 locator", 32) → locator L
     └─ "veritra-k0 locker" reserved, not used (see C7)

rk_id = SHA-256("veritra-k0-rk-id-v1" || rk_pub)[0..16]   (not secret)

per backup or bundle:
  file key FK (32 random bytes) + nonce prefix (8 random bytes)
   ├─ K1 backup: HPKE-Seal(rk_pub, FK || prefix)
   └─ K2 bundle: inside the SAS-bound hand-off (below)
  content: the existing chunked AES-256-GCM container under FK
```

### Why there is no shared account key

I weighed a symmetric account key held by every device and wrapped under
RK. It would let a device read backups without RK. But every device
removal would have to rotate it, and a revoked device that kept it could
read any backup it later got hold of. Sealing to `rk_pub` leaves devices
holding nothing that opens a backup, so a removal needs no rotation. No
current consumer needs a device to read a backup without the user.

## Algorithms (no new dependencies)

| Use | Choice | Library already in the tree |
|---|---|---|
| RK entropy | 30 bytes (240 bits) from the OS RNG | `openmls_rust_crypto` `rand()` |
| Derivation | HKDF-SHA256, labels above | `OpenMlsCrypto::hkdf_extract` / `hkdf_expand` |
| Recovery and transfer key pairs | RFC 9180 DeriveKeyPair / GenerateKeyPair, DHKEM(X25519, HKDF-SHA256) | `OpenMlsCrypto::derive_hpke_keypair` |
| Seal FK | HPKE base mode, X25519 / HKDF-SHA256 / AES-256-GCM | `OpenMlsCrypto::hpke_seal` / `hpke_open` |
| Hand-off signature | Ed25519 with the device's MLS credential key | `SignatureKeyPair` (signing), `OpenMlsCrypto::verify_signature` |
| Content | chunked AES-256-GCM, 1 MiB chunks (unchanged) | `aes-gcm` (`src/attachment.rs`) |
| Display | Crockford base32 of entropy ‖ 2-byte check, 52 characters in 13 groups of 4 | Rust, with test vectors |

- **The display check** is `SHA-256("veritra-k0-rk-check-v1" || entropy)[0..2]`.
  It catches a typo before anything touches the network. It is not a
  security control.
- **No password KDF.** 240 bits needs none. A user-chosen passphrase would
  need Argon2 on the client, which is a new crate (owner question 2).

**ABI v7 (additive), for K1 and K2 to build.**

- **Functions:**
  - recovery-key generate, encode and decode;
  - derive, which returns `rk_pub`, `rk_id` and `L`;
  - seal, and open (open takes the entropy and derives `rk_sk` inside
    Rust);
  - transfer key-pair create, which keeps the private key in the sealed
    provider state until the hand-off is opened or the link expires;
  - hand-off seal-and-sign and verify-and-open.
- **Labels stay in Rust.** Signing always prefixes its domain label inside
  Rust, so Dart cannot have the credential key sign arbitrary bytes.
- **What crosses the FFI.** The X25519 private keys never do. The RK
  entropy does, because the app must show it. It travels in the
  zero-on-free owned buffers.
- **Dart side.** Dart keeps it in a `Uint8List` and wipes it after use.
  Dart `String`s (the displayed and typed text) cannot be wiped, so that
  part is best effort.
- **Before it lands:** fixed test vectors for each function, and an
  entry in the `docs/crypto.md` change log.

## Container (K1 and K2)

This is the history container v1 (magic `VHC1`). Its name is separate from
the backup **plaintext** version, which W7 and W11 already bump (to v3 and
v4).

**Byte encoding.** `lp(x)` is a u16 big-endian length followed by `x`.
Integers are big-endian. The canonical header `H0` is, in this order:

```
"VHC1" | u8 kind (1 = backup, 2 = bundle) | lp(account_id)
| lp(source_device_id) | u64 created_at_ms | u64 counter | lp(rk_id or empty)
| u32 chunk_count | u64 padded_plaintext_size | u8 plaintext_version
```

The full header is `H = H0 | lp(enc or empty) | lp(sealed_fk or empty)`.
The last two fields are empty for a bundle.

- **HPKE.** `info` is `"veritra-k0-seal-v1" | lp(account_id)`, and `aad`
  is `H0`. The AAD leaves out `enc` and the sealed FK, so it is not
  circular.
- **Chunks.** The chunk context is `"veritra-history-v1" | SHA-256(H)`,
  inside the existing chunk AAD (`veritra-attachment-v1`, chunk index,
  context). So a server cannot move a container between accounts or
  devices, or edit any header field, `enc` included.
- **`counter`** is monotonic per source device. It replaces the
  `state_counter` that I45 reads from `crypto_metadata`. The server keeps a
  copy of it only to refuse a lower one.
- **The plaintext** is the backup plaintext at its current version,
  without:
  - the session and the device secret;
  - the sealed MLS state and its state key;
  - the outboxes.

  K1 takes the next plaintext number for that removal. The plaintext
  holds:
  - the conversation list and decrypted history with reactions;
  - attachment manifests;
  - DM verification records;
  - C7 channel history keys;
  - settings and contacts.

  It never holds the D01 database key or the search index.
- **Padding.** The plaintext is padded to a size bucket (K1 picks the
  buckets), so the daily upload size does not track daily activity.

## Where each piece lives

K0 puts **nothing new into the platform key store** (Keystore, Keychain,
DPAPI, Secret Service). No device holds a secret that opens a backup, and
`rk_pub` is integrity-critical but not secret against the device itself,
so the encrypted DB is enough.

| Piece | Where | Never |
|---|---|---|
| RK entropy | With the user (paper, password manager). In memory only while shown, confirmed or used to restore; wiped after (best effort for Dart strings) | Secure storage, the local DB, a container, the server, logs |
| `rk_sk` | Derived inside Rust for one open, then dropped | Anywhere persistent |
| `rk_pub`, `rk_id` | The encrypted local DB (D01), only after the user typed RK or a SAS-bound hand-off delivered it | The server; any path the server controls |
| `SHA-256(L)`, current `rk_id` | The server, on the account | — |
| Backup ciphertext | The server, plus optionally a second copy as a file where the user picks (K1) | — |
| FK | In memory while making or opening one container; inside one hand-off | Stored anywhere |
| Transfer private key | The sealed MLS provider state of the new device, until the hand-off is opened or the link expires | Anywhere after that |
| Channel history keys (C7) | The encrypted local DB; inside containers | The server in clear |
| Search index (W10) | The encrypted local DB | Containers, the server |

## How it moves to a new device

### Linked device, old device present (K2)

The device-link protocol moves to `veritra-device-link-v2`, and the
transcript gains one field: the new device's fresh X25519 transfer
public key, appended after `new_signing_public_key`. The SAS the user
compares therefore covers it. Then:

1. After approval, the old device builds a `bundle` container under a
   fresh FK. It uploads the container as an ordinary blob (ciphertext
   only).
2. The old device makes a hand-off of `{blob_id, sha256, FK,
   nonce_prefix, rk_pub, rk_id}`:
   - HPKE-sealed to the transfer key, with `info` =
     `"veritra-k2-handoff-v1" | transcript_hash`;
   - signed with its credential key over
     `"veritra-k2-handoff-sig-v1" | transcript_hash | enc | ciphertext`.
3. The old device posts the hand-off to the device link. The server keeps
   it next to the link (ciphertext only) and deletes it when the new
   device fetches it, or when the link expires.
4. The new device checks the signature against
   `existing_signing_public_key` from the transcript it has already
   SAS-checked. It opens the hand-off and downloads the blob. It checks
   `sha256`, decrypts and merges, because it may already hold newer
   messages.
5. The new device stores `rk_pub` only if `rk_id` matches. It wipes FK and
   the transfer private key, and the blob is deleted.

A device the server inserts never saw the SAS, so it gets nothing. If
the hand-off never arrives, the new device can ask the user to type RK
(for `rk_pub` only). The history then has to come from a K1 restore.

**Alternative considered:** a two-device MLS group whose add checks the
leaf's signature key against the SAS-checked key. That needs an
add-with-expected-key check in the ABI. The hand-off above needs fewer new
parts.

### All devices lost (K1 restore)

1. The user enters the server, username, password and RK.
2. The app derives `L` and calls a new **recovery enrollment** route.
   Under owner option (a), the server checks the password and
   `SHA-256(L)`, with these rules:
   - **Same error, same timing.** A wrong password and a wrong `L` get the
     same error and the same work, including the dummy hash for an
     unknown username. This is the pattern of `login` in
     `auth_handlers.go`.
   - **Shared back-off.** The route shares `LoginBackoff` under the
     `login-account` username key, plus the credential budget (D39).
   - **Optional challenge instead of a bearer `L`.** The server could
     store an Ed25519 public key derived from RK, and the client signs a
     server challenge. This is an open option for K1.
3. If the route accepts, the server enrolls a **new device** the same way
   registration does. It audits `device.recovered`, and every other device
   shows a notice.
4. **Lost devices.** The route offers "sign out every other device". It
   is on by default, and cannot be turned off when the user says every
   device is lost. The server revokes those devices (the existing
   `DELETE /devices/{id}` path) and queues their removal from every group
   (the I51 revocation flow), so a stolen device stops getting new
   messages.
5. **Forced resets.** Recovery forces a password change and a recovery-key
   replacement before the device is usable, because RK was just typed on
   a new device.
6. **Pick and import.** The app lists the account's backups (device, date,
   size). The user picks one; the app opens it with RK and checks that the
   header's `source_device_id` equals that backup's `backup_blobs.device_id`
   on the server. It then imports the history and marks those rows as
   restored.
7. **Other members re-add it.** Their apps add the new device by
   reconcile, and the account's safety numbers change, as for any new
   device.
8. **Conversations where nobody else can re-add it.** These are
   conversations with no other account's device left in them (a note to
   self, or a group whose other members have all left). Their restored
   history is read-only, and the app starts a new conversation for new
   messages. A group changes only through a commit by a current member
   device; compare the revocation coordinator query in
   `identity_store.go`, which also needs another active device.
9. **The gap.** Messages sent between the backup and the restore are lost
   to this device. The server withholds them by design, and no old device
   is left to bundle them.

**Confirm now and then (K1).** The user types RK. The app derives
`rk_pub` and compares it with the stored one. Nothing leaves the device.

### Why not restore the MLS state

Not because of nonce reuse: MLS XORs a random reuse guard into each
nonce. The real failures are these:

- **Repeated generations.** A copy of a day-old state sends with
  generations the live device has already used. Receivers fail to
  decrypt those messages. Under I33, an application message that cannot
  be decrypted stops sync without advancing the cursor, and there is
  **one cursor for all conversations** (`saveSnapshot` / `_syncCursor` in
  `local_store.dart`). So one twin's message halts every receiver's whole
  sync.
- **Missing leaf keys.** If the device committed an update since the
  backup, the copy lacks the new leaf private keys and cannot process
  later commits.
- **Forks.** Two devices on one leaf can each commit, so the group forks.

Today's clone-restore is safe only if nothing happened since the backup
and the original never runs again. The app cannot enforce either. K1
therefore restores **history only**, into a new device.

## Rotation

- **Device removed.** Nothing to rotate: devices hold only `rk_pub`.
- **Replacing the recovery key** (the user asks; RK was seen or lost
  while a device still works; or after a recovery):
  1. The device generates RK′ and shows it. The user confirms it by typing
     it.
  2. With recent auth, the device registers `SHA-256(L′)` and `rk_id′`. The
     server swaps them in one transaction and **deletes every backup
     sealed to the old `rk_id`**.
  3. The device uploads a new backup at once.
  4. **Other devices.** They notice that the server's `rk_id` changed,
     either from the backup-status call or from an upload refusal. They
     **pause their backups** and ask the user to type the new RK there.
     `rk_pub` never travels between existing devices.
  5. The app tells the user that any second-copy files made before still
     open with the old key, and should be deleted.
- **Algorithm change** (for example an ML-KEM hybrid, once a reviewed
  one is in the tree). It takes a new salt (`veritra-k0-v2`) and a new
  container version. Devices re-seal on the next backup.

## Losing the recovery key

| Situation | Result |
|---|---|
| RK lost, a device still works | Replace the recovery key. Nothing is lost |
| RK lost and every device lost | Nobody can recover the history, the instance owner included. There is no escrow. Whether the account can come back is owner question 1 |
| RK found by someone else | Under option (a): nothing without the password. With a second-copy file: that file. The user replaces RK |
| Password forgotten, RK kept | Under option (a), no way in without a device. See owner question 1 |

## Threat model

| Adversary | Gets | Mitigation, or what is left |
|---|---|---|
| Server operator, or a breach of the server and its R2 backups | Backup ciphertext, padded sizes, upload times, `rk_id`, `SHA-256(L)` | No key material. 240-bit RK, so no offline guessing |
| Malicious server forging history | Would need `rk_pub` to seal a backup that opens | `rk_pub` is never on the server or on a server-controlled path. The restore checks the header's source device against the server record, and restored rows are marked |
| Malicious server inserting a ghost device | Pending changes add it to MLS groups (a residual of trust-on-first-use, not of K0) | It gets no bundle or `rk_pub`: the hand-off is SAS-bound and signed |
| Malicious server rolling back | Can serve an older backup, or withhold one | The AAD binds account, device and header. The restore screen shows date and device. Rollback on a fresh device cannot be detected otherwise; accepted |
| Lost or stolen locked device | Secure storage and the D01 DB | It holds nothing that opens a backup. The user revokes it; nothing rotates |
| Compromised unlocked device | Its own history, `rk_pub`, live messages | It cannot read any backup. With `rk_pub` it could forge a backup for its own account; that is accepted, since it already holds that account's live access |
| Attacker with password and RK | Recovery enrollment, then sign-out of the real devices | Forced password and RK change; notices on every device; owner question 1b (a waiting period that active devices can cancel) |
| Quantum attacker in the future | Could open captured backups only together with `rk_pub` from a device that held it | Residual. Move to an ML-KEM hybrid when a reviewed one exists |
| Shoulder-surfing during setup | RK | Shown once, with a confirm step; replaceable |

## How each package uses K0

- **K1 automatic backups.**
  - **Setup:** make RK, show it once, confirm it, and register
    `SHA-256(L)` and `rk_id`.
  - **Daily backup:** a `backup` container sealed to `rk_pub`, with no
    user input. A device replaces only its own copy. "Confirm now and
    then" is the `rk_pub` comparison. The second copy is the same
    ciphertext saved as a file (`file_selector` is already a dependency).
  - **Server work:**
    - backups that stay recoverable (no 15-minute expiry);
    - registering `rk_id` and the locator, and refusing an upload whose
      `rk_id` is not current or whose counter is lower;
    - the recovery enrollment route with the rules above;
    - deleting old-key backups on a swap;
    - deleting another device's backup only with recent reauth.
  - **Quota:** 10 devices × 64 MiB is more than the 512 MiB per-account
    quota (D38). K1 picks one of two:
    - one current copy per account, uploaded by the device with the most
      history;
    - a copy per device under a total cap.
  - **I45:** retires the clone-restore (see Migration).
- **K2 history on a new device.** A `bundle` container delivered by the
  SAS-bound hand-off. Or a K1 restore onto a device already enrolled by
  link, which needs no recovery enrollment.
- **C7 community history.** A channel history key is shared with other
  accounts, so it cannot derive from anyone's RK. K0 provides only where a
  member keeps those keys:
  - in the encrypted local DB;
  - inside K1 backups and K2 bundles, so a restored or new device of the
    same member can read the history that member was entitled to.

  After a restore, keys that arrived since the last backup come from C7's
  normal hand-over by channel members. The `locker` label is reserved for
  one case: C7 later needing a member's devices to fetch keys from the
  server with no member online. That would need an account key and its
  own review.
- **W10 search over old messages.**
  - **The index:** an FTS5 table in the same SQLite3MC database, so it is
    page-encrypted under the D01 key. It needs no key of its own.
    `sqlite3` 3.5.2's hook builds with `SQLITE_ENABLE_FTS5` by default
    (its `doc/hook.md`), but W10 must check `PRAGMA compile_options` on
    every platform first.
  - **Rebuilds:** the index is never put in a container. It is rebuilt
    after an import.
  - **W2 interaction:** expired or deleted messages must leave the index.
    W10 should use FTS5 `delete` with `secure_delete`, or merge segments,
    so expired text does not survive in free pages.

## Migration from I45

- **Old recovery codes.** `v1.` codes expire 15 minutes after upload, so
  none are left to migrate.
- **The clone-restore** stays only until K2 ships. After that:
  - device link plus a hand-off replaces it;
  - creating format 2 backups is removed;
  - the server's 15-minute token path goes with it.
- **Until then.** The UI should tell the user to stop using the old phone
  once the code is made. That is the only condition under which a clone
  is safe.

## Open questions for the owner

1. **Recovery enrollment.** Restoring onto a new device after all devices
   are lost needs a new way into the account. Pick one:
   - (a) Password plus RK (recommended). Losing either one locks the
     account.
   - (b) RK alone. This covers a forgotten password, but anyone with the
     paper gets the account and its history.
   - (c) No recovery enrollment. A user who loses every device loses the
     account; backups only help with a device link.

   Then decide on a **waiting period**. If any device of the account was
   seen in the last N days (for example 7), recovery waits N days, and
   any active device can cancel it. That stops someone with the password
   and RK from locking out the real user, at the cost of a slow recovery.

   Either way, recovery signs out the other devices by default and forces
   new credentials. This is a credential decision and needs your yes and
   an independent review.
2. **Passphrase instead of a random key?** Easier to remember, but it needs
   Argon2 on the client (a new crate, a licence review and a
   `THIRD_PARTY_NOTICES.md` entry), and users pick weak ones. The
   recommendation is a random key only.
3. **Backups on by default** at onboarding (a skippable prompt to save
   RK), or opt-in in Settings?
4. **Retire the clone-restore** once K2 ships?

## Done when (for K0)

K0 is done when this design is reviewed and the owner has answered the
questions above. K1 then builds ABI v7 with test vectors, and adds a
`docs/crypto.md` change-log entry for the ABI, link protocol v2 and the
container.
