# Deployment and Operations Risks

## Deployment posture

The repository has several solid production foundations: a non-root scratch container, explicit persistent volumes, a health endpoint, resource limits in Compose, Caddy/TLS guidance, systemd support, backup and restore commands, and documented single-node expectations. The present deployment story is nevertheless not launch-ready because release gating, mobile distribution, recovery automation, and operational evidence are incomplete.

## Findings

### DEP-01 - The release gate is a source-marker check, not a release evidence gate

- **Severity:** High
- **Location:** `scripts/release-readiness.sh`; `.github/workflows/release.yml`
- **Description:** Readiness currently fails while two known crypto markers remain, which is a useful fail-closed safeguard. Once those strings disappear, however, the script does not validate crypto review evidence, tests, advisory status, live/native contracts, mobile builds, migration/restore evidence, or required CI completion.
- **Why it matters for production:** Removing or renaming a marker can unlock publication without proving that the replacement is safe or complete. Policy encoded as text matching is fragile and easy to bypass accidentally.
- **Recommended fix:** Replace marker-only readiness with a machine-readable release manifest generated from protected checks. Require the exact commit, complete CI suite, independent crypto review artifact, advisory policy, ABI and live-contract results, signed artifacts, migration compatibility, and restore drill. Keep source markers as defense in depth.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** TEST-06; SEC-03; repository protection and attestation design.

### DEP-02 - The release workflow does not produce signed mobile applications

- **Severity:** High
- **Location:** `.github/workflows/release.yml`; Android/iOS signing and distribution configuration
- **Description:** Tag releases build server binaries and a container, but not signed Android or iOS artifacts. The mobile package remains at an early version and there is no evidenced store/TestFlight/internal-distribution promotion path.
- **Why it matters for production:** Veritra is primarily a mobile messenger. Server artifacts alone cannot deliver or verify the product, and unsigned local builds do not exercise entitlements, native library packaging, secure storage, push, or upgrade behavior as users receive them.
- **Recommended fix:** Add protected mobile build/sign jobs with environment separation, secret isolation, provenance, SBOMs, native library inclusion checks, and staged distribution. Promote the exact tested release candidate rather than rebuilding for production.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** Apple/Google credentials; native ABI; TEST-04 and TEST-05; versioning policy.

### DEP-03 - Compose rebuilds source instead of consuming the attested release image

- **Severity:** High
- **Location:** `deploy/docker-compose.yml`; release container publication and operations documentation
- **Description:** The documented Compose path uses `build:` from local source. That permits operators to deploy a different image from the one built, scanned, and attested by the release workflow.
- **Why it matters for production:** The runtime binary becomes dependent on local checkout state, toolchain availability, and build context. Incident response cannot reliably map a container to a published immutable artifact.
- **Recommended fix:** Make production Compose reference a versioned image digest. Keep a clearly separate development override for local builds. Record the image digest in backup/upgrade logs and verify signatures/provenance before activation.
- **Blocker before production:** Yes for a supported production deployment path.
- **Related risks or dependencies:** Registry availability; release signing/attestation; rollback documentation.

### DEP-04 - Backup and restore use fixed staging paths with destructive cleanup

- **Severity:** High
- **Location:** `server/cmd/messenger-server/main.go`, `backup` and `restore` staging at `<output>.tmp` and `<storage>.restore-tmp`
- **Description:** Backup creates and later removes a predictable `<output>.tmp` directory. Restore unconditionally removes and recreates a predictable `.restore-tmp` path. A pre-existing directory at either location can be reused or deleted, and concurrent invocations collide.
- **Why it matters for production:** Recovery tooling should have an exceptionally narrow destructive scope. Predictable staging can destroy unrelated operator data, mix stale files into an archive, or make concurrent/aborted operations unsafe.
- **Recommended fix:** Resolve and validate all target paths, create a unique sibling staging directory with exclusive semantics, reject unexpected pre-existing targets, write a provenance marker, and only remove a directory proven to belong to that invocation. Lock backup/restore operations per instance.
- **Blocker before production:** Yes before relying on these commands for irreplaceable data.
- **Related risks or dependencies:** TEST-08; Windows/Unix path behavior; operator permissions.

