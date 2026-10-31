# K0 recovery enrollment (password + recovery key)

**Status: proposed (2026-10-31), not built.** Implements K0's "All devices
lost" ([K0](K0-long-lived-key.md)) under D49, D57, D63, D71, D73 and D77.
The owner's answers are D78 and D79. Credential and recovery change: it
needs an independent review (AGENTS.md).

## Where things stand

- **No device-less way in.** `login` (`auth_handlers.go`) needs a device id
  and secret. A D71/D73 restore leaves an account-only session
  (`restoredAccountSession`) that only a device link finishes.
- **What exists.** The K0 recovery key (RK) is not built; only VHC1's
  `rk_id` field exists. I45 backups live 15 minutes
  (`RecoveryCapabilityLifetime`, `content_store.go`; one-time per TASK-168),
  and D78 keeps that until K1.
- **So, honestly:** this gives the **account** back on a new device to
  someone who lost every device. It brings **history** back only if a
  restore happened inside that window. Disaster recovery of history waits
  for K1's durable backups. UI and docs must not claim more.

## Proof of the user

- **RK.** K0's 30-byte entropy and 52-character display, with PRK =
  HKDF-Extract("veritra-k0-v1", entropy).
  - A new label, `"veritra-k0 recovery-auth"`, gives a 32-byte Ed25519
    seed, and from it **`rk_auth_pub`**. `ed25519-dalek` becomes a direct
    dependency (D78).
  - This replaces K0's `SHA-256(L)` bearer verifier; `L` stays reserved and
    unused.
  - `rk_pub` and `rk_id` are derived now too, so K1 reuses the same key.
- **The proof.** Built in Rust; Dart gets no sign-anything entry point:
  `"veritra-k0-recovery-proof-v1" | lp(challenge) | signing_key |
  SHA-256(key_package) | lp(origin)`. It binds the reservation, the new
  device and the origin, and the server never receives a reusable secret.
- **The origin is a server setting, never the request.** A new required
  setting, `PRIVATE_MESSENGER_PUBLIC_ORIGIN` (`config.go`), holds the
  canonical `https://host[:port]`, the one permanent hostname (STATE,
  "Needed from the owner"). The rules:
  - The server rebuilds the proof message with that value and verifies
    against it. It never derives the origin from `Host`,
    `X-Forwarded-Host` or the body.
  - While the setting is unset, every `/account-recovery/` route answers
    503 `recovery_not_configured`, the same for every account, and
    `GET /account/recovery-key` reports `available: false`, so the app
    offers no setup.
  - **What it prevents.** A user can be steered to a look-alike origin
    that relays to the real server. Their own app then signs a proof for
    the look-alike origin, and the relay forwards the claim and keeps the
    returned claim token and device secret. With the session, it then
    changes the password, swaps the RK and has revoked every real device:
    a full takeover. The real server refuses that proof because its origin
    differs. A server that took the origin from `Host` would accept it.
- **Password.** Checked as in `login`: Argon2id (D34), a dummy hash when
  there is no account, and the 3 hashing slots. **The claim never
  rehashes** (no `passwords.Upgrade`); a legacy hash upgrades at the next
  login.
- **Offline guessing (D63).**
  - A random RK has 240 bits, out of reach.
  - A passphrase RK can be guessed offline by whoever holds `rk_auth_pub`.
    Later, any K1 backup sealed to `rk_pub` is a second oracle, so
    peppering or encrypting the verifier adds little.
  - The defence is on the client:
    - Argon2id(passphrase, salt = SHA-256("veritra-k0-pp-v1" | origin |
      account_id)), with at least 128 MiB, about 1 s on the slowest
      supported phone;
    - a strength floor;
    - refusing the login password;
    - D63's plain warning.
  - The passphrase package comes after K1 (D78).

## Server API

Paths sit under `/api/v1/account-recovery/`, not `/api/v1/recovery` (the
I45 download credential route). In `ClassifyRoute`:
- `…/enrollment` keeps the enrollment budget (5/min);
- every other path under the prefix is a credential route (10/min), as for
  device-link v3, alternate slash spellings included.

| Route | Auth | Does |
|---|---|---|
| `PUT /api/v1/account/recovery-key` | `withRecentAuth` | Set or replace `{rk_auth_pub, rk_id}`. In the same transaction it cancels any waiting request; sync event; audit `account.recovery_key_set` |
| `GET /api/v1/account/recovery-key` | `withAuth` | `{available, configured, rk_id, set_at, pending_request?}` |
| `POST …/account-recovery/enrollment` | none | `{username}` → reservation `{id, account_id, device_id, challenge, expires_at}`, kind `recovery`. This is the **only** route that takes a username |
| `POST …/account-recovery/claim` | none | `{enrollment_reservation_id, password, device_name, device_key_package, signing_key, challenge_signature, recovery_signature}`, **no username**. The account is the reservation's `account_id`. Returns 202 `{request_id, claim_token, device_secret, state, ready_at}`, or 401 `invalid_credentials` |
| `GET …/account-recovery/{id}/status` | `X-Veritra-Claim-Token` | 202 `{state:"waiting", ready_at}`; when ready, 200 `{state:"completed", account, device, token}` the first time, then 200 `{state:"completed", account, device}` with no token; 410 `recovery_cancelled` |
| `POST …/account-recovery/{id}/cancel` | `withRecentAuth`, same account | Cancel a waiting request; audit `account.recovery_cancelled` |

