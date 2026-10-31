# K0 recovery enrollment (password + recovery key)

**Status: proposed (2026-10-31), not built.** Implements K0's "All devices
lost" ([K0](K0-long-lived-key.md)) under D49, D57, D63, D71, D73 and D77.
Credential and recovery change: needs an independent review (AGENTS.md).

## Where things stand

- **No device-less way in.** `login` (`auth_handlers.go`) needs a device id
  and secret; since D71/D73 a restore leaves an account-only session
  (`restoredAccountSession`, `local_store.dart`) that only a device link
  finishes.
- **The K0 recovery key (RK) is not built**: no generate, derive or
  `rk_pub`; only VHC1's `rk_id` field exists (`crypto/rust/src/history.rs`).
- **I45 backups live 15 minutes** (`RecoveryCapabilityLifetime`,
  `content_store.go`; one-time per TASK-168).
- **So, honestly:** this package gives the **account** back on a new
  device to someone who lost every device. It brings **history** back only
  if a restore happened inside that window (a same-day phone move).
  Disaster recovery of history needs durable backups (O1). UI and docs
  must not claim more.

## Proof of the user

- **RK.** K0's 30-byte entropy, 52-character display, PRK =
  HKDF-Extract("veritra-k0-v1", entropy). New label
  `"veritra-k0 recovery-auth"` → 32-byte Ed25519 seed → **`rk_auth_pub`**.
  It replaces K0's `SHA-256(L)` bearer verifier (`L` stays reserved,
  unused). `rk_pub`/`rk_id` are derived now too, so K1 reuses the same key
  and the user saves it once.
- **Why a signature.** The proof signs the reservation challenge, the new
  device's signing key and key-package hash and the origin, so a proof seen
  at the TLS edge cannot be replayed or moved to another device. The server
  never receives a reusable secret. Proof message (built in Rust; Dart gets
  no sign-anything entry point): `"veritra-k0-recovery-proof-v1" |
  lp(challenge) | signing_key | SHA-256(key_package) | lp(origin)`.
- **Dependency.** A seeded Ed25519 key needs `ed25519-dalek` (2.2.0,
  already in `Cargo.lock`, transitive) as a direct dependency: **O2**, like
  D76. Fallback: K0's bearer `L`. The server stores `SHA-256(L)` and uses
  `subtle.ConstantTimeCompare`; the routes are unchanged.
- **Password.** Checked as in `login`: Argon2id (D34), a dummy hash for
  unknown users, and the 3-slot hashing limit.
- **Offline guessing (D63).** A random RK has 240 bits, out of reach. A
  passphrase RK can be guessed offline by whoever holds `rk_auth_pub`, and
  later by whoever holds a K1 backup sealed to `rk_pub` (a second oracle),
  so peppering or encrypting the verifier adds little. The defence is all
  client-side:
  - entropy = Argon2id(passphrase, salt = SHA-256("veritra-k0-pp-v1" |
    origin | account_id)), with ≥128 MiB, tuned to about 1 s on the
    slowest supported phone;
  - a strength floor;
  - refusing the login password, typed in the same setup flow (NFKC,
    case-folded compare);
  - D63's plain warning.

  The server never learns which kind of RK was chosen. The passphrase is
  its own later package (new Argon2 crate, O4).

## Server API

Paths sit under `/api/v1/account-recovery/`, never `/api/v1/recovery` (the
I45 download credential route). `ClassifyRoute`:
- `…/enrollment` stays on the enrollment budget (5/min);
- every other path under the prefix is a credential route (10/min), as for
  device-link v3, including alternate slash spellings.

| Route | Auth | Does |
|---|---|---|
| `PUT /api/v1/account/recovery-key` | `withRecentAuth` | Set or replace `{rk_auth_pub, rk_id}`; sync event and audit `account.recovery_key_set` |
| `GET /api/v1/account/recovery-key` | `withAuth` | `{configured, rk_id, set_at, pending_request?}` |
| `POST …/account-recovery/enrollment` | none | `{username}` → reservation `{id, account_id, device_id, challenge, expires_at}`, kind `recovery` |
| `POST …/account-recovery/claim` | none | reservation id, username, password, device name, key package, signing key, `challenge_signature`, `recovery_signature` → 202 `{request_id, claim_token, device_secret, state, ready_at}`, or 401 `invalid_credentials` |
| `GET …/account-recovery/{id}/status` | `X-Veritra-Claim-Token` | 202 `{state:"waiting", ready_at}`; once ready, 200 `{account, device, token}` (consumed in one transaction, as `ConsumeApprovedDeviceLink`); 410 `recovery_cancelled` |
| `POST …/account-recovery/{id}/cancel` | `withRecentAuth`, same account | Cancel a waiting request; audit `account.recovery_cancelled` |

