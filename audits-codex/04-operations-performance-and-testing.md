# Operations, performance, architecture, and testing

Unsafe restore, ignored path configuration, and container-volume ownership are release gates R-11 through R-13.

## OPS-01 — Server backup is not an instance-consistent backup (High)

- **Evidence:** the CLI backs up SQLite with `VACUUM INTO` but explicitly leaves encrypted blobs operator-managed (`server/cmd/messenger-server/main.go:170-190`). Blob rows and files can change independently while an operator copies the directory.
- **Impact:** restore can produce database references to missing blobs, orphan files, or mismatched versions; no manifest proves completeness.
- **Fix:** create a versioned backup manifest, coordinate a stable DB/blob snapshot or content-addressed generation, checksum every object, include configuration/migration version, and regularly test full restore.

## OPS-02 — Health and doctor checks can be green during data failure (Medium)

- **Evidence:** `Store.Check` only pings writer and reader pools (`server/internal/storage/sqlite.go:124-125`). The HTTP health route calls only that (`server/internal/httpapi/api.go:66-71`).
- **Impact:** disk-full/read-only blob storage, corrupt SQLite pages, broken foreign keys, missing crypto/provider readiness, or exhausted free space can pass health checks.
- **Fix:** separate liveness from readiness; check a bounded DB read/write, blob-directory writeability/reserve, migration status, and critical provider readiness. Put expensive `quick_check`/foreign-key checks in doctor/startup jobs.

## OPS-03 — The systemd example exposes plaintext HTTP on every interface (High)

- **Evidence:** `deploy/systemd/private-messenger.service:10` sets `PRIVATE_MESSENGER_ADDR=:8080` with no reverse-proxy dependency, TLS guidance in the unit, firewall binding, `EnvironmentFile`, or `StateDirectory` setup.
- **Impact:** copying the production-looking unit can expose setup, passwords, tokens, and metadata over cleartext LAN/Internet HTTP.
- **Fix:** bind loopback by default, document a TLS reverse proxy, use `StateDirectory=private-messenger`, an environment file with strict permissions, and startup assertions for unsafe public HTTP.

## OPS-04 — Development scripts bind plaintext to the LAN (Medium)

- **Evidence:** Docker fallbacks publish `-p 8080:8080` (`scripts/dev.sh:9`, `scripts/dev.ps1:10`) while the server listens on `:8080`.
- **Impact:** a developer can unknowingly expose an uninitialized takeover-prone instance and credentials to the local network.
- **Fix:** publish `127.0.0.1:8080:8080`, use ephemeral dev credentials/data, and print the exact exposure.

## OPS-05 — Request logging and Compose resource controls are incomplete (Medium)

- **Evidence:** every request is logged at info (`server/internal/app/app.go:171-186`). `routeClass` redacts several IDs but misses `/api/v1/devices/{id}` (`app.go:262-278`). Compose has no log rotation, disk/memory/PID limits, or disk-reserve monitoring (`deploy/docker-compose.yml`).
- **Impact:** device identifiers enter logs, and attack/error traffic can grow Docker's default logs until the host disk is full; unbounded resource contention can take down the host.
- **Fix:** classify every parameterized route, sample expected traffic, rotate/cap logs, set practical resource limits, and alert on data/log volume free space.

## OPS-06 — Native failures can be masked by the PowerShell scripts (High)

- **Evidence:** native Go/Cargo/Flutter branches call commands without checking `$LASTEXITCODE` (`scripts/test.ps1:5-27`, `scripts/lint.ps1:5-39`). Only Docker branches check it. Windows PowerShell's `$ErrorActionPreference = "Stop"` does not reliably convert a nonzero native exit into a terminating error.
- **Impact:** local test/lint scripts can continue and exit successfully after a failed native tool, creating false release confidence.
- **Fix:** check `$LASTEXITCODE` after every native command (with `try/finally` for location restoration), or require PowerShell 7 and enable native error preference explicitly; test the scripts with deliberate failures.

## OPS-07 — CI does not exercise the product's production boundaries (High)

