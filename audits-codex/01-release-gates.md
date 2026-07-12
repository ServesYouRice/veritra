# Release gates

Every item here should be closed or explicitly removed from the shipped product before production.

## R-01 — First remote request can seize a new instance (Critical)

- **Evidence:** `server/internal/httpapi/api.go:36` exposes owner creation without authentication. `api.go:102-106` accepts the public constant header `X-Private-Messenger-Setup: 1` as its only gate. The default bind is all interfaces (`server/internal/config/config.go:27`).
- **Impact:** anyone who reaches a fresh instance can race the operator, choose the sole owner credentials, and permanently control it.
- **Fix:** require a high-entropy one-time setup secret delivered out-of-band, or perform setup through a local CLI/loopback socket. Rotate and erase the secret after an atomic setup transaction.

## R-02 — Production end-to-end encryption does not exist (Critical)

- **Evidence:** `mobile/lib/main.dart:13-18` wires `UnavailableCryptoService`; `mobile/lib/crypto/crypto_service.dart:3-19` has only key-package/encrypt methods and throws; there is no decrypt operation. `crypto/rust/src/lib.rs:3-10` reports the Rust layer unavailable.
- **Impact:** the default app cannot register a usable device, send, receive, decrypt, verify, recover, or rotate production keys. The repository is a UI/server shell, not a functioning private messenger.
- **Fix:** specify the protocol and threat invariants first; then implement audited key storage, key-package publication/fetch, group/session lifecycle, encrypt/decrypt, device verification, rotation, revocation, backup/recovery, and interop vectors. Keep the server ciphertext-only.

## R-03 — Android and iOS applications are absent (Critical)

- **Evidence:** `mobile/` contains `lib`, `test`, and metadata, but no `android/` or `ios/` project. `mobile/README.md:13-16` tells developers to generate them later.
- **Impact:** there is no installable mobile product, signing setup, manifest/entitlement review, secure-storage platform configuration, notification configuration, or release build.
- **Fix:** generate and commit reviewed platform projects; pin minimum OS/SDK versions; configure signing, Keychain/Keystore, network security, backup exclusions, notifications, and release flavors; build both platforms in CI.

## R-04 — The committed mobile dependency graph cannot run in CI (Critical)