### DEP-05 - Restore activation is not robust against collisions or interruption

- **Severity:** High
- **Location:** `server/cmd/messenger-server/main.go`, `restore` rollback naming and database/blob activation sequence
- **Description:** Rollback paths use second-resolution naming and can collide. Database and blob storage are activated as separate filesystem operations, and the implementation does not provide clear crash-durability/fsync guarantees around the final switch.
- **Why it matters for production:** A power loss or process failure can leave the database and blob tree from different restore points. Collision behavior can also prevent rollback exactly when it is needed.
- **Recommended fix:** Use unique rollback identifiers, preflight all destinations, verify archive/database/blob consistency before mutation, fsync staged files and parent directories where supported, and use a journaled activation plan that can deterministically resume or roll back. Document filesystem requirements and test interruption at every step.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** DEP-04; TEST-08; platform-specific rename guarantees.

### DEP-06 - Build toolchains drift across local, CI, and container paths

- **Severity:** Medium
- **Location:** `server/go.mod`; `.github/workflows/ci.yml`; `.github/workflows/release.yml`; `server/Dockerfile`
- **Description:** Go versions are not consistently pinned across the module/CI and Docker build paths. The audited configuration used Go 1.25.x in module/CI contexts while the Dockerfile referenced 1.26.4.
- **Why it matters for production:** Toolchain drift can produce different compilation behavior, dependency selection, standard-library security posture, or test results between CI and the released container.
- **Recommended fix:** Define one supported Go patch version in a central update mechanism and consume it in CI, local containers, and release builds. Have CI verify version alignment and record the compiler in provenance.
- **Blocker before production:** No, but fix before the first supported release.
- **Related risks or dependencies:** Base image availability; reproducible build policy.

### DEP-07 - The single-instance lock does not cover overridden database/storage paths

- **Severity:** Medium
- **Location:** `server/cmd/messenger-server/main.go`, `serve`/`acquireInstanceLock`; server path configuration overrides
- **Description:** Lock identity is based on the data directory, while database and blob paths can be independently overridden. Two processes using different data directories could therefore point to the same SQLite database or storage path while holding different locks.
- **Why it matters for production:** Multiple writers can bypass the intended singleton protection, risking SQLite contention, duplicate background jobs, and conflicting blob/retention operations.
- **Recommended fix:** Canonicalize and lock the actual database and storage resources, reject overlapping ownership, and log privacy-safe resolved configuration at startup. Add a deployment preflight test for conflicting path combinations.
- **Blocker before production:** Yes if path overrides are supported in the production contract; otherwise remove or constrain the overrides.
- **Related risks or dependencies:** Symlink/canonical-path behavior; filesystem lock semantics.

### DEP-08 - Compose injects long-lived secrets through environment variables

- **Severity:** Medium
- **Location:** `deploy/docker-compose.yml`; server secret configuration
- **Description:** Sensitive configuration is supplied through environment variables, which can be exposed to users with container inspection access and can leak into support diagnostics.
- **Why it matters for production:** Container control already implies significant privilege, but reducing secret copies and accidental exposure is still important for signing, push, TURN, and bootstrap credentials.
- **Recommended fix:** Support file-based secret inputs (`*_FILE`) and document Docker secrets or a host secret manager. Redact configuration dumps and rotate any secret used during setup or incident debugging.
- **Blocker before production:** No for a tightly controlled host; recommended before broader supported deployment.
- **Related risks or dependencies:** Configuration API changes; secret rotation runbooks.

### DEP-09 - Backups are manual and have no monitored recovery objective

- **Severity:** High
- **Location:** `docs/operations.md`; deployment examples; backup/restore tooling
- **Description:** The project documents backup commands but does not ship a scheduler/timer, retention policy, off-host copy verification, success marker, alert, or defined recovery point/recovery time objective. A restore drill is not part of release or operational readiness.
- **Why it matters for production:** A backup command that nobody schedules or verifies is not a recovery system. Silent failures can remain unnoticed until user data must be restored.
- **Recommended fix:** Provide supported cron/systemd-timer examples, encrypted off-host transfer guidance, immutable retention, integrity verification, monitored completion age, and periodic automated restore drills to a disposable instance. Publish realistic RPO/RTO for each deployment tier.
- **Blocker before production:** Yes before storing irreplaceable production data.
- **Related risks or dependencies:** DEP-04 and DEP-05; storage provider; key escrow/recovery policy.