**No enumeration oracle.**
- `createEnrollmentReservation` mints `account_id` at reservation time, and
  the challenge encodes it. For `recovery`, a known username gets its real
  id. An unknown one gets a decoy, `"acct_" + HMAC(decoy key, normalized
  username)`: the same format, stable across calls.
- The decoy key is 32 random bytes in `instances`.
- An account with no RK gets a normal reservation; its claim fails like any
  other.

**Claim handler.** Same work on every path, no early return:
1. Size checks, and `challenge_signature` with the device key (cheap,
   public data), as `register` does before it spends a hashing slot.
2. The password check (dummy hash if no account).
3. `recovery_signature` against `rk_auth_pub`, or a fixed decoy key when
   there is no account or no RK.
4. `ok = exists & passwordOK & rkOK`.

**Backoff.**
- `LoginBackoff` key `recovery-source\x00ip\x00user` counts every failure.
- `recovery-account\x00user` is checked and counted only when `rkOK`, as
  `deviceOK` is in `login`. Only an RK holder can drain the account budget,
  and no 429 reveals whether the password was right.
- `LoginBackoff` is in memory, so a durable `recovery_attempts` row also
  caps all failed claims for a username (default 50 a day), whatever the
  credentials. It bounds distributed guessing of a passphrase RK when the
  password has leaked. Accepted cost: someone who knows the username can
  delay a recovery by a day.

**Waiting period (D49).**
- **Active devices** are not revoked, hold an unexpired session, and have
  `devices.last_seen_at` within `RECOVERY_ACTIVE_WINDOW` (7 d).
- **Wait.** With any active device, `ready_at = now + RECOVERY_WAIT` (7 d);
  otherwise `now`. Both are `PRIVATE_MESSENGER_RECOVERY_*` settings (O3).
- **Cancel** needs recent auth (password and device secret), so a thief
  with an unlocked phone cannot block the owner.
- **No early approval.** Whoever still has a working device links instead
  (L0/K2).
- **One waiting request per account.** A new valid claim replaces it,
  restarts the timer and notifies again. Unclaimed requests expire 3 d
  after `ready_at`.

**Completion** (the status call after `ready_at`), in one transaction:
1. Lock the request (`waiting`, `ready_at <= now`, account `active`).
   Insert the device from the reservation and its first key package, plus a
   session with `recent_auth_at = now`. Consume the reservation.
2. **Revoke every other device.** First set `revoked_at` on all of them,
   then delete their sessions and retire their v2/v3 links, and only then
   call `queueMLSRevocations` per device.
   - Its coordinator query picks `MIN(device_id)` among non-revoked
     devices. Revoking one device at a time would let a doomed sibling
     coordinate, and that revocation would stall.
   - The new device is in no group yet, so it is never chosen.
3. Sync events `device.revoked` for each, then `account.recovered`. Audit
   `account.recovered {device_id, revoked}`. After commit, publish and
   `Hub.DisconnectDevice` each revoked device.

**Notices.**
- **At claim:** sync event `account.recovery.pending {request_id,
  device_name, ready_at}`, a generic push wake (no text; D53), and audit
  `account.recovery_requested`.
- **Active devices** show a persistent local notice: "Someone is recovering
  your account on <device>, finishing <date>. Not you? Cancel, then change
  your password and recovery key."
- **Peers** see a new device and changed safety numbers, as for any new
  device.

## Client flow (mobile)

1. Start from the restored account-only session (origin and username
   prefilled), or "I lost all my devices" on the connect screen (no
   history). The RK is typed and checked by the Rust decode before any
   network call. Then reserve.
2. **Account check.** If a restored session exists and the reservation's
   `account_id` differs, **stop** ("this backup is for another account").
   Otherwise `_identityChanged` would silently drop the restored history.
   Decoys land here too, with the same generic wording.
3. `createEnrollmentCredential` (fresh MLS identity), the recovery proof
   (new ABI), then claim.
4. **Persist the pending claim**: claim token, device secret, request id,
   `ready_at`, and the claim's MLS state. The wait spans days and restarts,
   and `pendingDeviceLinkClaim` is memory-only today. Reuse K2's encrypted
   pending-enrollment storage (local schema 16) if it has landed; otherwise
   this package builds it and K2 reuses it.
5. **Finish.** Poll at start, on resume and hourly. On 200, do what
   `completeDeviceLinkClaim` does:
   - check origin, account and device;
   - save the session (the restored history is kept) and set cursor 0;
   - publish initial key packages, refresh and sync.
6. **Forced hygiene before chats open.** Replace the RK (generate, show,
   confirm by typing, `PUT`), then change the password, both under the
   fresh recent auth.
   - The server keeps the old RK valid until it is replaced, so a crash at
     this step never locks the user out.
   - `rk_pub`/`rk_id` are stored only after the user typed the RK (K0).