**No enumeration oracle.**
- The reservation carries `account_id` because the challenge encodes it
  (`createEnrollmentReservation`).
  - A known, active username gets its real id.
  - Any other username (unknown, suspended or deleted) gets a decoy:
    `"acct_" + hex(HMAC-SHA256(decoy key,
    NormalizeUsername(username))[:16])`. It has the same format (it passes
    `domain.ValidID`) and is stable.
  - The decoy key is 32 random bytes in `instances`. That row exists only
    after setup, so the migration backfills it for an existing instance and
    setup creates it.
- **The claim trusts only the reservation's `account_id`.** It looks up the
  account record by id, with `status = 'active' AND deleted_at IS NULL`,
  as `LoginRecord` does. A decoy, unknown, suspended or deleted account
  gets the dummy hash and the decoy RK key: the same work and the same
  401. One user's reservation can never be used with another user's
  credentials.
- **Does an unauthenticated route take an account id?** No (checked
  2026-10-31 against `api.go` and `device_link_v3_handlers.go`). The
  unauthenticated routes take a username (setup, login, register), a
  device id (login), or codes, tokens, claim tokens and link ids.
  - **Residual:** signed-in routes do take account ids (conversation and
    community members in `conversation_handlers.go`, conversation
    creation, key-package claims), and they answer differently for an id
    that does not exist. So the decoy stops anonymous enumeration, but not
    an insider: any account on this invite-only instance can tell a decoy
    from a real id. Accepted; the fix would be uniform answers on those
    routes, out of scope here.

**Claim handler.** It does the same work on every path, with no early
return:
1. If the origin is not configured, answer 503. Then the size checks, and
   `challenge_signature` with the device key (cheap, public data), before
   any hashing slot, as `register` does.
2. Check the password against the account's hash, or the dummy hash.
3. Check `recovery_signature` against `rk_auth_pub`, or a fixed decoy key.
   The message is built with the configured origin.
