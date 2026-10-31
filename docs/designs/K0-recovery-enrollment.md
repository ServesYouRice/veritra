# K0 recovery enrollment (password + recovery key)

**Status: proposed (2026-10-31), not built.** Implements K0's "All devices
lost" ([K0](K0-long-lived-key.md)) under D49, D57, D63, D71, D73 and D77.
Credential and recovery change: needs an independent review (AGENTS.md).

## Where things stand

- **No device-less way in.** `login` (`auth_handlers.go`) needs a device id
  and secret. A D71/D73 restore leaves an account-only session
  (`restoredAccountSession`) that only a device link finishes.
- **What exists.** The K0 recovery key (RK) is not built; only VHC1's
  `rk_id` field exists. I45 backups live 15 minutes
  (`RecoveryCapabilityLifetime`, `content_store.go`; one-time per TASK-168).
- **So, honestly:** this gives the **account** back on a new device to
  someone who lost every device. It brings **history** back only if a
  restore happened inside that window (a same-day phone move). Disaster
  recovery of history needs durable backups (O1). UI and docs must not
  claim more.

## Proof of the user

- **RK.** K0's 30-byte entropy and 52-character display, with PRK =
  HKDF-Extract("veritra-k0-v1", entropy). A new label,
  `"veritra-k0 recovery-auth"`, gives a 32-byte Ed25519 seed and from it
  **`rk_auth_pub`**. That replaces K0's `SHA-256(L)` bearer verifier; `L`
  stays reserved and unused. `rk_pub` and `rk_id` are derived now too, so K1
  reuses the same key and the user saves it once.
- **Why a signature.** The proof is built in Rust; Dart gets no entry point
  that signs arbitrary bytes. It is `"veritra-k0-recovery-proof-v1" |
  lp(challenge) | signing_key | SHA-256(key_package) | lp(origin)`.
  - It binds the reservation, the new device and the origin. A proof seen at
    the TLS edge cannot be replayed or moved to another device.
  - The server never receives a reusable secret.
- **Dependency (O2).** A seeded Ed25519 key needs `ed25519-dalek` (2.2.0,
  already in `Cargo.lock`, transitive) as a direct dependency, like D76.
  - Fallback: K0's bearer `L`. The server stores `SHA-256(L)` and compares
    with `subtle.ConstantTimeCompare`; the routes stay the same.
- **Password.** Checked as in `login`: Argon2id (D34), a dummy hash for an
  unknown user, and the 3 hashing slots.
- **Offline guessing (D63).**
  - A random RK has 240 bits, out of reach.
  - A passphrase RK can be guessed offline by whoever holds `rk_auth_pub`.
    Later, a K1 backup sealed to `rk_pub` is a second oracle, so peppering or
    encrypting the verifier adds little.
  - The defence is on the client:
    - Argon2id(passphrase, salt = SHA-256("veritra-k0-pp-v1" | origin |
      account_id)), at least 128 MiB, about 1 s on the slowest supported
      phone;
    - a strength floor;
    - refusing the login password, which is typed in the same flow (NFKC,
      case-folded);
    - D63's plain warning.
  - The server never learns which kind of RK was chosen. The passphrase
    path is a later package (new Argon2 crate, O4).

## Server API

Paths sit under `/api/v1/account-recovery/`, not `/api/v1/recovery`, which
is the I45 download credential route. In `ClassifyRoute`:
- `…/enrollment` keeps the enrollment budget (5/min);
- every other path under the prefix is a credential route (10/min), as with
  device-link v3, alternate slash spellings included.

