# B7: passkeys and accounts (design)

**Status: proposed (2026-11-07), not built.** This is a credential-area
change. An independent review must approve S1 and S3 before either lands
(AGENTS.md). B7 does not change the MLS protocol, the crypto ABI or any
payload, so `docs/crypto.md` stays as it is.

- **Package:** B7 in the `STATE.md` build plan (route "Opus designs").
- **Done when:** "Passkey sign-in and an in-app account switcher."
- **Owner approval:** one passkey library dependency (see
  [Libraries](#libraries)). The design names one Go module and one Flutter
  plugin family. Their transitive packages fall under that approval and
  each needs a `THIRD_PARTY_NOTICES.md` entry at build time.
- **Counters:** one server migration (S1), with the number reserved by the
  coordinator at build time. No crypto ABI change. No local schema change:
  the account list lives in secure storage, not in any database.

## Summary

- A **passkey replaces the password at sign-in, and only there.** Sign-in
  still needs an enrolled device: the device ID and device secret are
  checked at both steps of the passkey flow, exactly as `login` checks them
  today. A passkey never adds a device. New devices still come only from
  registration, device link (L0) or K0 recovery.
- A **passkey sign-in grants no recent authentication.** Every
  `withRecentAuth` route stays password-only: logout-all, password change,
  invites, device removal, device link, export, account delete, admin
  status, the recovery-key `PUT` and K0 cancel. Adding or removing a
  passkey also needs a recent password check.
- The **relying party ID is the exact host of
  `PRIVATE_MESSENGER_PUBLIC_ORIGIN`**, which is the one permanent hostname.
  Passkeys are off unless the operator turns them on and that origin
  qualifies.
- **Platforms:** Android and Windows can work with any self-hosted
  hostname. iOS and macOS work only for hostnames compiled into the app's
  entitlements. Linux has no support in the plugin, so Linux stays
  password-only. See [Platforms](#platforms).
- The **account switcher** keeps one account active at a time. Each account
  has its own storage slot, built on the existing `SecureLocalStore`
  namespace. The existing install becomes the first slot without moving any
  file. Inactive accounts are paused: no sync, no push and no notices.

## Where things stand

- **`login`** (`server/internal/httpapi/auth_handlers.go`) needs a
  username, password, `device_id` and `device_secret`. It verifies the
  password even when the lookup fails (constant work), and checks the
  device secret in constant time. It counts failures against a source key,
  and against an account-device key only when the device secret was valid.
- **`CreateLoginSession`** (`server/internal/storage/identity_store.go`)
  inserts the session only `WHERE a.password_hash = ?`, the hash that was
  verified. A concurrent password change therefore wins. It sets
  `recent_auth_at = now`.
- **`withRecentAuth`** (`server/internal/httpapi/api.go`) requires
  `recent_auth_at` within 5 minutes. K0 relies on this: "Cancel needs
  recent auth (password and device secret), so a thief holding an unlocked
  phone cannot block the owner" (`K0-recovery-enrollment.md`).
- **Sessions** (T37C, D34): idle 14 days, absolute 30 days counted from the
  last password and device-secret check, and token rotation at reauth.
- **On the phone, password sign-in already needs a linked device:**
  `AppState.login` throws `errorPasswordLoginNeedsLink` when it has no
  stored device ID and secret for that server.
- **`SecureLocalStore(namespace:)`** already separates the database
  directory, the database key and the legacy record key per namespace.
  Demo builds use it for `--profile` (`main_demo.dart`). The release build
  uses the empty namespace.
- **`PRIVATE_MESSENGER_PUBLIC_ORIGIN`** (`config.go`, `ValidPublicOrigin`)
  holds `https://host[:port]`. K0 proofs are bound to it, and clients warn
  when they reach the server under another address.

## Server

### Library

`github.com/go-webauthn/webauthn` v0.18.2, BSD-3-Clause. It is the
maintained successor of `duo-labs/webauthn`, which is archived. Details are
in [Libraries](#libraries). The handlers use its `webauthn` package with:

- `RPID` = the host of the public origin; `RPDisplayName` = "Veritra";
- `RPOrigins` = `https://<host>` plus each configured
  `android:apk-key-hash:<base64url(SHA-256(cert))>`;
- attestation preference `none`; resident key `required`; user
  verification `required`;
- algorithms EdDSA (-8), ES256 (-7) and RS256 (-257). Windows Hello on some
  TPMs registers RS256 keys.

The library's `SessionData` is stored server-side (see the ceremonies
table). It never goes to the client.

### Configuration

| Setting | Meaning |
|---|---|
| `PRIVATE_MESSENGER_PASSKEYS` | `off` (default) or `on` |
| `PRIVATE_MESSENGER_PASSKEY_ANDROID_APPS` | Comma list of `package:SHA256-fingerprint` (hex, as `keytool` prints it). Builds `assetlinks.json` and the Android origins |
| `PRIVATE_MESSENGER_PASSKEY_APPLE_APP_IDS` | Comma list of `TEAMID.bundle.id`. Builds `apple-app-site-association` |

When the setting is `on`, startup fails unless all of the following hold:

- the public origin is set and valid (`ValidPublicOrigin`);
- it uses `https`;
- it has **no port**. The iOS and Windows authenticators report the origin
  `https://<rpid>` without a port, so a port would make every assertion
  fail;
- its host is a DNS name with a dot. IP addresses and `localhost` are
  refused.

Turning passkeys on is an operator choice and is never automatic.
Registering a passkey ties users to the hostname, and on Android and Apple
platforms it tells Google or Apple the hostname (see
[Threats](#threats)).

The Android signing certificate is not pinned in this repository yet
(`STATE.md`, "Signing pins"), so the fingerprints are operator input. Debug,
emulator and release builds have different fingerprints. Operations
documents the release one once it exists.

### Well-known files

The Go server serves both files from the settings above, with no redirect
and `Content-Type: application/json`. Both shipped proxies already pass
every path through: Caddy's `reverse_proxy` and the Traefik `Host()` match.

- `GET /.well-known/assetlinks.json`: one entry per Android app, with
  relation `delegate_permission/common.get_login_creds`.
- `GET /.well-known/apple-app-site-association`:
  `{"webcredentials":{"apps":[...]}}`.

Both routes answer 404 while passkeys are off or their list is empty. They
are public and static, and they use the general per-address budget.

### Routes

| Route | Auth | Body | Answer |
|---|---|---|---|
| `POST /api/v1/auth/passkey/options` | none; credential budget (10/min) | `{device_id, device_secret}` | 200 `{ceremony_id, public_key}`. 401 `invalid_credentials`. 503 `passkeys_not_configured` |
| `POST /api/v1/auth/passkey` | none; credential budget | `{ceremony_id, device_id, device_secret, credential}` | 200 `{token, account_id, device_id, role}`, the same shape as `login`. 401 `invalid_credentials` |
| `GET /api/v1/account/passkeys` | `withAuth` | none | `{passkeys:[{id, name, created_at, last_used_at, synced}]}` |
| `POST /api/v1/account/passkeys/options` | `withRecentAuth` | none | 200 `{ceremony_id, public_key}` |
| `POST /api/v1/account/passkeys` | `withRecentAuth` | `{ceremony_id, name, credential}` | 201 `{id}`. 409 `passkey_limit` |
| `PATCH /api/v1/account/passkeys/{id}` | `withAuth` | `{name}` | 204 |
| `DELETE /api/v1/account/passkeys/{id}` | `withRecentAuth` | none | 204 |

`GET /api/v1/setup/status` gains `passkeys: {rp_id}` while passkeys are
on, so the app can offer the button before anyone signs in. That reveals
configuration only.

**Sign-in options.** The handler checks the device ID and secret with the
same constant-time comparison as `login`. The device must be active and its
account active and not deleted. A wrong secret, an unknown device and a
revoked device all get the same 401.

On success it returns a 32-byte challenge, with `allowCredentials` set to
that account's credential IDs. Only a holder of the device secret learns
the IDs. The OS picker then shows only this account's passkeys, which
matters when two accounts on one phone use the same server.

No username is taken, so the route is no enumeration oracle.

**Sign-in finish.** These checks run in order:

1. Re-check the device secret, as in options.
2. Load the ceremony by `ceremony_id`. Its kind must be `login`, its
   `device_id` must match, and it must not have expired.
3. Verify with the library:
   - the challenge, origin and RP ID hash;
   - the UP and UV flags (both required);
   - the signature over the stored public key.

   Then apply Veritra's own checks:
   - the credential belongs to the ceremony's account;
   - `userHandle` equals that account's handle.
4. **Backup flags.** A change in backup eligibility (BE) is refused. A
   change in backup state (BS) is stored and is not an error.
5. **Sign count.** When the stored and received counts are both nonzero
   and the received one is not greater, sign-in is refused and the audit
   log gets `passkey.clone_warning {passkey_id}`. Synced passkeys always
   report 0, so they get no clone detection. That is accepted.
6. Run one writer transaction (below), then answer like `login`. Audit:
   `session.login {device_id, method: "passkey"}`.

Every failure answers the same 401 `invalid_credentials` and counts against
the **same backoff buckets as password login**: the source key always, and
the account-device key only when the device secret was valid. Switching
between password and passkey therefore does not double an attacker's
budget.

**The writer transaction (race fence).** It mirrors `CreateLoginSession`'s
`password_hash` fence and is all-or-nothing:

1. `DELETE FROM passkey_ceremonies WHERE id = ? AND kind = 'login' AND
   device_id = ? AND expires_at > now`. It must remove exactly one row, so
   a ceremony is single-use even under concurrent finishes.
2. `UPDATE passkey_credentials SET sign_count = ?, backup_state = ?,
   last_used_at = ? WHERE id = ? AND account_id = ? AND sign_count = <value
   read before verification>`. It must change exactly one row. A passkey
   deleted meanwhile (by its owner, or by K0 completion if O5 is yes)
   matches no row. Two concurrent uses of the same passkey cannot both
   commit.
3. `INSERT INTO sessions ... SELECT ... FROM accounts a JOIN devices d ...
   WHERE a.id = ? AND a.status = 'active' AND a.deleted_at IS NULL AND
   d.id = ? AND d.account_id = a.id AND d.revoked_at IS NULL AND
   d.auth_secret_hash = <the hash just verified>`. It must insert one row.
   `recent_auth_at` stays NULL, and the idle and absolute expiry start now.
   A device revoked, an account suspended or a device secret changed
   meanwhile matches no row.

The password hash is deliberately **not** fenced. This path never checked
the password, and a password change does not invalidate passkeys. A
sign-in that commits just after a password change is the same as one that
starts just after it.

**Registration.**

- **Options** returns:
  - `rp`;
  - `user {id: handle, name: username, displayName: username}`;
  - `excludeCredentials` = the account's credentials;
  - a challenge, with `residentKey: required` and
    `userVerification: required`.
- The account's **handle** is 32 random bytes, created at the first
  registration. It is not the account ID, so a credential manager that
  syncs to a third party holds no Veritra identifier beyond the username.
- **Finish** checks recent auth again, because the 5-minute window can
  close during the ceremony. It verifies the response, then inserts in one
  transaction that consumes the ceremony.
- **Credential IDs are unique across the instance**, as WebAuthn requires,
  so a duplicate ID is refused.
- **Limit:** 10 passkeys per account.
- **Stored data:** the credential ID, the COSE public key, the algorithm,
  the sign count, BE, BS, the transports, the name and the times. The
  AAGUID is **not** stored: with attestation `none` it only tells the
  server which password manager the user runs.
- **Name:** at most 64 characters. The app suggests "Passkey 1", "Passkey
  2", and so on, never a device model.
- **Afterwards:** audit `passkey.added {passkey_id}`, and a sync event
  `account.passkey_added {passkey_id}` so other devices show a notice
  ("A passkey was added to your account").
- **Removal** audits `passkey.removed` and emits
  `account.passkey_removed`.

**Ceremonies.**

- Each ceremony expires after 3 minutes.
- A device may hold at most 4 open ceremonies. A new one evicts the oldest.
- Expired rows are pruned with the enrollment reservations.
- Revoking a device only sets `revoked_at`, so the revoke helper also
  deletes that device's ceremonies. Deleting an account deletes the
  account's ceremonies and passkeys in its transaction. The foreign keys
  cascade only on a hard row delete. Even a ceremony that is missed fails
  at finish, because the fence requires an active device and account.

### Schema (one migration, number reserved at build time)

```sql
CREATE TABLE passkey_user_handles (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  user_handle BLOB NOT NULL UNIQUE,      -- 32 random bytes
  created_at TEXT NOT NULL
);
CREATE TABLE passkey_credentials (
  id TEXT PRIMARY KEY,                   -- random row id; the only id in audit and sync
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  credential_id BLOB NOT NULL UNIQUE,
  public_key BLOB NOT NULL,              -- COSE key
  algorithm INTEGER NOT NULL,
  sign_count INTEGER NOT NULL,
  backup_eligible INTEGER NOT NULL,
  backup_state INTEGER NOT NULL,
  transports TEXT NOT NULL DEFAULT '',
  name TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT
);
CREATE INDEX idx_passkey_credentials_account ON passkey_credentials(account_id);
CREATE TABLE passkey_ceremonies (
  id TEXT PRIMARY KEY,                   -- 32 random bytes, base64url
  kind TEXT NOT NULL CHECK (kind IN ('register', 'login')),
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  session_data BLOB NOT NULL,            -- the library's SessionData, JSON
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE INDEX idx_passkey_ceremonies_device ON passkey_ceremonies(device_id, created_at);
CREATE INDEX idx_passkey_ceremonies_expiry ON passkey_ceremonies(expires_at);
```

The migration only adds tables. An older binary ignores them, and passkey
users fall back to their password. **Account export** lists each passkey's
name and times, never the key material.

### What else changes on the server

- **Wording (T37C, operations.md):** "the absolute lifetime counts from the
  last password **or passkey** sign-in, each with the device secret".
  Password reauth still rotates the token. A passkey sign-in creates a new
  session, as a password `login` does.
- **Logging:** request bodies are never logged, as today. Audit and sync
  rows carry the passkey row ID only, never the credential ID, the public
  key, the challenge or the ceremony ID.
- **Suspension, deletion and offline owner reset** behave as they do for
  password sign-in. A suspended account is refused at both steps. The
  offline owner reset leaves passkeys in place, because it is for a lost
  password.

## K0 interplay

- **The K0 claim stays password plus recovery key (D49).** A passkey is
  never accepted in its place (O4).
- **A passkey session cannot cancel a recovery**, because it carries no
  recent authentication. This keeps K0's guarantee against a thief who
  holds an unlocked phone and knows its PIN.
- **Adding or removing a passkey does not cancel a waiting recovery.**
  Password change, offline reset and the recovery-key `PUT` still do.
- **Completion (default, O5): delete every passkey of the account** in the
  completion transaction, together with the account's open
  `passkey_ceremonies`.
  - Completion means the user lost every device. Passkeys registered on a
    lost phone, or by someone who held it, should not outlive that.
  - A synced passkey is re-added in one step after the forced password
    change, and the recovery client flow offers it there.
  - This edits reviewed K0 completion code
    (`account_recovery_store.go`), so the K0 reviewer checks that change.
- **D79's leaked-password warning is unchanged.** A user who signs in only
  with a passkey still sees it and is asked to change the password.

## Platforms

| Platform | Passkeys | What it needs |
|---|---|---|
| Android 9+ (Credential Manager) | Yes, any self-hosted hostname | The server serves `assetlinks.json` naming the app's package and signing certificate. Play services verify it, and the origin is `android:apk-key-hash:...` |
| Windows 10 1903+ (`webauthn.dll`) | Yes, any hostname | Nothing in the OS checks that the app and the domain belong together. The app pins `rp.id` itself (below) |
| iOS 16+, macOS 13.5+ | Only hostnames in the build's `webcredentials:` associated domains | A team-signed build whose entitlements list the hostname, plus the AASA file on the server. Unsigned macOS demos carry no entitlements, so they get no passkeys (O1) |
| Linux | No | The plugin has no Linux support. Security keys over CTAP (libfido2) would be a new dependency (O2) |

**The app pins the RP ID.** Before calling the platform, the app checks
that `public_key.rp.id` (and, for sign-in, the RP ID the options imply)
equals:

- the host of the server URL that this slot uses, and
- the `rp_id` that the server advertised in setup status.

Otherwise it refuses and calls nothing. On Windows this is the only check
that stops a hostile server from asking for an assertion meant for another
server.

**Where the button shows.** On iOS and macOS the app also needs the host
to be in a compile-time list (`--dart-define=VERITRA_PASSKEY_DOMAINS=...`)
that matches the entitlements. A host missing from that list never sees
the passkey button.

## Libraries

### Go: `github.com/go-webauthn/webauthn` v0.18.2 (2026-09-19)

Resolved against the server's `go.mod` (go 1.26.10) in a scratch module,
and built: `go list -deps` shows these modules newly linked into the
binary.

| Module | Version | Licence | Why it is pulled in |
|---|---|---|---|
| `github.com/go-webauthn/webauthn` | v0.18.2 | BSD-3-Clause | The library |
| `github.com/go-webauthn/x` | v0.3.1 | BSD-3-Clause | Helpers from the same project |
| `github.com/fxamacker/cbor/v2` | v2.9.4 | MIT | CBOR and COSE decoding |
| `github.com/x448/float16` | v0.8.4 | MIT | Used by cbor |
| `github.com/google/go-tpm` | v0.9.8 | Apache-2.0 | TPM attestation parsing. Linked even with attestation `none` |
| `github.com/go-viper/mapstructure/v2` | v2.5.0 | MIT | Metadata decoding |
| `github.com/tinylib/msgp` | v1.6.4 | MIT | Serialisation helpers |
| `github.com/philhofer/fwd` | v1.2.0 | MIT | Used by msgp |

- `golang-jwt/jwt/v5` moves from v5.2.2 to v5.3.1 (MIT; it is already
  indirect through `webpush-go`). `google/uuid` is already present.
- MIT, BSD-3-Clause and Apache-2.0 are all compatible with
  AGPL-3.0-or-later.
- S1 runs `govulncheck` over the new graph and adds a notice for each row.
  It also adds a `check_notice` for `github.com/go-webauthn/webauthn` to
  `scripts/license-check.sh`. S3 does the same for `passkeys` and
  `androidx.credentials`. The Dart packages must also pass
  `check-dart-licenses` and the retraction scan in
  `check-mobile-dependencies.sh` (hashed lock entries).
- **Rejected:**
  - writing our own verifier: CBOR and COSE parsing is security-critical,
    and the owner approved a library;
  - `duo-labs/webauthn`: archived, and replaced by this library.

### Flutter: `passkeys` 2.24.1 (Corbado, BSD-3-Clause)

**Federated packages, pinned exactly:**

| Package | Version |
|---|---|
| `passkeys_platform_interface` | 2.11.0 |
| `passkeys_android` | 2.15.0 |
| `passkeys_darwin` | 0.4.8 |
| `passkeys_windows` | 0.1.6 |
| `passkeys_web` | 2.11.0 |
| `passkeys_doctor` | 1.7.0 |

All are BSD-3-Clause and published by `corbado.com`. The `passkeys` package
is the most used Flutter passkey plugin (about 237k downloads in 30 days),
and it is the only one that covers Android, iOS, macOS and Windows.

**Also pulled in:**

- `device_info_plus` and `package_info_plus` (BSD-3-Clause, Flutter
  Community). Both come from `passkeys_doctor`, and both are native plugins
  on every platform, Linux and Windows included.
- `web` and `convert` (BSD-3-Clause, dart.dev).
- `json_annotation` (BSD-3-Clause). `http` and `meta` are already locked.
- On Android: `androidx.credentials:credentials` and
  `credentials-play-services-auth` 1.6.0 (Apache-2.0). The app already
  depends on Firebase, so Play services are not a new class of dependency.
  An F-Droid flavour later would have to leave them out.
- On Windows: the OS `webauthn.dll`. On Apple platforms:
  `AuthenticationServices`.

**Requirements and rules:**

- The plugin needs Flutter 3.41 or later and Dart 3.11 or later. The
  current pin is Flutter 3.44 with Dart 3.12, so it fits. S3's first action
  is to resolve the lock in CI, because D88 is a precedent for a plugin
  that did not resolve under the pinned Flutter.
- `passkeys_darwin` keeps the iOS 13 and macOS 10.15 targets and checks
  for iOS 16 and macOS 13.5 at run time, so no deployment-target bump is
  needed.
- **Never set `debugMode: true`.** The doctor then fetches the server's
  `.well-known` files. It reaches only the user's own server and never a
  Corbado host (checked in `passkeys_doctor` 1.7.0 source), but the app
  needs none of it.
- The plugin sits behind a `PasskeyClient` interface. Tests use a fake,
  matching the rule that platform services stay behind interfaces.

**Rejected:**

- `credential_manager` (MIT): no Windows support, and far less use.
- `flutter_passkey`: last published 2024, Android and iOS only.
- `webauthn` (Dart): a software authenticator, not the platform's.

## Account switcher

### Model

- **Slots.** A slot is one account on one server, with its own
  `SecureLocalStore` namespace:
  - The existing install is the **primary slot**, the empty namespace in
    release builds and `demo` or `demo-<profile>` in demo builds. Nothing
    moves.
  - Further slots get `a-<12 random base32 lowercase>` in release builds
    and `<primary>-a-<12>` in demo builds. Both fit the
    `^[a-z0-9-]{0,40}$` rule.
  - A namespace never contains a username or a hostname, so file and key
    names reveal nothing.
- **Registry.** A secure-storage entry `veritra.accounts.v1` (in demo
  builds, `veritra.<primary>.accounts.v1`) holds:
  - `{version, active, slots:[{slot, state, origin, account_id, username,
    added_at}]}`;
  - `state` is one of `pending`, `active` or `removing`.

  Each write is read back and compared, as the database key already is.
- **At most 5 slots** (O8).
- **One account per slot.** The same `(origin, account_id)` cannot occupy
  two slots.

### What is per slot and what is shared

Found by searching for every `'veritra.` secure-storage key, every
`getTemporaryDirectory`, `getApplicationSupportDirectory` and
`getApplicationDocumentsDirectory` call, and the native push and wake
state.

| Item | Today | B7 |
|---|---|---|
| Database, WAL and SHM (`<support>/<ns>/veritra-local.db*`) | Per namespace | Per slot, no change |
| Database key `veritra[.<ns>].database_key.v1` and quarantined copies | Per namespace | Per slot, no change |
| Legacy record `veritra[.<ns>].account_state.v2` | Per namespace | Per slot, no change |
| Everything inside the database: session, device secret, MLS state, cursor, drafts, settings, search index, pending enrollment (K0 claim), notice outbox | Per namespace | Per slot, no change |
| Read receipts `veritra.read_receipts.v1` (`receipts_state.dart`) | **Global** | Per slot. The primary keeps the old name; others use `veritra.<ns>.read_receipts.v1` |
| Hide previews `veritra.notifications.hide_preview.v1` (`message_notifications.dart`) | **Global** | Per slot, same naming. A new slot copies the primary's value |
| Attachment working files (`attachment_crypto.dart`, support root) | **Shared root** | `<support>/<ns>/` |
| Backup and recovery files: `.veritra-recovery.partial` and `.*.backup-ciphertext` (`backup_service.dart`, support root) | **Shared root, fixed name** | `<support>/<ns>/`. Otherwise one slot's partial recovery file could be picked up by another slot |
| Opened files `<tmp>/veritra-open` (`attachment_views.dart`) | **Shared**, purged at start | `<tmp>/veritra-open/<ns or "primary">`, purged at start and at every switch |
| Pasted images (`composer_attachments.dart`) | Per profile (`usePastedImageProfile`) | Per slot |
| Account export file (Documents, `veritra-account-export-v2-<stamp>.json`) | User-visible file | Shared folder. It is the user's own file |
| Appearance `veritra.appearance.v1` | Global | Shared: it is a device look, not account data |
| Push: native `PushRegistrationConfig` (one instance at a time), FCM token and APNs token (one per app), UnifiedPush endpoint (per instance `accountId:deviceId`) | One | The active slot only (below) |
| D52 wake bridge profile and native permit (`wake_worker_bridge.dart` refuses a second profile) | One per process | The active slot. Rebinding happens after an uninstall (S5) |
| Desktop tray, window, notifier and its pending notices | Bound to one `AppState` | Re-attached to the new runtime at each switch. The old slot's notices are cleared |
| Native crypto (Rust `loaders()` map keyed by handle) | Per handle | The old handles are closed at teardown |

### Runtime: one live account per process

The D52 contract ("one store and one AppState per process",
`main_demo.dart`) still holds, in this form: **at most one live
`SecureLocalStore` and `AppState` exist at any time.** A switch tears the
old runtime down completely before it builds the next one. The steps run
in one serialized queue, the same queue as session transitions:

1. Show a blocking "Switching…" overlay.
2. Flush the debounced draft (D65's sign-out path).
3. Cancel any wake worker and `bridge.uninstall(old profile)`.
4. Stop sync, sockets and timers, and advance the session generation. The
   I30 fences (`session_switch_test.dart`) then drop any late result.
5. **Push handoff:**
   - Delete the old slot's push subscription on its server, and call
     native `unregister`.
   - On failure, retry twice. Then ask: "Switch anyway? You may get
     notifications for <account> until you open it again."
6. Close the store, dispose the `AppState`, and detach the desktop
   services.
7. Purge that slot's opened files and pasted images.
8. Build the new store, `AppState` and services, and mount the UI under a
   key unique to the slot, so no widget state crosses over.
9. Register push and install the wake permit for the new slot. Then write
   `active` in the registry.

If step 8 fails, the previous slot is reopened and an error is shown. A
crash at any point leaves `active` naming the old slot, which opens
normally at the next start.

**Bridge change (S5).** Today `install` refuses a different profile for
the life of the process. It must accept one once `uninstall` has finished.
The native side then binds the permit to the new profile, and a wake that
names any other profile is refused. Both get tests. Background wakes stay
off, as D52 says (`can_opt_in: false`).

### Add and remove

**Add account** (from the switcher):

- Write a `pending` slot, open its runtime and run the normal connect
  flow: registration by invite, device link, or K0 "lost all my devices".
- Once a session is saved, set the slot `active` with its origin, account
  ID and username, then switch to it.
- A duplicate `(origin, account_id)` found at that point is refused. The
  slot signs out and is wiped. The device that the server just created
  stays in the account's device list, and the user is told to remove it.
- **Cleanup at start:** a `pending` slot is wiped only when its store
  holds neither a session nor a pending enrollment. A K0 claim can wait 7
  days in that state (D78), so it must survive restarts.

**Remove from this device:**

1. Set the slot to `removing`.
2. Sign out on the server (best effort) and delete its push subscription.
3. Delete its files, its database key, its quarantined copies and its
   `unreadable-*` folders. This is a delete, not the quarantine reset.
4. Remove the registry entry.

The app resumes a `removing` slot at the next start. The primary slot can
be removed too. The registry then names another slot as primary, and the
empty namespace is left empty.

### Inactive accounts (default, O7)

- **Paused.** No sync, no push registration and no notices.
- The switcher shows each account's host and username, but no unread
  counts. Those would need background sync.
- **Shown at the next activation:** K0 notices, D79 warnings and pending
  recovery claims of an inactive slot. Its K0 claim timer runs on the
  server regardless.
- A later package can make every account live. That changes the D52 wake
  contract and needs its own design.

### Passkeys with several accounts

Sign-in options carry `allowCredentials` for the slot's account, so the OS
offers only that account's passkeys, even when two slots use the same
server. Passkeys of another account on the same server are refused anyway:
the credential must belong to the device's account.

## Threats

| Threat | Outcome |
|---|---|
| Phishing site or look-alike host relaying to the server | On Android and Apple platforms the OS binds the passkey to the RP ID, so the relay gets nothing. On Windows the app's RP ID pin refuses any `rp.id` other than its server's host. The password path is unchanged |
| A hostile server asks the app for another server's assertion | The app's RP ID pin refuses. Android and Apple platforms also refuse an RP ID with no association to the app |
| Thief with the phone who knows its PIN (UV is often the unlock PIN) | Can sign in after a session expiry, which reads new messages, as an unexpired session already can. **Cannot** add or remove passkeys, change the password, cancel a recovery, remove or link devices, create invites, export or delete the account: all need the password. The owner removes the device from another one, or recovers. Residual: password-only sign-in blocked this thief after expiry |
| Stolen session token, no password | Cannot add a passkey to keep access after the session ends, because registration needs recent password authentication |
| Replay or reuse of an assertion | The challenge is single-use, deleted in the session transaction, and bound to the device ID. It lives 3 minutes |
| Credential or user swap | The credential must belong to the ceremony's account and `userHandle` must match. Credential IDs are unique per instance |
| Cloned authenticator | Refused on a non-increasing nonzero sign count. Synced passkeys (count 0) get no clone detection; accepted |
| Account enumeration | Sign-in options need a valid device secret and take no username. Failures look the same |
| Ceremony flooding | Device secret required, 4 open ceremonies per device, the 10/min credential budget, and pruning |
| Server operator or a database leak | Gets public keys, sign counts, backup flags, names and times. No secret: a passkey cannot be replayed from the database. The operator could always mint sessions; this adds nothing |
| Hostname changed later | Every passkey stops working, together with K0 proofs and device identity. Users fall back to the password. Operations states it at the hostname step |
| Third parties learn the hostname | Android's verification goes through Google's Digital Asset Links service, and Apple's CDN fetches the AASA file, so Google or Apple learns the instance hostname. The user's credential manager stores the hostname and username. Google Password Manager and iCloud Keychain encrypt them end to end, but third-party managers vary. Hence off by default, an operator opt-in, then per-user opt-in (O6) |
| Logs | No body, credential ID, public key, challenge or ceremony ID is logged. Audit rows carry the row ID |
| Data from one account showing in another | One live runtime per process, a full teardown, UI keyed per slot, the I30 generation fences, and the per-slot directories and keys in the table above |
| Notices for an inactive account | Push is deregistered at switch. If that fails and the user switches anyway, the old server keeps waking the phone. On iOS that wake is D53's visible generic "New message". Residual, stated in the dialog |
| One server links two accounts on one phone | FCM and APNs give one token per app, so two accounts on one server register the same token and the server can link them. IP and timing link them anyway. UnifiedPush endpoints differ per instance, but they share one distributor. The add-account screen says "This server can tell that these accounts are on the same device" when the host matches an existing slot (O10) |
| Someone holding the unlocked phone | Sees the account list (hosts and usernames). Today they see the one signed-in account already |
| A removed account leaves data | The journaled `removing` state is finished at the next start. Quarantine folders of that slot are deleted too |

## Build steps

| Step | What | Counter | Done when | Route |
|---|---|---|---|---|
| S0 | This design | none | Merged after review | Opus designs |
| S1 | Server passkeys: the Go module, config and startup checks, well-known files, migration, routes, the writer-transaction fence, backoff sharing, audit and sync events, export, `THIRD_PARTY_NOTICES.md`, `operations.md` (settings, hostname permanence, T37C wording) | **one server migration**, number reserved by the coordinator | Go tests with a test authenticator written in the test code (ECDSA P-256 and Ed25519 keys, CBOR from the module already pulled in, attestation `none`). The tests cover: register, sign in, wrong device secret, revoked device, suspended account, wrong `userHandle`, another account's credential, replayed and expired ceremony, two concurrent finishes (exactly one session), a passkey deleted mid-ceremony, BE change refused, sign-count regression refused, no `recent_auth_at` after a passkey sign-in, `withRecentAuth` refused with a passkey session, registration refused without recent auth, the shared backoff, and startup refusing a port, an IP or `http`. `go test -race`, `go vet`, `govulncheck` and `scripts/test` pass | Sonnet builds; independent review before merge |
| S2 | K0 completion deletes passkeys (only if O5 is yes) | none (same tables) | A completion test shows no passkey left and a ceremony fenced | Inside S1 or after it; reviewed with K0 |
| S3 | App passkeys: plugin pins (resolve in CI first), the `PasskeyClient` interface, API client, RP ID pin, "Sign in with passkey" next to the password on the sign-in screen (same post-sign-in path as `login`), Settings, Passkeys (list, add after password reauth, rename, remove), notices for `account.passkey_added` and `account.passkey_removed`, English and Serbian strings, the empty iOS `webcredentials` build setting and `VERITRA_PASSKEY_DOMAINS` | none | Flutter tests with a fake `PasskeyClient` cover: the RP ID pin refuses a mismatch, a cancel is silent, the button is hidden on Linux and on an iOS host not in the list, and passkey sign-in keeps the cursor rules of `login`. An API contract fixture holds JSON shapes the Go tests produce. CI green on every desktop and phone job | Sonnet builds; independent review before merge |
| S4 | Slot storage: registry with read-back, per-slot names for the global items in the table above, primary unchanged | none | Tests: the primary keeps its keys and paths byte for byte; two slots share no file or key; a crash in each registry state recovers; a pending slot with a K0 claim survives a restart | Sonnet; Opus review (storage) |
| S5 | Runtime switch: teardown queue, bridge rebind (Dart and native), push handoff with retry, desktop re-attach | none | `session_switch_test.dart` grows: a page, a draft, a sync result or a notice from slot A never reaches slot B; after a switch no timer, socket or store of A is alive; the bridge refuses a stale profile's wake; deregistration failure shows the dialog | Opus review (MLS ordering and lifecycle) |
| S6 | Switcher UI: list, add, remove, the same-server warning, the 5-slot cap; English and Serbian strings | none | Widget tests; the demo e2e signs into a second account in one process and switches back | Sonnet |
| S7 | Evidence: `testing/evidence/B7-passkeys.md` | none | Server tests and CI linked. One hand run on Windows Hello (the owner, with W1). Android and iOS runs need signed builds and wait for G24-era devices; they are listed as open, not claimed | Owner run |

Order: S1 → S3 for passkeys and S4 → S5 → S6 for the switcher. The two
tracks are independent. S2 waits for O5.

## Owner questions (defaults in bold)

- **O1. iOS and macOS hostnames.** The App Store build can list only fixed
  hostnames.
  - **Only the owner's permanent hostname in the official build; other
    servers get password-only on Apple platforms.**
  - Alternatives: self-hosters build their own app, or no passkeys on
    Apple platforms.
- **O2. Linux.** **Password-only.** Security keys through libfido2 would
  be a further new dependency.
- **O3. Does a passkey count as recent authentication?** **No, for every
  sensitive action.** A phone's UV is often its unlock PIN.
- **O4. A passkey instead of the password in a K0 claim?** **No; D49
  stands.**
- **O5. Does K0 recovery completion delete passkeys?** **Yes**, in the
  completion transaction. The alternative is to keep synced passkeys
  working.
- **O6. Disclosure.** Passkeys tell Google (Android) or Apple the
  hostname. **Off by default; the operator turns it on, and each user opts
  in by adding a passkey.**
- **O7. Inactive accounts.** **Paused: no sync and no notices.** A later
  package could make them live.
- **O8. Account cap.** **5.**
- **O9. Accounts without a password.** **No.** The password stays a K0
  factor.
- **O10. Two accounts on the same server on one phone.** **Allowed, with a
  plain warning that the server can link them.** The alternative is to
  refuse.