4. **The D79 cap.**
   - Read and write the `recovery_attempts` row for `(reservation
     account_id, day)` on **every** failed claim, adding
     `passwordOK && !rkOK ? 1 : 0`. Writing every time keeps the timing
     equal.
   - The table has no foreign key, so decoy ids count too.
   - Once the count is over 50, force `rkOK = false`. The answer stays the
     same 401, never a 429.
   - On a real account, the first time the cap trips each day, send its
     devices a sync event `account.password_leak_suspected` (a notice: "Your
     password was used with a wrong recovery key many times. Change your
     password.").
5. `ok = exists & active & passwordOK & rkOK`.

On success, in one transaction:
- consume the reservation (it expires in 10 minutes, so it must not wait
  for completion);
- insert the request with the device fields and, as **verified**, the
  current `password_hash` and `rk_auth_pub`.

**Backoff.**
- `LoginBackoff` key `recovery-source\x00ip\x00<reservation account_id>`
  counts every failure.
- `recovery-account\x00<account_id>` is checked and counted only when
  `rkOK`, as `deviceOK` is in `login`. Only an RK holder can drain it, and
  no 429 reveals whether the password was right.
- Both keys come from the reservation's id, never a username in the body.

**Waiting period (D49; numbers D78).**
- **Active devices:** not revoked, an unexpired session, and
  `devices.last_seen_at` within `RECOVERY_ACTIVE_WINDOW` (7 d).
- **Wait:** with any active device, `ready_at = now + RECOVERY_WAIT` (7 d);
  otherwise `now`. Both are `PRIVATE_MESSENGER_RECOVERY_*` settings.
- **Cancel** needs recent auth (password and device secret), so a thief
  holding an unlocked phone cannot block the owner. There is no early
  approval.
- **What else cancels a waiting request, in the same transaction:**
  `ChangePassword`, `ResetOwnerPassword` and the RK `PUT`. A sync event
  and an audit entry follow.
- **One waiting request per account.** A new valid claim replaces it,
  restarts the timer and notifies again. Unclaimed requests expire 3 d after
  `ready_at`.
- **Same-day movers** whose old phone still works link from it (L0 and K2;
  D77). Recovery is for lost devices. If they recover anyway, the old phone
  is active, so the full wait applies.

**Completion** (the status call after `ready_at`), in one transaction:
1. **Lock the request.** It must be `waiting`, with `ready_at <= now`, and
   the account `active` and not deleted. Otherwise answer 410, and a
   suspended account gets the same 410.
   - The backstop: the account's `password_hash` and `rk_auth_pub` must
     still equal the verified copies.
   - The cancel-on-change rule above is the primary mechanism. A legacy or
     changed-parameters rehash by a login (`UpgradePasswordHash`) must not
     cause a false 410, so that statement also moves the hash forward: in
     the same transaction, `verified_password_hash = updated` on the
     account's waiting request where it equals `current`.
2. **Revoke every other device before inserting the new one.**
   - For each old device, run what `revokeDevice` (`identity_store.go`) runs,
     as a helper in this transaction: set `revoked_at`, delete its sessions,
     `retireDeviceLinksV3ForDevice`, `queueMLSRevocations` and
     `releaseMLSRevocationConfirmations`. Without the release, a pending
     revocation an old device had to confirm waits for good.
   - Only the new device must come last. In a legacy group (no roster),
     every non-revoked device of a member may coordinate
     (`mlsRevocationEligibleDevice`), and `mls_revocation_required_devices`
     is snapshotted at queue time. A new device inserted first, which has
     no leaf, could then become coordinator or a required confirmer, and the
     revocation would stall.
   - Revoking old devices one at a time is safe:
     `mlsRevocationCoordinator` re-elects once a recorded coordinator is
     revoked, and the release clears a revoked sibling's confirmations.
3. **Insert the new device** from the request, with its first key package
   and a session.
   - `recent_auth_at` is **never** set here, even with no wait.
   - The client calls `POST /auth/reauth` (password plus the claim's device
     secret) before the forced changes.
4. **Events.** Sync `device.revoked` for each old device, then
   `account.recovered`. Audit `account.recovered {device_id, revoked}`.
   After commit, publish, and call `Hub.DisconnectDevice` for each revoked
   device.
5. **A lost 200.** The session token is returned once. Later status calls
   answer `completed` without it, and the client signs in with the
   existing `login` (username, password, device id, and the device secret
   from the claim).

**Notices.**
- **At claim:**
  - sync event `account.recovery.pending {request_id, device_name,
    ready_at}`;
  - a generic push wake (no text; D53);
  - audit `account.recovery_requested`.
- **Active devices** show a persistent notice: "Someone is recovering your
  account on <device>, finishing <date>. Not you? Cancel, or change your
  password or recovery key."
- **Peers** see a new device and changed safety numbers.

## Client flow (mobile)

1. **Start.** From the restored account-only session (prefilled), or from
   "I lost all my devices" (no history). The Rust decode checks the RK
   before any network call. Then reserve.
2. **Account check.** If the reservation's `account_id` differs from the
   restored session's, **stop** ("this backup is for another account").
   Otherwise `_identityChanged` silently drops the restored history. On the
   no-history path, a decoy only fails at the claim (401).
3. **Claim.** `createEnrollmentCredential` (a fresh MLS identity), the
   recovery proof over the canonical origin the app uses, then the claim.
4. **Persist the pending claim.**
   - What: the claim token, device id, device secret, request id,
     `ready_at` and the claim's MLS state.
   - Where: K2's encrypted pending-enrollment storage (local schema 16) if
     it has landed. Otherwise this package builds it, and K2 reuses it.
   - **Never in a backup** (D71): the export skips it, and
     `backup_no_credentials_test.dart` scans for it.
5. **Finish.** Poll at start, on resume and hourly.
   - On 200 with a token, do what `completeDeviceLinkClaim` does: check
     origin, account and device; save the session (the restored history is
     kept); set cursor 0; publish key packages; sync.
   - On `completed` without a token, ask for the password and `login`.
6. **Forced, before chats open.** `reauth`, then replace the RK (generate,
   show, confirm by typing, `PUT`), then change the password.
   - The old RK stays valid until it is replaced, so a crash never locks the
     user out.
   - `rk_pub` is stored only after the user typed the RK (K0).
7. **Groups.**
   - Peers' devices add the new device by I51 reconcile and remove the old
     leaves.
   - `joined_epoch` still withholds earlier messages; D54 and D74 cover the
     gaps.
   - With no other account's live device (notes to self, abandoned
     groups), the history is read-only and a new conversation is offered
     (K0 step 8).
8. **Setup.** Settings → "Set up a recovery key" (recent auth). K1 moves it
   into onboarding (D49).

## Abuse cases