- **Evidence:** `.github/workflows/ci.yml` runs Go unit/vet/format, Rust stub tests, Flutter unit/analyze/format, and a simple license script. It has no Docker/Compose smoke, migrations/restore, Android/iOS build, client-server contract, WebSocket protocol, cross-device sync, E2EE vector, race, fuzz, coverage threshold, or end-to-end test.
- **Impact:** current release blockers—such as the channel-kind mismatch and container startup risk—can merge while every defined job appears conceptually green.
- **Fix:** add layered required jobs: server race/integration, migration/backup restore, Compose fresh-volume smoke, generated API contracts, crypto vectors, two-device sync/E2E, Android/iOS builds, accessibility/widget tests, and minimum coverage on security invariants.

## OPS-08 — Workflow actions are mutable and permissions/timeouts are implicit (Medium)

- **Evidence:** actions use floating major tags such as `actions/checkout@v4`, `actions/setup-go@v5`, `subosito/flutter-action@v2`, and Rust `stable` (`.github/workflows/ci.yml:11-50`). The workflow has no top-level `permissions`, concurrency cancellation, or job timeouts.
- **Impact:** upstream tag/toolchain movement changes trusted build code and outputs; hung jobs waste capacity; default token permissions are not made reviewable.
- **Fix:** pin actions/toolchains by reviewed digest/commit, declare read-only permissions, add timeouts and concurrency, and automate reviewed update PRs.

## OPS-09 — Images/releases are not reproducible or attestable (Medium)

- **Evidence:** build/runtime images use mutable tags (`golang:1.25`, `gcr.io/distroless/static-debian12:nonroot`, `caddy:2`, `flutter:stable`, `rust:1.82`). There is no SBOM, image digest pinning, artifact signing, provenance, checksum publication, or release workflow.
- **Impact:** operators cannot prove what was built or detect/tag rollback; rebuilds can differ without repository changes.
- **Fix:** pin image digests, generate CycloneDX/SPDX SBOMs, sign images/binaries, emit SLSA-style provenance and checksums, and document a reproducible release process.

## OPS-10 — Private vulnerability reporting has no usable contact (Medium)

- **Evidence:** `SECURITY.md` says a dedicated security address will be published “once established” and otherwise asks reporters not to open public issues.
- **Impact:** reporters have no supported private channel, so serious vulnerabilities may be disclosed publicly or not reported.
- **Fix:** publish a monitored security email/form, PGP or equivalent secure option, supported versions, response targets, and disclosure policy.

## OPS-11 — Expired/terminal operational rows are never pruned (Medium)

- **Evidence:** the sweeper removes expired messages plus old sync/audit events only (`server/internal/app/app.go:110-145`). Expired sessions/invites/device links, terminal push subscriptions, call sessions, and obsolete backup/attachment records have no lifecycle cleanup.
- **Impact:** metadata and indexes grow indefinitely, increasing privacy retention, query cost, and operator ambiguity.
- **Fix:** define retention per table and blob class, implement bounded resumable jobs, expose counts/age in doctor metrics, and verify that cleanup respects legal/user expectations.

## OPS-12 — Global HTTP timeouts conflict with supported upload sizes (High)

- **Evidence:** the server sets 30-second read/write timeouts (`server/internal/app/app.go:81-88`) while accepting encrypted 50 MiB attachments and 100 MiB backups (`server/internal/httpapi/api.go:894-975`).
- **Impact:** legitimate mobile uploads on slow links are terminated before completion; retrying large bodies amplifies bandwidth and temporary-file churn.
- **Fix:** use route-aware streaming limits/deadlines, resumable chunked uploads with idempotency/integrity, and reverse-proxy limits aligned with the application.

## OPS-13 — Realtime has no connection budget or graceful drain (High)

- **Evidence:** each authenticated WebSocket is registered and spawns frame handling with no per-account/IP/global cap (`server/internal/httpapi/api.go:1091-1101`; `server/internal/realtime/websocket.go:69-72`). `http.Server.Shutdown` does not manage hijacked connections and the Hub has no server-shutdown broadcast/close.
- **Impact:** authenticated connection floods consume descriptors/goroutines; deploy shutdown can abruptly lose events or leave sockets until process death.
- **Fix:** enforce layered connection budgets, idle/auth expiry, backpressure/drop policy, metrics, and a Hub drain that stops upgrades, sends close, waits with a deadline, then terminates.