- **Evidence:** `.github/workflows/ci.yml:46-50` pins Flutter `3.24.5`. The committed `mobile/pubspec.lock` requires Dart `>=3.10.3` and Flutter `>=3.38.4` (`git show HEAD:mobile/pubspec.lock`). Current code uses `RadioGroup` (`conversation_details_screen.dart:98`), which Flutter documents as stable only in 3.35 in its [Radio API migration guide](https://docs.flutter.dev/release/breaking-changes/radio-api-redesign). The worktree's uncommitted lock downgrade does not prove source compatibility.
- **Impact:** the mobile CI job is non-reproducible and is expected to fail before meaningful tests. A lockfile regeneration can silently change the graph because CI uses plain `flutter pub get`.
- **Fix:** choose one supported Flutter release, align `pubspec.yaml`, lockfile, source APIs, developer containers, and CI; use lockfile enforcement; add Android and iOS compile/package jobs.

## R-05 — Channel creation always violates the server schema (High)

- **Evidence:** `mobile/lib/core/api_client.dart:151-163` defaults channel `kind` to `text`. The database permits only `private` or `announcement` (`server/migrations/0001_init.sql:57-62`). The handler passes the value through without validating it (`server/internal/httpapi/api.go:475-489`).
- **Impact:** the normal mobile “create channel” flow reaches a SQLite CHECK violation and returns a 500. Tests copy the same fake-client default, so they miss the contract break.
- **Fix:** define shared wire-contract constants/schema, validate at the HTTP boundary with a 400, change the client default, and add a real client-to-handler contract test.

## R-06 — Setup and registration can commit without returning a session (Critical)

- **Evidence:** owner/account and device creation commit first; token generation and `CreateSession` happen afterward (`server/internal/httpapi/api.go:128-154` and `228-254`). Invite consumption is committed inside `RegisterWithInvite` before the session is created (`server/internal/storage/sqlite.go:337-376`).
- **Impact:** token/session failure can consume an invite or create the only owner/device while the client receives only a 500. Initial setup can become irrecoverably “already setup.”
- **Fix:** generate the token first and create account, device, invite use, and hashed session in one storage transaction. Return only after commit; add injected-failure tests at each step.

## R-07 — The only owner can delete themselves and orphan the instance (Critical)

- **Evidence:** accounts are created only as owner during setup or member during invite registration (`server/internal/storage/sqlite.go:312,360`); there is no ownership transfer/promotion route. `DeleteAccount` has no last-owner guard (`sqlite.go:1586-1610`). `SetupRequired` counts deleted accounts too (`sqlite.go:260-265`).
- **Impact:** deleting the sole owner leaves an instance with no administrator and no supported reinitialization or recovery path.
- **Fix:** require ownership transfer or another active owner, prohibit deleting the last owner, revoke outstanding owner-created credentials, and provide an offline recovery command with an audit trail.

## R-08 — A global admin can silently enter any private conversation (Critical)

- **Evidence:** `effectiveConversationRole` returns the instance role even when `ConversationMemberRole` says the caller is not a member (`server/internal/httpapi/api.go:1186-1194`). The member-add route uses that effective role (`api.go:573-592`).
- **Impact:** an owner/admin who learns a conversation ID can add themselves without participant consent or an in-conversation event. This violates the repository rule that admin features must not create silent private-content access.
- **Fix:** require actual conversation membership for membership management. Keep instance administration metadata-only; make any exceptional recovery action explicit, participant-visible, and protocol-enforced by clients.

## R-09 — A message can be acknowledged without a durable sync event (High)

- **Evidence:** message insertion commits before `saveSyncEvent` (`server/internal/httpapi/api.go:717-742`). `saveSyncEvent` logs and returns zero on failure rather than failing the request (`api.go:848-853`).
- **Impact:** the sender can receive success while recipients never discover the envelope. This is especially severe because the client treats WebSocket payloads as catch-up triggers rather than authoritative state.
- **Fix:** persist envelope and event in one transaction before acknowledging. Publish only after commit; use a durable outbox for realtime delivery.

## R-10 — Membership changes are not delivered through sync (High)

- **Evidence:** member addition records only an audit event (`server/internal/httpapi/api.go:587-592`); conversation creation does not create account-scoped events for invited members. `docs/sync.md:14-15` promises `membership.updated`/`invite.updated`, but no corresponding `saveSyncEvent` call exists.
- **Impact:** a user can be added to a conversation and never learn about it until an unrelated manual/full refresh. Offline devices can miss membership state permanently.
- **Fix:** define a versioned event matrix for every state mutation, persist account-scoped membership events transactionally, and test offline add/remove/role-change flows.

## R-11 — Restore deletes the live database before validating the backup (High)

- **Evidence:** `server/cmd/messenger-server/main.go:194-220` checks only file existence, uses an unreliable WAL-open probe, deletes the live DB/WAL/SHM, then copies. There is no SQLite integrity/schema check, durable fsync, rollback, or process lock.
- **Impact:** a corrupt/wrong backup or copy failure can destroy the recoverable live database. On Unix, opening the WAL does not prove the server is stopped.
- **Fix:** restore to a separate file, run integrity/schema/migration checks, fsync it, acquire an explicit exclusive lock, atomically swap with rollback, and test power/failure points.

## R-12 — Documented database and blob paths are silently ignored (High)

- **Evidence:** config loads `PRIVATE_MESSENGER_DB_PATH` and `PRIVATE_MESSENGER_STORAGE_PATH` (`server/internal/config/config.go:33-34`), but the CLI overwrites both from `DataDir` whenever `--db`/`--storage` are absent (`server/cmd/messenger-server/main.go:52-60`).
- **Impact:** a deployment can start against an unexpected empty database or write blobs to the wrong disk despite valid documented environment settings.
- **Fix:** track whether a CLI flag was explicitly supplied and preserve environment-derived paths otherwise. Add precedence tests for defaults, environment, and flags.

## R-13 — The default non-root container may not be able to initialize `/data` (High)

- **Evidence:** `server/Dockerfile:9-15` runs a distroless `:nonroot` image and declares `/data` as a volume, but never creates/chowns it for that UID. Compose mounts a new named volume there (`deploy/docker-compose.yml:10-11`).
- **Impact:** on a normal root-owned empty volume, startup can fail when creating the SQLite database or blob directory. Runtime confirmation was blocked by the unavailable Docker daemon.
- **Fix:** create `/data` in a build stage with the exact runtime UID/GID and copy/chown it into the final image, or use a documented init step. Add a fresh-volume Compose smoke test. Docker's [Dockerfile reference](https://docs.docker.com/reference/dockerfile/) documents volume initialization and `COPY --chown` behavior.

## R-14 — “Delete account” makes a false irreversible-deletion promise (High)

- **Evidence:** the UI says all account data, devices, and memberships are permanently removed (`mobile/lib/features/settings/settings_screen.dart:163-170,215-225`). The server deletes sessions, revokes devices, and soft-marks the account (`server/internal/storage/sqlite.go:1586-1610`); memberships, identifiers, messages, attachments, backups, push endpoints, and other rows remain. `docs/privacy.md:25` acknowledges this.
- **Impact:** users are induced to make a high-trust privacy decision under a materially false description.
- **Fix:** immediately change UI wording to the exact current behavior, then define and implement a deletion/scrubbing policy with ownership transfer, relational/blob cleanup, retention exceptions, and verification tests.
