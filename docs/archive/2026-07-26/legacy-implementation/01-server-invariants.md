# Plan 01 — Repair server invariants

Run these cards after Plan 00. S01 and S02 are immediate data/privacy defects.
S03 and S04 must land before production crypto or public deployment.

## S01 — Fix conversation key-package claims

Audit references: LOG-01, TEST-03.

Objective:
Make key-package claims use the authoritative memberships schema and prove the
claim remains atomic.

Read first:

- server/internal/storage/key_package_store.go
- server/migrations/0001_init.sql
- server/internal/storage/sqlite_test.go
- server/internal/httpapi/key_package_handlers.go
- server/internal/httpapi/api_test.go
- docs/crypto-protocol.md key-package rules

Steps:

1. Add a migration-backed store test that currently fails with the nonexistent
   table error.
2. Cover requester membership, one package per other active device, exclusion
   of the requesting device, revoked devices, missing-package rollback, and a
   second claim.
3. Replace conversation_members with memberships in both queries.
4. Add a narrow HTTP test for success, nonmember denial, and unavailable
   package status mapping.
5. Use opaque synthetic bytes only.

Acceptance:

- No current query references conversation_members.
- A failure for any target consumes no package.
- Concurrent/duplicate claims cannot reuse one package.
- Store and HTTP tests pass under the race-enabled server suite.

Verify:

- cd server && go test ./internal/storage ./internal/httpapi
- cd server && go test -race ./...

## S02 — Enforce the exactly-two-account DM invariant

Audit references: LOG-06, UI-05.

Objective:
Prevent an existing DM from gaining a third account or being silently treated
as a group.

Read first:

- server/internal/storage/community_store.go
- server/internal/httpapi/conversation_handlers.go
- server/internal/storage/sqlite_test.go
- server/internal/httpapi/api_test.go
- docs/crypto-protocol.md conversation lifecycle

Steps:

1. Add regression tests that create a valid DM and attempt to add a third
   account through the store and HTTP route.
2. Inside the same transaction as membership management, read conversation
   kind and current membership.
3. Reject new membership and role mutation for DMs unless an explicitly
   documented existing-member operation is required.
4. Keep group and community-channel rank checks unchanged.
5. Add a read-only diagnostic or documented migration query for any existing
   DM with a membership count other than two; do not silently delete rows.

Acceptance:

- DM creation still requires exactly two accounts.
- Every later path preserves exactly two DM memberships.
- Rejection returns a stable client-visible error.
- Group membership management still passes.

## S03 — Enforce versioned message protocol markers

Audit reference: SEC-04.

Depends on: protocol identifier in docs/crypto-protocol.md.

Objective:
Prevent production storage from accepting placeholder or unknown message
protocol markers.

Read first:

- server/internal/httpapi/conversation_handlers.go
- server/internal/storage/message_store.go
- server/internal/httpapi/api_test.go
- server/internal/storage/sqlite_test.go
- docs/crypto-protocol.md

Steps:

1. Centralize the initial supported protocol identifier:
   mls10-openmls-v1.
2. Apply the same policy to create, edit, and delete marker endpoints.
3. Add negative tests for empty, placeholder, and unknown identifiers.
4. Replace obsolete test markers with the reviewed identifier while retaining
   opaque synthetic ciphertext.
5. Document how a future protocol version is added without reinterpretation or
   plaintext fallback.

Acceptance:

- Production paths reject mls-openmls-todo and arbitrary strings.
- All message mutations use one policy.
- Calls retain their stricter exact encrypted metadata schema.
- No server decryption or ciphertext inspection is added.

## S04 — Fail owner bootstrap closed in production

Audit references: SEC-03, SEC-07, DEP-02.

Objective:
Prevent a host-local reverse proxy from turning tokenless remote setup into
loopback-authorized owner creation.

Read first:

- server/internal/httpapi/auth_handlers.go
- server/internal/config/config.go
- server/internal/app/app.go
- server/cmd/messenger-server/main.go
- docs/deployment.md
- deploy/docker-compose.yml
- deploy/systemd/private-messenger.service