### DEP-10 - Automatic migrations rely on manual backup and rollback discipline

- **Severity:** Medium
- **Location:** Server startup migrations; upgrade and rollback documentation
- **Description:** The server applies migrations at startup. Documentation advises backup, but there is no preflight/dry-run command, schema compatibility matrix, or automated block when a binary cannot safely roll back after migration.
- **Why it matters for production:** A routine container restart can become an irreversible data upgrade. Operators may discover incompatibility only after the old version no longer understands the database.
- **Recommended fix:** Classify migrations as backward-compatible or breaking, expose a preflight report, record current/target schema, require a fresh verified backup for breaking transitions, and test N-1 upgrade/rollback. Separate expand and contract phases where practical.
- **Blocker before production:** No for the current early schema, but required before promising supported upgrades.
- **Related risks or dependencies:** TEST-08; release version policy; database size and migration duration.

### DEP-11 - Host hardening profiles are incomplete

- **Severity:** Low
- **Location:** systemd unit and Compose security options
- **Description:** The service uses a non-root container and some hardening, but the host unit could further restrict home/device access, address families, executable memory, personality changes, kernel interfaces, and writable paths. Compose could make dropped capabilities/read-only intent more explicit.
- **Why it matters for production:** Defense in depth limits damage if an internet-facing parsing or dependency vulnerability is exploited.
- **Recommended fix:** Threat-model required syscalls, address families, paths, and capabilities; then add only compatible systemd/container restrictions. Verify startup, SQLite, DNS, TLS, push, TURN, backup, and upgrade under the hardened profile.
- **Blocker before production:** No.
- **Related risks or dependencies:** Push/network provider behavior; backup path access; portability goals.

### DEP-12 - Operational metrics and alerts do not cover service health dependencies

- **Severity:** Medium
- **Location:** Server metrics, health endpoints, operations documentation
- **Description:** Basic request/runtime telemetry exists, but no clear alert set covers sync lag, retention backlog, push queue/provider outcomes, WebSocket connection churn, SQLite latency/checkpoint health, disk headroom, backup age, restore drill age, or crypto/decryption failures.
- **Why it matters for production:** `/healthz` returning 200 does not prove that messages can sync, push wakes are being delivered, storage is converging, or data can be recovered.
- **Recommended fix:** Define service-level indicators and privacy-safe metrics for each critical flow. Add readiness/degraded-state semantics where appropriate and publish actionable alert thresholds/runbooks. Avoid user, conversation, endpoint, token, or ciphertext labels.
- **Blocker before production:** Yes for an operated general-availability service; a private alpha can begin with a documented manual runbook.
- **Related risks or dependencies:** Durable push work; PERF-05 and PERF-10; privacy review.

## Recommended deployment sequence

1. Keep publication closed until the release evidence gate and production crypto review are real (DEP-01).
2. Build and verify signed mobile release candidates alongside server artifacts (DEP-02).
3. Deploy immutable signed image digests rather than rebuilding source (DEP-03).
4. Correct staging/activation safety and prove backup/restore with fault injection (DEP-04 and DEP-05).
5. Automate, monitor, and drill backups before accepting irreplaceable data (DEP-09).
6. Align toolchains and resource locking (DEP-06 and DEP-07).
7. Define migration compatibility, secrets handling, hardening, metrics, and runbooks (DEP-08 and DEP-10 through DEP-12).

## Positive controls to retain

- Non-root scratch runtime image.
- Explicit fail-closed production crypto marker.
- Health endpoint and graceful service shape.
- Single-node deployment scope rather than an unsupported cluster claim.
- Resource limits and persistent volume examples.
- Existing operations documentation and backup/restore commands as a base for hardening.
