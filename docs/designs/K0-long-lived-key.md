# K0: one long-lived key

**Status: proposed, not yet built.** Needs the owner's yes on the open
questions at the end and an independent second opinion (AGENTS.md:
recovery and credential decisions) before K1 or K2 starts. Written
2026-10-24 against `main` at `dbce0f2`.

## Summary

- The user keeps one **recovery key** (RK). No device stores it. The server
  never sees it.
- RK yields a **recovery key pair**. Devices keep only its public half,
  and seal every backup to it. So no device, and no stolen or revoked
  device, can open any backup. Only the person holding RK can.
- Live transfers (a history bundle to a newly linked device) use a fresh
  key per transfer, sent inside MLS. They never use a long-lived key.
- K1 backups and K2 bundles use **one container format**. Only the source
  of the file key differs.
- C7 channel history keys and W10 search add **no key scheme of their
  own**. Channel keys travel inside that container. The search index stays
  in the encrypted local database (D01).

This also sets one hard rule for K1: **a long-lived backup never holds MLS
state, the session token or the device secret.** A restore creates a new
device (see [Why not restore the MLS state](#why-not-restore-the-mls-state)).

## What exists today

- The I45 backup (`mobile/lib/crypto/backup_service.dart`) uses a random
  32-byte key per backup and the chunked AES-256-GCM container. The
  recovery code `v1.<origin>.<token>.<key>` carries the key itself.
- The backup plaintext (`LocalStore.exportBackup`, format 2) holds the
  session (token and device secret), the sealed MLS provider state, the
  outboxes, the conversations and the decrypted history.
- The server releases a backup to anyone with the token, but only for 15
  minutes after upload (`RecoveryCapabilityLifetime`,
  `server/internal/storage/content_store.go`). Today it is a
  "move to a new phone now" tool, not a disaster backup.
- Password login needs an existing device id and device secret
  (`auth_handlers.go` `login`). A new device joins only by device link
  (`device_link_screen.dart`, SAS-checked transcript) or by cloning a
  backup.
- Every device is its own MLS leaf. The server withholds messages from
  epochs before a device joined (`joined_epoch`, `mls_group_store.go`).

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
   └─ K2 bundle: sent inside an MLS message of the account-devices group
  content: the existing chunked AES-256-GCM container under FK
```

### Why two layers and no shared account key

I weighed a symmetric account key held by every device and wrapped under
RK. It lets a device read backups without RK. The cost is that every
device removal must rotate it, and a revoked device that kept it can read
any backup it later gets hold of. Sealing to `rk_pub` means devices hold
nothing that opens a backup, so a device removal needs no rotation at all.
No current consumer needs a device to read a backup without the user. An
account key becomes worth it only if a later package needs one (see C7).

## Algorithms (no new dependencies)

| Use | Choice | Library already in the tree |
|---|---|---|
| RK entropy | 30 bytes (240 bits) from the OS RNG | `openmls_rust_crypto` `rand()` |
| Derivation | HKDF-SHA256, labels above | `OpenMlsCrypto::hkdf_extract` / `hkdf_expand` |
| Recovery key pair | RFC 9180 DeriveKeyPair, DHKEM(X25519, HKDF-SHA256) | `OpenMlsCrypto::derive_hpke_keypair` |
| Seal FK | HPKE base mode, X25519 / HKDF-SHA256 / AES-256-GCM | `OpenMlsCrypto::hpke_seal` / `hpke_open` |
| Content | chunked AES-256-GCM, 1 MiB chunks (unchanged) | `aes-gcm` (`src/attachment.rs`) |
| Display | Crockford base32 of entropy ‖ 2-byte check, 52 chars in 13 groups of 4 | Rust, with test vectors |

- The display check is `SHA-256("veritra-k0-rk-check-v1" || entropy)[0..2]`.
  It catches a typo before anything touches the network. It is not a
  security control.
- The HPKE `info` is `"veritra-k0-seal-v1"`, followed by a length-prefixed
  account id. The AAD is the container header (below). So a server
  cannot move a backup between accounts or edit its header.
- 240 bits needs no password KDF. A user-chosen passphrase would need
  Argon2 on the client, which is a new crate (see the owner questions).

**ABI v7 (additive), for K1 to build.** Recovery-key generate, encode and
decode; derive (returns `rk_pub`, `rk_id`, `L`); seal; and open (takes
the entropy and derives `rk_sk` inside Rust). The X25519 private key never
crosses the FFI. The entropy does, because the app must show it. It
travels in the zero-on-free owned buffers, and Dart wipes its copies.
Fixed test vectors cover each function. When it lands, it gets an entry in
the `docs/crypto.md` change log.

## Container (K1 and K2)

History container **v3**:

- **Header, in clear and used as AAD:** magic `VBK3`, kind
  (`backup` / `bundle`), account id, source device id, created_at, a
  monotonic counter, `rk_id` (backup only), the HPKE `enc` (backup only),
  the sealed FK (backup only), the chunk count and the padded size.
- **Body:** the existing chunk format under FK. The chunk context is
  `"veritra-history-v3"` followed by SHA-256 of the header.
- **Plaintext holds:**
  - the conversation list and decrypted history with reactions;
  - attachment manifests (keys included);
  - DM verification records;
  - C7 channel history keys;
  - settings and contacts.
- **Plaintext never holds:**
  - the session token or the device secret;
  - the sealed MLS state or its state key;
  - outboxes;
  - the D01 database key;
  - the search index.
- **Padding:** the plaintext is padded to a size bucket (K1 picks the
  buckets), so the daily upload size does not track daily activity.

## Where each piece lives

K0 puts **nothing new in secure storage.** No device holds a secret that
opens a backup, so there is nothing for Keystore, Keychain, DPAPI or
Secret Service to guard beyond today's D01 database key and the sealed
MLS state key.

| Piece | Where | Never |
|---|---|---|
| RK entropy | With the user (paper, password manager). In memory only while shown, confirmed or used to restore; wiped after | Secure storage, the local DB, a backup, the server, logs |
| `rk_sk` | Derived inside Rust for one open, then dropped | Anywhere persistent |
| `rk_pub`, `rk_id` | The encrypted local DB (D01) on each device; sent to own devices over the account-devices group | The server (keeping `rk_pub` off the server keeps a future quantum attacker from opening captured backups with server data alone) |
| `SHA-256(L)`, `rk_id` | The server, on the account | — |
| Backup ciphertext | The server, one current copy per device; optionally a second copy as a file where the user picks (K1) | — |
| FK | In memory while making or opening one container | Stored anywhere |
| Channel history keys (C7) | The encrypted local DB; inside containers | The server in clear |
| Search index (W10) | The encrypted local DB | Containers, the server |

## The account-devices group

This is a hidden MLS group per account whose members are that account's
active devices: a conversation kind `account_devices`, never shown as a
chat. Own devices have no other private channel to each other. It carries
two payload types:

- `k0.recovery_public {rk_id, rk_pub, set_at}`;
- `k2.history_bundle {bundle_id, blob_id, sha256, fk, nonce_prefix, size}`.

Rules:

- **Creation.** The first device that needs the group creates it at epoch
  0 through the normal commit bundle. If two devices race, the server
  accepts one epoch-0 creation (D28). The other clears its staged commit
  and joins by Welcome.
- **Joining.** New devices are added by the normal reconcile
  (`_reconcileMlsMembership`).
- **No history.** A device never sees messages from before its join epoch
  (`joined_epoch`). So the device that commits an add **sends
  `k0.recovery_public` again in the new epoch, after the server accepts
  the commit**. Nothing may rely on old messages in this group.
- **Accepting a new `rk_pub`.** A device accepts it only from its own
  account's device in this group, and only when `rk_id` matches the id the
  server has on record. Every device then shows "Your recovery key was
  changed on <device>". A rogue own device can still push a key it made,
  but it needs a recent password reauth to register that key's id.

## How it moves to a new device

**Linked device, old device present (K2).**

1. After SAS approval, the old device adds the new one to every group,
   including account-devices.
2. It sends `k0.recovery_public`.
3. It builds a v3 `bundle` under a fresh FK, uploads it as an ordinary
   blob (ciphertext only), and sends `k2.history_bundle`.
4. The new device downloads the bundle, checks its hash, decrypts it and
   merges it, since it may already hold newer messages.
5. It wipes FK, and the blob is deleted.

The bundle needs no RK. If no account-devices message arrives, the new
device can ask the user to type RK. That gives it `rk_pub`, but it must
check that `rk_id` matches the server's record.

**All devices lost (K1 restore).**

1. The user enters the server, username, password and RK.
2. The app derives `L` and calls a new **recovery enrollment** route.
   Under owner option (a) below, the server checks the password
   (Argon2id, D34) and `SHA-256(L)`. It charges the credential budget
   (D39) and enrolls a **new device** the same way registration does.
3. It audits `device.recovered`, and every remaining device shows a
   notice.
4. **Lost devices.** The route offers "sign out every other device". It
   is on by default and cannot be turned off when the user says every
   device is lost. The server revokes those devices (the existing
   `DELETE /devices/{id}` path) and queues their removal from every group
   (the I51 revocation flow), so a stolen device stops getting new
   messages. A notice alone is not enough.
5. **The account-devices group.** If no other device of the account is
   still active, no member is left to add the new device. The server then
   lets the recovered device recreate that group at a fresh epoch 0, and
   drops the old group's state. If another device is still active, that
   device adds the new one as usual.
6. The app lists this account's backups (device, date, size), opens the
   one the user picks with RK, and imports it.
7. Other members' apps add the new device by reconcile. The account's
   safety numbers change, as for any new device.
8. Messages sent between the backup and the restore are lost to this
   device. The server withholds them by design, and no old device is
   left to bundle them.

**Confirm now and then (K1).** The user types RK. The app derives
`rk_pub` and compares it with the stored one. Nothing leaves the device.

### Why not restore the MLS state

A day-old MLS state is wrong in three ways:

- The live device has since moved its sender ratchet. The copy would reuse
  generations, which other members reject (and which risks key reuse).
- If the device committed an update since the backup, the copy lacks the
  new leaf private keys, so it cannot process later commits.
- If the original device is still alive, two devices share one leaf.

Today's clone-restore is safe only when nothing has happened since the
backup and the original never runs again. The app cannot enforce either.
K1 therefore restores **history only**, into a new device.

## Rotation

- **Device removed:** nothing to rotate. Devices hold only `rk_pub`.
- **Replace the recovery key** (the user asks, or RK was seen or lost
  while a device still works):
  1. The device generates RK′ and shows it. The user confirms it by
     typing it.
  2. With recent auth, the device registers `SHA-256(L′)` and `rk_id′`.
     The server swaps them in one transaction and **deletes every backup
     sealed to the old `rk_id`**.
  3. The device sends `k0.recovery_public` for RK′, and every device
     uploads a new backup at once.
  4. The app tells the user that any second-copy files made before still
     open with the old key, and should be deleted.
- **Algorithm change** (for example, an ML-KEM hybrid once a reviewed one
  is in the tree): a new salt (`veritra-k0-v2`) and container version.
  Devices re-seal on the next backup, and the old key stays readable until
  then.

## Losing the recovery key

| Situation | Result |
|---|---|
| RK lost, a device still works | Replace the recovery key (above). Nothing is lost |
| RK lost and every device lost | History cannot be recovered by anyone, the instance owner included. There is no escrow. Whether the account itself can come back is an owner question (below) |
| RK found by someone else | Without the password they get nothing from the server. With a second-copy file they can read that file. The user replaces RK |
| Password forgotten, RK kept | Today the account cannot be entered without a device. See the owner questions |

## Threat model

| Adversary | Gets | Mitigation, or what is left |
|---|---|---|
| Server operator, or a breach of the server and its R2 backups | Backup ciphertext, sizes (padded), upload times, `rk_id`, `SHA-256(L)` | No key material. 240-bit RK, so no offline guessing. `rk_pub` is off the server, so even a broken X25519 does not open the backups with server data alone |
| Malicious server | Can serve an older backup, or withhold one | AAD binds account, device and header, so it cannot forge or move one. The restore screen shows the backup's date and device. Rollback on a fresh device cannot be detected otherwise; accepted |
| Lost or stolen locked device | Secure storage and the D01 database | It holds no key that opens any backup. The user revokes it; nothing needs rotating |
| Compromised unlocked device | Its own history, `rk_pub`, live messages | It cannot read other devices' backups. It could push a forged `rk_pub` only with the password (reauth), and every device shows a notice |
| Someone with the RK paper | Under option (a): nothing without the password. Under option (b): the account and its history | Under (a), restore and download need password and `L`. In either case, replace RK |
| Future quantum attacker with stored ciphertext plus `rk_pub` from a captured device | Could break the X25519 seal | Residual. Move to an ML-KEM hybrid when one is reviewed (STATE.md, post-quantum readiness) |
| Shoulder-surfing during setup | RK | Shown once, with a confirm step; replaceable |

## How each package uses K0

- **K1 automatic backups.**
  - Setup makes RK, shows it once, confirms it, and registers
    `SHA-256(L)` and `rk_id`.
  - The daily backup is a v3 `backup` sealed to `rk_pub`. It needs no
    user input and replaces that device's previous copy (one current copy
    per device).
  - "Confirm now and then" is the `rk_pub` comparison.
  - The second copy is the same ciphertext saved as a file
    (`file_selector` is already a dependency).
  - Server work:
    - backups that stay recoverable (no 15-minute expiry);
    - registering `rk_id` and the locator hash;
    - the recovery enrollment route;
    - deleting old-key backups on a swap.
  - Retires the I45 clone-restore (below).
- **K2 history on a new device.** A v3 `bundle` under a fresh FK, sent
  over the account-devices group as described above. Or a K1 restore,
  with the device already enrolled by link, so no recovery enrollment is
  needed.
- **C7 community history.** A channel history key is shared with other
  accounts, so it cannot derive from anyone's RK. K0 provides only where a
  member keeps those keys:
  - in the encrypted local DB;
  - inside K1 backups and K2 bundles, so a restored or new device of the
    same member can read the channel history that member was entitled to;
  - after a restore, keys received since the last backup come from C7's
    normal hand-over by channel members.

  The `locker` label is reserved for one case only: if C7 later needs a
  member's devices to fetch keys from the server without any member
  online, a server-held key locker sealed under an account key. That
  would be the trigger to add one, with its own review.
- **W10 search over old messages.**
  - **The index:** an FTS5 table in the same SQLite3MC database, so it is
    page-encrypted under the D01 key. It needs no key of its own.
    `sqlite3` 3.5.2's hook builds with `SQLITE_ENABLE_FTS5` by default
    (its `doc/hook.md`), but W10 must check `PRAGMA compile_options` on
    every platform before relying on it.
  - **Rebuilds:** the index is never put in a container. It is rebuilt
    after a K1 or K2 import.
  - **W2 interaction:** expired or deleted messages must leave the index
    too. W10 should use FTS5 `delete` with `secure_delete` (or merge
    segments), so expired text does not survive in free pages.

## Migration from I45

- **Old recovery codes.** `v1.` codes expire 15 minutes after upload, so
  none are left in the wild to migrate. K1 keeps reading format-2
  plaintext only for as long as K2 is unbuilt.
- **The clone-restore** ("move to a new phone now") stays only until K2
  ships. After that:
  - device link plus a bundle replaces it;
  - format-2 creation is removed;
  - the server's 15-minute token path goes with it.
- **Until then.** The UI should tell the user to stop using the old phone
  once the code is made. That is the only condition under which a clone
  is safe.

## Open questions for the owner

1. **Recovery enrollment factors.** Restoring onto a new device after all
   devices are lost needs a new way into the account.
   - (a) Password plus RK (recommended). Losing either one locks the
     account.
   - (b) RK alone. This covers a forgotten password, but anyone with the
     paper gets the account and its history.
   - (c) No recovery enrollment. A user who loses every device loses the
     account; backups only help with a device link. This keeps today's
     trust surface.

   Whichever you pick, recovery enrollment signs out every other device
   by default when the user says all of them are lost (see the restore
   flow). This is a credential decision and needs your yes and an
   independent review.
2. **Passphrase instead of a random key?** It is easier to remember, but
   needs Argon2 on the client, a new crate (licence review,
   `THIRD_PARTY_NOTICES.md`), and still invites weak choices. The
   recommendation is a random key only.
3. **Backups on by default** at onboarding (prompt to save RK, skippable),
   or opt-in in Settings?
4. **Retiring the clone-restore** once K2 ships: yes or no.

## Done when (for K0)

K0 is done when this design is reviewed: an Opus review and the owner's
answers to the questions above. K1 then builds ABI v7 with test vectors,
and adds a `docs/crypto.md` change-log entry for the ABI and the container
v3.