7. **Groups.** Other accounts' devices add the new device by I51 reconcile,
   and their coordinators remove the old leaves. `joined_epoch` still
   withholds earlier messages; D54/D74 placeholders cover gaps.
   Conversations with no other account's live device (notes to self,
   abandoned groups) cannot re-add it: their history is read-only, with an
   offer of a new conversation (K0 step 8).
8. **Setup.** Settings → "Set up a recovery key" (recent auth). K1 moves it
   into onboarding (D49: on by default).

## Abuse cases

| Case | Outcome |
|---|---|
| Stolen backup and code, plus a guessed password | No RK, so no recovery; a backup holds no credentials (D71) |
| Password phished, RK safe | Nothing. Per-source backoff and the account cap |
| Password and RK stolen | Enrolls after the wait if the owner is active; the owner can cancel; notices and audit everywhere. Residual: owner inactive for 7 d means takeover, then the admin (B9) suspends |
| Thief with an unlocked phone | Cannot cancel without the password; completion revokes the phone |
| Operator, or a DB/R2 leak | `rk_auth_pub`, `rk_id`, audit rows. A random RK is safe; a passphrase is exposed per D63. The operator could always insert devices (L1 residual); nothing new |
| Enumeration, replay, MITM | Decoy ids, the same error and work. The proof binds the challenge, device key and origin; reservations are one-time |

## Migration and ABI (next free numbers at landing; D70 and K2 also take some)

- **`account_recovery_keys`** `(account_id PK, auth_public_key, rk_id,
  created_at)`.
- **`account_recovery_requests`** `(id, account_id, reservation_id,
  device_id, device_name, key_package, signing_key, device_auth_hash,
  claim_token_hash UNIQUE, state, created_at, ready_at, expires_at,
  cancelled_by_device_id, completed_at)`, with a partial unique index
  `(account_id) WHERE state='waiting'`.
- **`recovery_attempts`** `(account_id, day, failures)`.
- **`instances.recovery_decoy_key`**; `enrollment_reservations.kind` gains
  `recovery`. Expired rows are pruned with the reservations.
- **ABI** (next after D70's 10 and K2, additive): RK generate, encode and
  decode; derive `{rk_pub, rk_id, rk_auth_pub}`; sign the proof. It ships
  with test vectors, a `docs/crypto.md` change-log entry, and the K0 key
  hierarchy updated.

## Tests

- **Go.**
  - Equal work and the same error for an unknown user, no RK, a wrong
    password and a wrong RK.
  - Stable decoys.
  - The account backoff counts only on `rkOK`; the durable cap survives a
    restart.
  - Wait on and off by activity; cancel needs recent auth; replaced and
    expired requests; suspended account.
  - Completion: two old devices plus a peer, and the coordinator is never
    an old device.
  - Route classes for every new path and spelling.
- **Rust.** Derive and proof vectors.
- **Flutter.**
  - Account-mismatch refusal; the pending claim survives a restart; the
    restored history is kept after completion.
  - Forced RK and password replacement; read-only no-peer conversations;
    notice and cancel on an active device.
- **Demo e2e.** Restore → recovery with no other device → a peer re-adds
  it → messages flow; the old device is revoked.

## Packages, in order

1. **R1 Rust/ABI** (Opus review, after O2): RK codec, derive, proof,
   vectors.
2. **R2 Server** (Opus review): migration, routes, route classes, backoff,
   wait, completion transaction, events and audit; `docs/operations.md`.
3. **R3 Client setup**: set or replace the RK in Settings; status.
4. **R4 Client recovery**: reserve, claim, persisted claim, poll and
   complete, forced hygiene, read-only no-peer conversations, notice and
   cancel, and the banner's restore action (STATE "Banner hides backup
   restore").
5. **R5** Independent review of R1–R4, a demo e2e run, a STATE update.
6. **Later.** P1 passphrase RK (O4); K1 durable backups sealed to `rk_pub`
   bring history back after a disaster.

## Owner decisions

- **O1.** History after losing every device needs a downloadable backup.
  - (a) Keep the 15-minute I45 window until K1 (recommended): account back,
    history only for same-day moves.
  - (b) Lift it now: backups hold no credentials since D71, but the code
    `v1.origin.token.key` then becomes a long-lived key to the history.
- **O2.** `ed25519-dalek` as a direct crypto dependency for the signature
  proof (recommended), or K0's bearer `SHA-256(L)`.
- **O3.** Numbers: activity window 7 d, wait 7 d, failure cap 50 a day.
- **O4.** Whether the passphrase package (D57/D63, Argon2 crate) runs
  before or after K1.
