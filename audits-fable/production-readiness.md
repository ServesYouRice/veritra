# Production Readiness — Veritra Audit (audits-fable)

Deployment, operations, observability, backup/recovery, and release-engineering readiness. This is the "can an operator actually run and keep running this" view.

> **Historical snapshot:** findings and severities describe `c939f26`, not the
> current tree. Use [`../audits-codex/README.md`](../audits-codex/README.md) for
> current release status.

**Severity scale:** Critical / High / Medium / Low / Nice-to-have.

---

## Summary table

| ID | Title | Severity | Blocker |
|---|---|---|---|
| OPS-1 | Mobile app has no `android/`/`ios/` platform folders — cannot be built for a device | Critical | Yes |
| OPS-2 | No production crypto → no runnable product (cross-ref LOG-0) | Critical | Yes |
| OPS-3 | Blob directory has no backup/restore path; DB backup + blobs can desync | High | Yes |
| OPS-4 | No structured error/latency alerting; metrics are counters only, opt-in, unauthenticated | Medium | No |
| OPS-5 | No graceful WebSocket drain on shutdown | Medium | No |
| OPS-6 | No config validation / fail-fast for unsafe production settings | Medium | No |
| OPS-7 | DB backup is online but manual; restore requires downtime; no scheduling | Medium | No |
| OPS-8 | No migration rollback / down-migration story | Medium | No |
| OPS-9 | No admin surface: no way to disable/ban a user, revoke an invite, or inspect abuse | Medium | No |
| OPS-10 | Single-writer SQLite + local disk = single point of failure, no HA | Medium | No |
| OPS-11 | No dependency/vuln scanning in CI (govulncheck run manually, not gated) | Medium | No |
| OPS-12 | Log volume/format not production-tuned; no log level control | Low | No |
| OPS-13 | No container image publishing / release pipeline / versioning | Low | No |
| OPS-14 | `PRIVATE_MESSENGER_*` vs `Veritra`/`veritra_*` naming is inconsistent across surfaces | Low | No |

---

## OPS-1 — Mobile app cannot be built for a device

- **Severity:** Critical
- **Location:** `mobile/` contains `lib/`, `test/`, `pubspec.yaml`, `analysis_options.yaml`, and an `app/README.md` — but **no `android/`, `ios/`, `web/`, or platform runner directories**
- **Description:** A Flutter app needs platform folders (`android/`, `ios/`) to build an APK/IPA. They are absent. `flutter pub get` + `flutter test` + `flutter analyze` (what CI runs) work on pure Dart, but `flutter build apk`/`ios` would fail or require `flutter create .` to scaffold missing platforms. `flutter_secure_storage` also requires platform config (Keychain entitlements on iOS, min SDK on Android) that does not exist.
- **Why it matters:** There is no shippable mobile artifact. CI's green checkmarks are misleading about buildability for a device.
- **Recommended fix:** Scaffold platform folders (`flutter create --platforms=android,ios .`), configure `flutter_secure_storage` requirements (iOS Keychain sharing/entitlements, Android `minSdkVersion`), set app id/signing, and add a `flutter build` step to CI so this can't regress silently.
- **Blocker:** Yes.

## OPS-2 — No production crypto → no runnable product

- **Severity:** Critical
- **Location:** cross-reference LOG-0 (this file tracks it for the ops checklist)
- **Description:** Even with platform folders, the app is inert without client crypto. Listed here so the release gate is complete.
- **Blocker:** Yes.

## OPS-3 — Blob backup/restore is unmanaged and can desync from the DB

- **Severity:** High
- **Location:** `server/cmd/messenger-server/main.go:170-224` (`backup` copies only the SQLite DB via VACUUM INTO; both `backup` and `restore` print "encrypted blobs are operator-managed / restored separately"), `server/internal/uploads/local.go`
- **Description:** The DB records `attachment_envelopes`/`backup_blobs` rows referencing blob files on disk, but the backup tool copies only the database. An operator who backs up the DB and restores it later will have rows pointing at blobs that were never captured (or captured at a different time), producing dangling references. The two stores have no consistency mechanism.
- **Why it matters:** Backups that silently lose attachment/backup contents — or restore to an inconsistent state — are worse than no backups because they create false confidence. This is a data-integrity/DR gap.
- **Recommended fix:** Provide a single backup command that snapshots DB + blob directory together (or documents an atomic filesystem snapshot approach), and a restore that validates blob/row consistency. At minimum, make the DR runbook explicit and tested. Consider a periodic integrity check that flags rows whose blobs are missing.
- **Blocker:** Yes if attachments/backups are in launch scope.