| Route | Auth | Does |
|---|---|---|
| `PUT /api/v1/account/recovery-key` | `withRecentAuth` | Set or replace `{rk_auth_pub, rk_id}`; sync event, audit `account.recovery_key_set` |
| `GET /api/v1/account/recovery-key` | `withAuth` | `{configured, rk_id, set_at, pending_request?}` |
| `POST …/account-recovery/enrollment` | none | `{username}` → reservation `{id, account_id, device_id, challenge, expires_at}`, kind `recovery` |
| `POST …/account-recovery/claim` | none | reservation id, username, password, device name, key package, signing key, `challenge_signature`, `recovery_signature` → 202 `{request_id, claim_token, device_secret, state, ready_at}`, or 401 `invalid_credentials` |
| `GET …/account-recovery/{id}/status` | `X-Veritra-Claim-Token` | 202 `{state:"waiting", ready_at}`; when ready, 200 `{account, device, token}` once (consumed in one transaction); 410 `recovery_cancelled` |
| `POST …/account-recovery/{id}/cancel` | `withRecentAuth`, same account | Cancel a waiting request; audit `account.recovery_cancelled` |

**No enumeration oracle.**
- The reservation must carry `account_id`, because the challenge encodes it
  (`createEnrollmentReservation`). A known username gets its real id.
- Any other username gets a decoy, `"acct_" + hex(HMAC-SHA256(decoy key,
  NormalizeUsername(username))[:16])`: the same format (it passes
  `domain.ValidID`), and stable. The decoy key is 32 random bytes in
  `instances`; that row exists only after setup, so the migration backfills
  it for an existing instance and setup creates it.
- An account with no RK gets a normal reservation; its claim fails like any
  other.

**Claim handler.** It does the same work on every path, with no early
return:
1. Size checks, and `challenge_signature` with the device key. This is
   cheap, public data, and comes before any hashing slot, as in `register`.
2. Check the password (the dummy hash if there is no account).
3. Check `recovery_signature` against `rk_auth_pub`, or a fixed decoy key.
4. `ok = exists & passwordOK & rkOK`.

On success, in one transaction:
- consume the reservation (it expires in 10 minutes, so it must not wait
  for completion);
- insert the request with the device fields and, as **verified**, the
  current `password_hash` and `rk_auth_pub`.

**Backoff.**
- `recovery-source\x00ip\x00user` in `LoginBackoff` counts every failure.
- `recovery-account\x00user` is checked and counted only when `rkOK`, as
  `deviceOK` is in `login`. Only an RK holder can drain it, and no 429
  reveals whether the password was right.
- `LoginBackoff` is lost on restart, so a durable `recovery_attempts` row
  also caps all failed claims per username (default 50/day). That bounds
  distributed guessing of a passphrase RK after a password leak. Its cost,
  as written: someone who knows the username can block recovery for as long
  as they keep sending 50 failed claims a day (under review).

**Waiting period (D49).**
- **Active devices:** not revoked, an unexpired session, and
  `devices.last_seen_at` within `RECOVERY_ACTIVE_WINDOW` (7 d).
- **Wait:** if any device is active, `ready_at = now + RECOVERY_WAIT`
  (7 d); otherwise `now`. Both are `PRIVATE_MESSENGER_RECOVERY_*` settings
  (O3).
- **Cancel** needs recent auth (password and device secret), so a thief
  holding an unlocked phone cannot block the owner. There is no early
  approval: whoever still has a working device links instead (L0/K2).
- **One waiting request per account.** A new valid claim replaces it,
  restarts the timer and notifies again. Unclaimed requests expire 3 d after
  `ready_at`.
- **Same-day move.** The old phone that made the backup is still active, so
  the full wait applies. Signing it out after the backup avoids that, because
  `logout` deletes its session. The move screen says so.

**Completion** (the status call after `ready_at`), in one transaction:
1. **Lock the request.** It must be `waiting`, with `ready_at <= now`, the
   account `active`, and the account's `password_hash` and `rk_auth_pub`
   still equal to the verified copies. This is `CreateLoginSession`'s
   pattern. An owner who changes either during the wait has defeated the
   claim, even without pressing Cancel. Otherwise answer 410.
