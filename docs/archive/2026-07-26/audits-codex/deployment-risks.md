# Deployment and Operations Risks

**Audit date:** 2026-07-21  
**Deployment verdict:** The supplied configuration is a development template, not a safe production deployment.

## Findings

### DEP-01 — Recommended Compose does not enable production safeguards

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `deploy/docker-compose.yml:5-10`; `server/internal/config/config.go`; `docs/deployment.md` |
| Blocker before production | **Yes** |

**Description:** Compose omits `PRIVATE_MESSENGER_ENV=production`, despite documentation saying public deployments must set it. The server therefore starts with development behavior unless the operator manually overrides it.

**Why it matters:** Production-only fail-fast checks for public binding/proxy/metrics configuration are not guaranteed on the copy/paste path.

**Recommended fix:** Provide a production Compose profile/override that explicitly sets production mode and validates all required secrets/domain/proxy settings before starting.

**Risks/dependencies:** Keep a clearly separate local-development profile; never make developers invent production secrets in committed files.

### DEP-02 — First-owner setup secret is absent from deployable configuration

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `deploy/docker-compose.yml`; `server/config.example.env`; Caddy deployment |
| Blocker before production | **Yes** |

**Description:** No setup token secret is wired into the public deployment example. With bridge Caddy, tokenless remote setup is rejected; with a loopback proxy topology it can become unsafe.

**Why it matters:** Operators may either be unable to initialize the instance or weaken networking to make setup work, creating owner-takeover risk.

**Recommended fix:** Require a generated high-entropy secret via Docker secret/root-readable env file, document the exact bootstrap flow, and remove/rotate it after owner creation.

**Risks/dependencies:** Do not place the token in Compose command arguments, source control, browser URLs, or logs.

### DEP-03 — Release automation ships no usable mobile application

| Field | Detail |
| --- | --- |
| Severity | Critical |
| Location | `.github/workflows/release.yml`; Android/iOS projects; native crypto packaging |
| Blocker before production | **Yes** |

**Description:** Releases contain server binaries, container image, SBOM, checksums, and provenance only. There are no signed Android/iOS artifacts, native Rust libraries, signing/notarization/provisioning flow, store/internal-distribution plan, or reproducible client version metadata.

**Why it matters:** Users cannot install a production client, and server/client/protocol compatibility cannot be released as one tested product.

**Recommended fix:** After crypto integration, add hardened signed AAB/APK and iOS archive pipelines, native library builds for supported architectures, artifact provenance/SBOM, secret-isolated signing, and protocol compatibility gates.

**Risks/dependencies:** Mobile signing credentials need protected environments and rotation. Do not publish clients while the release-readiness gate is expected to fail.

### DEP-04 — Off-host backups are a manual suggestion, not an operated control

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `docs/deployment.md:112-126`; Compose/systemd examples |
| Blocker before production | **Yes** |

**Description:** The server has backup/restore commands and good design intent, but no scheduled job, retention example, off-host encrypted transfer, success alert, or automated restore rehearsal is supplied.

**Why it matters:** A single local named volume is a single point of loss. Operators may discover broken/no backups only after disk or host failure.

**Recommended fix:** Supply privacy-safe scheduler examples, completion markers, off-host copy pattern, retention policy template, failure alert, and a documented periodic restore drill with RPO/RTO expectations.

**Risks/dependencies:** Server snapshots contain account/social metadata and ciphertext; protect them as sensitive, retain deletion history only for the stated period, and never copy incomplete directories.

### DEP-05 — The single-process constraint is documented but not enforced

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `docs/deployment.md:92-107`; server startup/storage; in-memory realtime hub/local blobs |
| Blocker before production | **Yes** for safe operations |

**Description:** `serve` does not acquire an exclusive instance lock or detect another running server. Operators/orchestrators can accidentally start two processes against one data directory even though realtime and blob semantics are single-process.

**Why it matters:** Clients can miss live events across processes and concurrent local-blob/database lifecycle operations can diverge.

**Recommended fix:** Acquire a data-directory instance lock before migrations/serve and fail with an actionable error. Document that container replicas must equal one; add a startup test for lock contention.

**Risks/dependencies:** Maintenance commands need carefully scoped shared/exclusive access and crash-safe stale-lock behavior.

### DEP-06 — Metrics are implemented but not operable in the default deployment

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | server management listener; `deploy/docker-compose.yml`; deployment docs |
| Blocker before production | No for a small private pilot |

**Description:** Compose does not enable metrics or provide a protected scraper/sidecar path. The default management bind is loopback inside a scratch container, so another container cannot scrape it as configured. Alerts are recommendations only.

**Why it matters:** Operators lack visibility into readiness, 5xx rates, latency, active requests, realtime capacity, and backup failures.

**Recommended fix:** Add an optional internal-only monitoring profile with aggregate metrics, dashboards, and starter alerts; expose management only to that network/sidecar and keep it off public ports.

**Risks/dependencies:** Preserve no-telemetry policy, bounded route labels, and exclusion of IDs/content/secrets.

### DEP-07 — Graceful shutdown is shorter than supported long operations

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `server/internal/app/app.go:100-149`; 15-minute upload/export route deadlines |
| Blocker before production | No |

**Description:** On termination the server drains sockets and gives HTTP requests 10 seconds, while uploads can legitimately run for 15 minutes and export for 5 minutes.

**Why it matters:** Routine deploys can abort active encrypted uploads/exports, leaving clients to retry and potentially leaving unlinked blobs until cleanup.

**Recommended fix:** Reject new work, expose draining readiness, configure a deployment termination grace period compatible with the chosen request policy, and make resumable/idempotent operations recover cleanly.

**Risks/dependencies:** Do not hold shutdown indefinitely; coordinate with proxy stop timeouts and upload cleanup.

### DEP-08 — Build toolchain versions drift

| Field | Detail |
| --- | --- |
| Severity | Low |
| Location | `server/go.mod` and CI use Go 1.25; `server/Dockerfile` uses Go 1.26 |
| Blocker before production | No |

**Description:** Tests/release binaries and container builds use different Go minor versions.

**Why it matters:** Compiler/runtime behavior and dependency resolution can differ between the artifact tested and the container shipped.

**Recommended fix:** Pin one reviewed Go version/digest across `go.mod` expectations, scripts, CI, Dockerfile, and release builds; automate drift detection.

**Risks/dependencies:** Coordinate upgrades with SQLite driver and platform builds.

### DEP-09 — Upgrade, rollback, and incident procedures are incomplete

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `docs/deployment.md`; migrations; release notes/workflow |
| Blocker before production | No for a controlled pilot; yes before broad self-hosting |

**Description:** Documentation explains backup principles and incompatible rollback, but lacks a step-by-step version upgrade runbook, preflight/free-space checks, expected downtime, rollback decision tree, incident triage, secret rotation, and compromised-device/server response.

**Why it matters:** Self-hosters will improvise during the highest-risk operational moments.

**Recommended fix:** Publish concise versioned runbooks with pre-upgrade backup+doctor, migration verification, rollback boundaries, log/metric diagnostics, token/VAPID/setup-secret rotation, and security contact/escalation.

**Risks/dependencies:** Test every command against release artifacts and synthetic data; never advise destructive rollback without a verified snapshot.