## OPS-4 — Observability is thin

- **Severity:** Medium
- **Location:** `server/internal/app/app.go:71-79` (metrics opt-in via env, unauthenticated — SEC-9), `:171-187` (request logs), `doctor` command
- **Description:** Metrics are request counters by status class only — no latency histograms, no per-route breakdown, no DB pool stats, no WebSocket connection gauge, no error-type counters. Logs are structured (`slog`) but there's no log-level control and no correlation beyond a per-request ID. There's no alerting integration and no health signal beyond `/healthz` (DB ping).
- **Why it matters:** Operators can't answer "is it slow, and where" or "are we leaking connections" or "why did 5xx spike." The blob-DoS (SEC-4) would show up only as a disk-full crash, not as a metric.
- **Recommended fix:** Add latency histograms per route class, gauges for active WS connections and DB pool utilization, error-type counters, and disk-usage/quota metrics. Gate `/metrics` (SEC-9). Document a minimal Prometheus+Alertmanager setup.
- **Blocker:** No.

## OPS-5 — No graceful WebSocket drain on shutdown

- **Severity:** Medium
- **Location:** `server/internal/app/app.go:81-104` (`server.Shutdown` with 10 s timeout), `server/internal/realtime/websocket.go`
- **Description:** `http.Server.Shutdown` does not close **or wait for** hijacked WebSocket connections. The original audit incorrectly said those connections force the shutdown timeout to expire. The actual issue remains: without explicit hub shutdown, upgraded sockets receive no WebSocket Close frame and are cut when the process exits, so clients see an abnormal disconnect.
- **Recommended fix:** On shutdown, signal the hub to send Close frames (1001 "going away") to all clients and stop accepting new upgrades, then wait briefly before forcing exit.
- **Blocker:** No.

## OPS-6 — No fail-fast on unsafe production configuration

- **Severity:** Medium
- **Location:** `server/internal/config/config.go` (loads env with defaults, validates only trusted-proxy CIDRs)
- **Description:** The server will happily start bound to `:8080` on all interfaces with plain HTTP and no reverse proxy, no TLS, and no `TrustedProxies` — the exact insecure posture the docs warn against. There's no "production mode" that refuses to start without TLS termination in front, and no warning when `X-Forwarded-For` handling is effectively disabled (empty trusted proxies) while clearly behind a proxy.
- **Recommended fix:** Add an optional `PRIVATE_MESSENGER_ENV=production` that fails fast (or loudly warns) when: bound to a non-loopback address without a declared TLS/proxy front, or metrics exposed without auth. Log a startup summary of the effective security posture.
- **Blocker:** No.

## OPS-7 — DB backup is online but manual; restore is offline

- **Severity:** Medium
- **Location:** `main.go:170-192` (`backup`), `restore` requires the server stopped (probes the WAL lock)
- **Description:** `VACUUM INTO` does not require stopping the server, so calling backups “offline-only” was incorrect. Backup creation is online but unscheduled and operator-managed; restore explicitly requires downtime. There is no built-in retention/rotation or documented RPO/RTO.
- **Recommended fix:** Provide a scheduled-backup option (internal ticker or documented cron + rotation), and document RPO/RTO and a tested restore runbook. Combine with OPS-3 for blob consistency.
- **Blocker:** No.

## OPS-8 — No down-migration / rollback story

- **Severity:** Medium
- **Location:** `server/internal/storage/sqlite.go:147-208` (forward-only migrations, checksum-guarded), `server/migrations/`
- **Description:** Migrations are apply-only. There is no down path and no documented rollback procedure if a deploy ships a bad migration. The checksum guard (good) will actively *block* startup if a migration file is edited after being applied — meaning a botched migration can wedge the fleet with no scripted recovery beyond restore-from-backup.
- **Recommended fix:** Document the rollback procedure (restore prior backup), and adopt a convention that migrations are additive/backward-compatible (expand-contract) so a rollback of the binary doesn't require a schema rollback.
- **Blocker:** No.

## OPS-9 — No administrative surface

- **Severity:** Medium
- **Location:** whole system — roles exist (`owner`/`admin`/`moderator`/`member`) but the only admin-gated capability is `CanManageInvites`
- **Description:** An owner/admin has no way to: list users, suspend/ban an abusive account, revoke an outstanding invite, see storage usage per account (SEC-4/SEC-12), view audit events, or inspect instance health from within the product. `audit_events` are written but never surfaced anywhere. Moderation of a community is limited to add/role operations.
- **Why it matters:** The moment a real instance has more than a handful of trusted users, the operator needs to respond to abuse. Today they'd be editing SQLite by hand.
- **Recommended fix:** Add admin endpoints (list/suspend accounts, revoke invites, view audit log, view storage usage) and a minimal admin UI or CLI subcommands. This is also where SEC-4 quota visibility lives.
- **Blocker:** No (but early-post-launch necessity).