| Case | Outcome |
|---|---|
| Stolen backup and code, plus a guessed password | No RK, so no recovery; a backup holds no credentials (D71) |
| Password phished, RK safe | Nothing. After 50 wrong-RK tries a day the owner is warned (D79). Residual: the real owner's recovery is also refused that day |
| Look-alike origin relaying to the real server | The proof names the wrong origin, so the server refuses it |
| Password and RK stolen | Enrolls after the wait if the owner is active. The owner cancels, or changes the password or RK, which cancels it. Residual: an owner inactive for 7 d loses the account, and the admin (B9) suspends it |
| Thief with an unlocked phone | Cannot cancel without the password; completion revokes the phone |
| Operator, or a DB/R2 leak | Gets `rk_auth_pub`, `rk_id` and audit rows. A random RK is safe; a passphrase can be guessed per D63. The operator could always insert devices (L1 residual) |
| Enumeration, cross-account, replay | Decoy ids and the same work; the claim uses the reservation's account only; the proof binds the challenge, device key and origin; reservations are one-time. Insider residual above |

## Migration and ABI (next free numbers at landing; D70 and K2 also take some)

- **`account_recovery_keys`** `(account_id PK, auth_public_key, rk_id,
  created_at)`.
- **`account_recovery_requests`**:
  - `(id, account_id, device_id, device_name, key_package, signing_key,
    device_auth_hash, claim_token_hash UNIQUE, verified_password_hash,
    verified_auth_key, state, created_at, ready_at, expires_at,
    cancelled_by, completed_at)`;
  - a partial unique index on `(account_id) WHERE state='waiting'`.
- **`recovery_attempts`** `(account_id, day, failures, leak_notified)`,
  with no foreign key (decoys).
- **Other changes:** `instances.recovery_decoy_key`; reservation kind
  `recovery`; the config setting `PRIVATE_MESSENGER_PUBLIC_ORIGIN`. Expired
  rows are pruned with the reservations.
- **ABI.** Additive, the next one after D70's 10 and K2:
  - RK generate, encode and decode;
  - derive `{rk_pub, rk_id, rk_auth_pub}`;
  - sign the proof.

  It needs test vectors, a `docs/crypto.md` change-log entry and an update
  to the K0 key hierarchy.

## Tests

- **R2, Go credentials.**
  - Equal work and the same 401 for an unknown, suspended or deleted
    account, no RK, a wrong password and a wrong RK.
  - Stable decoys.
  - A claim with A's reservation and B's credentials fails, and touches
    only A's counters.
  - A proof made for another origin, or relayed through one, gets 401.
  - With the origin unset, every recovery route answers 503.
  - D79: only `passwordOK && !rkOK` counts; a decoy counts too; over the
    cap a correct RK still gets 401; the leak notice goes out once a day;
    the counter survives a restart.
  - The account backoff counts only on `rkOK`.
- **R2, Go lifecycle.**
  - The wait turns on and off with activity; cancel needs recent auth.
  - A password change, an owner reset or an RK `PUT` cancels in the same
    transaction.
  - **No false 410 after a rehash**: a login that upgrades the hash during
    the wait still lets completion run.
  - The reservation is consumed at claim, and completion works after 10
    minutes.
  - A lost 200 is followed by `completed` without a token, and `login`
    works.
  - Completion never sets `recent_auth_at`.
  - Revoking two old devices with a peer and a legacy group never makes the
    new device coordinator.
  - **The release of old devices' pending revocation confirmations.**
  - Route classes for every path and spelling.
- **Rust.** Vectors for derive and the proof.
- **Flutter.**
  - Account-mismatch refusal.
  - The claim survives a restart and is absent from a backup.
  - The history is kept.
  - The completed-without-token login.
  - The forced changes.
  - Read-only no-peer conversations.
  - Notices and cancel.
- **Demo e2e.** Restore, recover with no other device, a peer re-adds the
  new device, messages flow, and the old device is revoked.

## Packages, in order

1. **R1, Rust/ABI** (Opus review): RK codec, derive, proof, vectors, and
   the `ed25519-dalek` notice.
2. **R2, Server** (Opus review): config origin, migration, routes and
   classes, backoff and the D79 cap, wait, cancel-on-change, completion,
   events and audit, `docs/operations.md`.
3. **R3, Client setup**: set or replace the RK in Settings, and status.
4. **R4, Client recovery**: reserve and claim, the persisted claim,
   completion and the lost-200 login, the forced changes, no-peer read-only
   conversations, notices and cancel, and the banner restore action (STATE
   "Banner hides backup restore").
5. **R5**: independent review of R1–R4, a demo e2e run, STATE. Later: K1
   durable backups, then the passphrase option (D78).

## Decided, and what is left

- **Decided.** D78 settled O1–O4: keep the 15-minute window until K1;
  `ed25519-dalek`; 7 d, 7 d and 50 a day; passphrase after K1. D79 settled
  the cap.
- **Left for the owner.** Set `PRIVATE_MESSENGER_PUBLIC_ORIGIN` on the
  deployment; it is the permanent hostname already on the owner list.
  Until it is set, recovery stays off.
