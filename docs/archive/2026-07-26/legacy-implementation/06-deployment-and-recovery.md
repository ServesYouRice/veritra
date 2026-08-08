# Plan 06 — Deployment, backup, and release operations

Production work starts only after the server invariants are green. Secret
material must come from the operator environment, never from committed example
values.

## D01 — Make production configuration explicit

Audit references: DEPLOY-01, DEPLOY-02, SEC-04.

Depends on: S04.

Objective:
Make the supported Compose and systemd paths enter production mode and require
safe bootstrap configuration.

Steps:

1. Inventory every required production environment variable from config code.
2. Update Compose and systemd examples to set production mode explicitly.
3. Load setup and signing secrets through an operator secret file, systemd
   credential, or equivalent; do not commit a usable default.
4. Document first-run token creation, removal after setup, rotation, and
   failure recovery.
5. Add config/startup tests for missing, weak, and already-consumed setup
   credentials.

Acceptance:

- Both documented deployment paths fail closed when production prerequisites
  are absent.
- No example contains a production-usable shared secret.
- Loopback proxying cannot silently bypass the bootstrap token.

## D02 — Enforce one writer per data directory

Audit reference: DEPLOY-03.

Objective:
Prevent two server processes from concurrently opening the same SQLite and
blob state.

Steps:

1. Acquire a process-lifetime exclusive lock inside the resolved data root.
2. Return a clear privacy-safe startup error when the lock is held.
3. Release the lock on normal shutdown and process termination.
4. Keep restore/recovery maintenance locks compatible with this rule.
5. Test competing processes and restart after an unclean exit.

Acceptance:

- A second writer cannot start on the same data root.
- Separate data roots still start independently.
- No lock path can escape the configured data root.

## D03 — Operationalize encrypted backups and restore drills

Audit references: DEPLOY-04, TEST-05, NICE-09.

Depends on: C11.

Objective:
Turn the existing manual backup capability into a monitored, restorable
operator workflow.

Steps:

1. Define a supported scheduled backup command with retention and overlap
   protection.
2. Copy encrypted artifacts to an operator-selected off-host destination.
3. Emit privacy-safe success, age, and failure signals without ciphertext or
   secret contents.
4. Add an isolated restore-drill script that never overwrites the live root.
5. Document key custody, recovery verification, alert thresholds, and drill
   cadence.

Acceptance:

- Operators can detect a stale or failed backup.
- A documented drill restores into a new root and passes integrity checks.
- No server-side recovery mechanism can decrypt user content.

## D04 — Support large encrypted downloads safely

Audit references: DEPLOY-05, PERF-08.

Depends on: S06.

Objective:
Avoid default request timeout failures and full restarts for large authorized
ciphertext downloads.

Steps:

1. Apply route-family timeouts to attachment and backup item endpoints.
2. Add standards-compliant Range support after authorization and metadata
   validation.
3. Bound ranges, open files safely, and preserve constant privacy-safe errors.
4. Test valid, invalid, multipart-rejected, interrupted, and unauthorized
   requests.
5. Document client resume behavior and supported maximum object size.

Acceptance:

- Authorized downloads can resume without retransmitting the whole object.
- Unauthorized callers cannot infer object existence or size.
- Slow-client handling remains bounded.

## D05 — Add privacy-safe operational health signals

Audit references: DEPLOY-07, PERF-09.

Objective:
Expose enough aggregate state to operate an instance without telemetry or
content leakage.

Steps:

1. Define an allowlist of local metrics: request class/latency, status class,
   queue depth, database busy time, hub connections, backup age, and resource
   totals.
2. Exclude account IDs, conversation IDs, network addresses, tokens,
   ciphertext, filenames, and message text.
3. Protect the endpoint as an operator-only surface or local listener.
4. Document retention, scraping, and example alerts.
5. Add tests that reject forbidden labels and log fields.

Acceptance:

- An operator can identify saturation and stale backups.
- Metrics are local/operator controlled and contain no user identifiers.
- No third-party analytics or telemetry service is introduced.

## D06 — Drain realtime work on shutdown

Audit reference: DEPLOY-06.

Objective:
Make termination predictable during upgrades and orchestration.

Steps:

1. Stop accepting new HTTP and WebSocket work.
2. Signal connected clients to reconnect and close within a fixed grace
   period.
3. Stop background producers, flush safe durable state, then close storage.
4. Keep the grace period below the documented service stop timeout.
5. Test active HTTP, WebSocket, upload, and background jobs during shutdown.

Acceptance:

- Shutdown completes inside its bound without corrupting durable state.
- Clients recover through normal reconnect/sync behavior.

## D07 — Align build toolchains

Audit reference: DEPLOY-08.

Objective:
Use one documented Go version and reproducible mobile/Rust toolchain policy.

Steps:

1. Compare go.mod, Dockerfiles, CI, and contributor documentation.
2. Select one supported Go patch/minor policy and update every location.
3. Pin Rust and Flutter inputs used for release builds where practical.
4. Add a CI check that detects future version drift.

Acceptance:

- Local, container, CI, and release documentation agree.
- A drift check fails with an actionable message.

## D08 — Write upgrade, rollback, and incident runbooks

Audit references: DEPLOY-09, NICE-12.

Depends on: D02, D03, D06.

Objective:
Give operators a safe procedure for schema upgrades and privacy incidents.

Steps:

1. Document preflight, backup, version compatibility, downtime, and health
   checks.
2. State which migrations are irreversible and how rollback uses a restored
   copy rather than partial schema reversal.
3. Cover lost setup credentials, compromised signing keys, corrupt blobs,
   suspected metadata leakage, and failed restores.
4. Include explicit stop conditions and evidence to preserve without message
   contents.

Acceptance:

- Each supported release path has a tested recovery decision tree.
- Runbooks never instruct operators to inspect plaintext user content.

## D09 — Produce signed mobile releases

Audit reference: DEPLOY-10.

Depends on: C13, V08.

Objective:
Publish reproducible, signed Android and iOS artifacts only after crypto and
release gates pass.

Steps:

1. Separate CI test builds from protected release signing jobs.
2. Store signing material in platform secret stores with least privilege.
3. Generate checksums, provenance, dependency/license evidence, and release
   notes.
4. Test install/upgrade on supported devices and preserve rollback artifacts.
5. Document key rotation and lost-key recovery.

Acceptance:

- Release artifacts are signed, attributable, and install-tested.
- Fork and pull-request jobs cannot access signing keys.
- Failure of any crypto/release gate prevents publication.