## OPS-10 — Single point of failure, no HA

- **Severity:** Medium (by design)
- **Location:** ADR-0005 (single-node), in-memory Hub, local blob store, one SQLite file
- **Description:** No redundancy: process crash or disk failure = full outage and potential data loss between backups. Acceptable per the stated design, but operators must understand the RPO is "since last backup" and there is no failover.
- **Recommended fix:** Document the availability model plainly; recommend filesystem snapshots + off-host backup copies. HA is out of scope for the current architecture (see nice-to-haves architecture section).
- **Blocker:** No.

## OPS-11 — Dependency/vuln scanning not gated in CI

- **Severity:** Medium
- **Location:** `.github/workflows/ci.yml` (runs test/vet/gofmt, cargo, flutter, license check — no `govulncheck`, no `cargo audit`, no Dart `pub audit`/dependency review)
- **Description:** `WORK_IN_PROGRESS.md` says `govulncheck` was run manually and is clean, but CI does not enforce it, so a future vulnerable dependency won't fail a build. No Dependabot config is present in the repo tree (alerts were mentioned as addressed, but the automation isn't in-repo).
- **Recommended fix:** Add `govulncheck`, `cargo audit`, and a Dart dependency check to CI as gating steps; commit a Dependabot/renovate config.
- **Blocker:** No.

## OPS-12 — Logging not production-tuned

- **Severity:** Low
- **Location:** `server/internal/app/app.go:38-41,171-187` (text handler to stdout, Info level fixed)
- **Description:** Log level is hardcoded (`&slog.HandlerOptions{}` = Info); no way to raise/lower via env, no JSON option for log aggregation, and every request logs at Info (fine, but unfiltered volume). Text format is human-friendly but not ideal for ingestion.
- **Recommended fix:** Env-driven level and a JSON handler option for aggregation.
- **Blocker:** No.

## OPS-13 — No release/versioning pipeline

- **Severity:** Low
- **Location:** repo-wide — no image publishing, no version stamping, no changelog automation
- **Description:** The Dockerfile builds locally but nothing publishes a versioned image; the binary has no embedded version/build info; there's no tagged-release workflow. `mobile` is `0.1.0+1` but the server has no version at all.
- **Recommended fix:** Stamp version/commit into the binary (`-ldflags`), add a release workflow that builds and publishes the container image on tags, and a CHANGELOG.
- **Blocker:** No.

## OPS-14 — Inconsistent product naming

- **Severity:** Low
- **Location:** env vars `PRIVATE_MESSENGER_*`, code package `private-messenger`, CLI "Private Messenger server", metrics `veritra_*`, deep link `veritra://`, product name "Veritra", default instance name "Private Messenger"
- **Description:** Three names coexist (`private-messenger`, "Private Messenger", "Veritra"). Operators configuring env vars vs. reading the README about "Veritra" will be confused; the default instance name doesn't match the brand.
- **Recommended fix:** Pick one brand and align env-var prefix, package path (or at least user-facing strings), default instance name, and docs. Provide a migration alias for env vars if renaming the prefix.
- **Blocker:** No.

---

## Release gate checklist

Before a first production release, all of these must be true. Today, none of the "Yes" blockers are met.

- [ ] Client E2EE crypto implemented and wired (LOG-0 / OPS-2)
- [ ] Mobile platform folders + signing configured; `flutter build` in CI (OPS-1)
- [ ] Blob + DB backup/restore proven consistent, runbook tested (OPS-3, OPS-7)
- [ ] Storage quotas enforced (SEC-4)
- [ ] Conversation authz hole fixed (SEC-1); typing membership check (SEC-2)
- [ ] WebSocket ping/pong fixed (LOG-2); session-expiry handling in app (LOG-5)
- [ ] Username validation (LOG-9); constraint errors mapped to 4xx (LOG-10/11)
- [ ] Push delivery (at least one provider) — otherwise messages only arrive while foregrounded
- [ ] Admin/moderation basics + audit-log visibility (OPS-9)
- [ ] CI gates vuln scanning (OPS-11); metrics auth'd (SEC-9)
- [ ] Accessibility pass (UI-12); human-readable errors (UI-1); auth validation (UI-2)