Steps:

1. Add a test matrix for development/production, setup complete/incomplete,
   token present/absent, direct loopback, host-local proxy, and bridge proxy.
2. Choose a fail-closed rule: an incomplete production instance must not serve
   owner setup without a high-entropy configured token.
3. Enforce the rule after migrations and setup-status discovery so an already
   initialized production instance may remove the one-time token.
4. Keep direct tokenless loopback setup only for explicit development/local
   mode.
5. Never authorize setup using forwarded headers.
6. Coordinate deployment example changes with D01.

Acceptance:

- A remote request through a loopback proxy cannot create the owner without
  the token.
- An incomplete production instance fails with an actionable startup error
  when no safe bootstrap mechanism exists.
- Token comparison remains constant-time.
- The token is never logged or placed in a URL/command argument.

## S05 — Tighten authentication and enrollment throttles

Audit references: LOG-13, SEC-06, MERGE-03, MERGE-08.

Objective:
Apply suitable limits to every unauthenticated enrollment path and add
privacy-safe account-oriented login backoff.

Read first:

- server/internal/app/app.go limiter and client-IP resolution
- server/internal/httpapi/auth_handlers.go
- server/internal/storage enrollment and login methods
- existing limiter tests

Steps:

1. First add setup/owner/enrollment, register/enrollment, and
   device-links/claim-enrollment to explicit strict route classes.
2. Return Retry-After on 429 responses.
3. Add bounded outstanding-reservation caps tied to the safe parent object
   where possible.
4. Design per-normalized-username failure backoff using a keyed hash and short
   expiry; do not persist raw IPs or create analytics.
5. Preserve dummy password verification for missing accounts.
6. Test trusted-proxy and CGNAT behavior before enabling aggressive limits.

Acceptance:

- Every unauthenticated auth/enrollment write is intentionally classified.
- Limits are bounded in memory and expire.
- Logs and metrics contain no username, invite/link code, raw IP, or secret.
- Legitimate device-secret login and device-link flows remain usable.

## S06 — Make local blob commits durable and detectable

Audit references: MERGE-02, LOG-14.

Objective:
Prevent a committed blob row from pointing at an unsynced or obviously
truncated local file.

Read first:

- server/internal/uploads/local.go
- server/internal/uploads/storage.go
- server/internal/httpapi/content_handlers.go
- server/internal/storage/content_store.go
- server backup/doctor implementation and tests

Steps:

1. Add file.Sync before close and rename in PutEncryptedBlob.
2. Preserve temp-file cleanup on every failure path.
3. Add a narrow storage interface for size validation if needed; avoid leaking
   LocalStore details into domain logic.
4. Reject or clearly fail an authorized download when the on-disk size differs
   from committed metadata.
5. Keep full checksum verification in doctor/background scrub or restore paths
   unless measurement proves per-download hashing acceptable.
6. Add tests for interrupted writes, short files, missing files, and context
   cancellation.

Acceptance:

- Successful writes are synced before rename.
- Obvious corruption yields a clean server error rather than a misleading
  decryption failure.
- Authorization still occurs before file access.
- No ciphertext bytes or storage keys are logged.

## S07 — Add durable blob deletion reconciliation

Audit reference: LOG-14.

Depends on: S06.

Objective:
Retry post-commit file deletions without risking removal of a referenced blob.

Steps:

1. Define a small SQLite deletion-work table or an equally durable idempotent
   mechanism.
2. Enqueue file deletion in the same transaction that removes the owning row.
3. Process work in bounded batches and delete the work row only after success.
4. Add doctor/reconcile reporting that compares keys without logging them.
5. Coordinate with backup/restore and account deletion.

Acceptance:

- A process crash between DB commit and file deletion leaves retryable work.
- Reprocessing is idempotent.
- A committed attachment or backup row can never have its file deleted by the
  reconciler.
- Failure tests pass.