## OPS-14 — SQLite PRAGMAs are not guaranteed on every pooled connection (High)

- **Evidence:** pools are opened by filename and PRAGMAs are executed once (`server/internal/storage/sqlite.go:78-107`). Reader pool size is 4–16; `foreign_keys` and `busy_timeout` are connection-local. A replacement writer connection can also lose settings.
- **Impact:** readers can fail immediately under writer contention, and a recreated writer connection can perform writes without foreign-key enforcement.
- **Fix:** encode `_pragma=foreign_keys(1)` and `_pragma=busy_timeout(...)` in the modernc SQLite DSN/connector so every connection is initialized; assert values across multiple acquired connections.

## OPS-15 — Expiry pruning is an unindexed, unbounded delete (Medium)

- **Evidence:** `PruneExpiredMessages` deletes all matching rows in one statement (`server/internal/storage/sqlite.go:1254-1262`). The migration has no index on `expires_at`; only conversation/created is indexed (`server/migrations/0001_init.sql:191-195`).
- **Impact:** a large expiry wave can scan and lock the message table, expand WAL, delay writes, and make the six-hour sweeper unpredictable.
- **Fix:** index non-null expiry, delete deterministic small batches, checkpoint/vacuum deliberately, and measure sweep duration/backlog.

## OPS-16 — Core lists are unpaginated and every sync event triggers broad refetches (High)

- **Evidence:** conversation/device list methods return the full result set (`server/internal/storage/sqlite.go:902-909` and device listing). The client marks almost any conversation-scoped event as requiring a full conversation refresh and selected-message refetch (`mobile/lib/core/app_state.dart:603-630`).
- **Impact:** cost grows with account history; bursts cause repeated whole-list/database reads, radio wakeups, and UI rebuilds instead of applying small deltas.
- **Fix:** paginate stable snapshots, make events carry enough opaque metadata for local delta application, coalesce invalidations, and cache state durably.

## OPS-17 — Core logic is concentrated in concrete monoliths (Medium)

- **Evidence:** `server/internal/httpapi/api.go` is about 1,300 lines and depends directly on concrete `*storage.Store` (`api.go:24-28`); `server/internal/storage/sqlite.go` is about 1,800 lines; `mobile/lib/core/app_state.dart` is 666 lines with one global `busy`/`error` state.
- **Impact:** transaction/event/privacy invariants are spread through handlers, storage, Hub calls, and UI state; tests rely on broad fakes and contract drift goes unnoticed.
- **Fix:** keep the modular monolith, but introduce small application services and narrow repository/event interfaces by domain; split client feature controllers/repositories and typed async states. Refactor behind characterization tests, not as a rewrite.

## OPS-18 — Metrics are exposed without an authentication or bind policy (Medium)

- **Evidence:** setting `PRIVATE_MESSENGER_ENABLE_METRICS=1` registers public `GET /metrics` on the main listener (`server/internal/app/app.go:71-78`). There is no separate loopback/management bind or authentication.
- **Impact:** Internet-facing deployments can reveal request volume, status distribution, and operational behavior useful for reconnaissance.
- **Fix:** serve metrics on a separate loopback/private management listener, or require explicit trusted-network/auth middleware; document proxy/firewall requirements.

## OPS-19 — Configured instance name is dead configuration (Medium)

- **Evidence:** `PRIVATE_MESSENGER_INSTANCE_NAME` is loaded into `Config.InstanceName` (`server/internal/config/config.go:16,29`) but never used. Setup takes its own request field, and the mobile client hardcodes `Private Messenger` (`mobile/lib/core/api_client.dart:21-34`).
- **Impact:** operators believe an environment setting controls identity/branding when it does not; instances are created with an unexpected name.
- **Fix:** choose one authoritative setup source, expose the stored instance identity through setup/session APIs, and remove or correctly apply the environment variable with precedence tests.

## Verification gap recorded by this audit

`go`, `cargo`, and `flutter` were unavailable. Docker Desktop's Linux engine pipe was absent, so both `scripts/test.ps1` and `scripts/lint.ps1` failed before any project check ran. This is an environment limitation, not evidence that the project passes or fails those checks. The first post-audit action should be to run the new release-gate tests in a clean, pinned CI environment.