2. **Revoke every other device before inserting the new one.**
   - For each old device, run what `revokeDevice` (`identity_store.go`) runs,
     as a helper in this transaction: set `revoked_at`, delete its sessions,
     `retireDeviceLinksV3ForDevice`, `queueMLSRevocations` and
     `releaseMLSRevocationConfirmations` (without it, a pending revocation
     an old device had to confirm waits for good).
   - Only the new device must come last. In a legacy group (no roster)
     every non-revoked device of a member is eligible to coordinate
     (`mlsRevocationEligibleDevice`) and `mls_revocation_required_devices`
     is snapshotted at queue time, so a new device inserted first, which has
     no leaf, could be named coordinator or a required confirmer and the
     revocation would stall. Revoking old devices one at a time is safe:
     `mlsRevocationCoordinator` re-elects once a recorded coordinator is
     revoked, and the release clears a revoked sibling's confirmations.
3. **Insert the new device** from the request, with its first key package
   and a session.
   - `recent_auth_at = now` only when there was no wait.
   - After a wait the client calls `POST /auth/reauth` (password plus the
     claim's device secret) before the forced changes.
4. **Events.** Sync `device.revoked` for each old device, then
   `account.recovered`, and audit `account.recovered {device_id, revoked}`.
   After commit, publish and `Hub.DisconnectDevice` each revoked device.

**Notices.**
- **At claim:** sync event `account.recovery.pending {request_id,
  device_name, ready_at}`, a generic push wake (no text; D53), and audit
  `account.recovery_requested`.
- **Active devices** show a persistent notice: "Someone is recovering your
  account on <device>, finishing <date>. Not you? Cancel, then change your
  password and recovery key."
- **Peers** see a new device and changed safety numbers, as for any new
  device.

## Client flow (mobile)

1. **Start** from the restored account-only session (prefilled), or "I lost
   all my devices" on the connect screen (no history). The RK is checked by
   the Rust decode before any network call. Then reserve.
2. **Account check.** If the reservation's `account_id` differs from the
   restored session's, **stop** ("this backup is for another account").
   Otherwise `_identityChanged` silently drops the restored history. On the
   restored path decoys end here too, with the same generic wording; on the
   no-history path a decoy only fails at the claim (401).
3. **Claim.** `createEnrollmentCredential` (a fresh MLS identity), then the
   recovery proof (new ABI), then claim.
4. **Persist the pending claim.** Store the claim token, device secret,
   request id, `ready_at` and the claim's MLS state; the wait spans days and
   restarts.
   - `pendingDeviceLinkClaim` is memory-only today.
   - Reuse K2's encrypted pending-enrollment storage (local schema 16) if it
     has landed. Otherwise build it here, and K2 reuses it.
5. **Finish.** Poll at start, on resume and hourly. On 200, do what
   `completeDeviceLinkClaim` does:
   - check origin, account and device;
   - save the session (the restored history is kept), cursor 0;
   - publish key packages, sync.
6. **Forced, before chats open.** Replace the RK (generate, show, confirm by
   typing, `PUT`), then change the password.
   - The old RK stays valid until it is replaced, so a crash never locks the
     user out.
   - `rk_pub` is stored only after the user typed the RK (K0).
7. **Groups.**
   - Peers' devices add the new device by I51 reconcile and remove the old
     leaves.
   - `joined_epoch` still withholds earlier messages; D54 and D74 cover
     gaps.
   - With no other account's live device (notes to self, abandoned groups),
     history is read-only and a new conversation is offered (K0 step 8).
8. **Setup.** Settings → "Set up a recovery key" (recent auth). K1 moves it
   into onboarding (D49).

## Abuse cases

| Case | Outcome |
|---|---|
| Stolen backup and code, plus a guessed password | No RK, so no recovery; a backup holds no credentials (D71) |
| Password phished, RK safe | Nothing; per-source backoff and the account cap apply |
| Password and RK stolen | Enrolls after the wait if the owner is active. The owner cancels, or changes the password or RK, which defeats the claim. Residual: an owner inactive for 7 d loses the account, and the admin (B9) suspends it |
| Thief with an unlocked phone | Cannot cancel without the password; completion revokes the phone |
| Operator, or a DB/R2 leak | Gets `rk_auth_pub`, `rk_id` and audit rows. A random RK is safe; a passphrase is guessable per D63. The operator could always insert devices (L1 residual) |
| Enumeration, replay, MITM | Decoy ids, the same error and work. The proof binds the challenge, the device key and the origin; reservations are one-time |

## Migration and ABI (next free numbers at landing; D70 and K2 also take some)

- **`account_recovery_keys`** `(account_id PK, auth_public_key, rk_id,
  created_at)`.
- **`account_recovery_requests`**:
  - `(id, account_id, device_id, device_name, key_package, signing_key,
    device_auth_hash, claim_token_hash UNIQUE, verified_password_hash,
    verified_auth_key, state, created_at, ready_at, expires_at,
    cancelled_by_device_id, completed_at)`;
  - a partial unique index on `(account_id) WHERE state='waiting'`.
- **`recovery_attempts`** `(account_id, day, failures)`;
  `instances.recovery_decoy_key`; reservation kind `recovery`. Expired rows
  are pruned with the reservations.
- **ABI**, additive, the next one after D70's 10 and K2: RK
  generate/encode/decode, derive `{rk_pub, rk_id, rk_auth_pub}`, sign the
  proof. It needs test vectors, a `docs/crypto.md` change-log entry and an
  update to the K0 key hierarchy.

## Tests

- **Go: credentials.** Equal work and the same error for an unknown user, no
  RK, a wrong password and a wrong RK. Stable decoys. The account backoff
  counts only on `rkOK`, and the durable cap survives a restart.
- **Go: lifecycle.**
  - The wait turns on and off with activity; cancel needs recent auth.
  - A password or RK change during the wait gives 410.
  - The reservation is consumed at claim, and completion happens after 10
    minutes.
  - Revoking two old devices with a peer and a legacy group never makes the
    new device or an old one coordinator.
  - Route classes for every path and spelling.
- **Rust.** Vectors for derive and the proof.
- **Flutter.** Account-mismatch refusal; the claim survives a restart; the
  history is kept; the forced RK and password changes; read-only no-peer
  conversations; the notice and cancel.
- **Demo e2e.** Restore → recover with no other device → a peer re-adds it →
  messages flow, and the old device is revoked.

## Packages, in order

1. **R1, Rust/ABI** (Opus review, after O2): RK codec, derive, proof,
   vectors.
2. **R2, Server** (Opus review): migration, routes and classes, backoff,
   wait, completion, events and audit, `docs/operations.md`.
3. **R3, Client setup**: set or replace the RK in Settings, and status.
4. **R4, Client recovery**: reserve and claim, the persisted claim,
   completion, forced changes, no-peer read-only, notice and cancel, and the
   banner restore action (STATE "Banner hides backup restore").
5. **R5**: independent review of R1–R4, a demo e2e run, STATE. Later: P1
   passphrase (O4), and K1 durable backups for history after a disaster.

## Owner decisions

- **O1. Durable backups.** History after losing every device needs a
  downloadable backup.
  - (a) Keep the 15-minute I45 window until K1 (recommended): the account
    comes back, history only for same-day moves.
  - (b) Lift it now. Backups hold no credentials (D71), but the code
    `v1.origin.token.key` becomes a long-lived key to the history.
- **O2.** `ed25519-dalek` as a direct crypto dependency, for the signature
  proof (recommended), or K0's bearer `SHA-256(L)`.
- **O3.** Numbers: activity window 7 d, wait 7 d, failure cap 50/day. A
  same-day move waits 7 d unless the old phone signed out.
- **O4.** Whether the passphrase package (D57/D63, Argon2 crate) runs before
  or after K1.
