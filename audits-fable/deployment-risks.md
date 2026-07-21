# Deployment Risks

Artifacts reviewed: `server/Dockerfile`, `deploy/docker-compose.yml`, `deploy/caddy/Caddyfile`, `deploy/systemd/private-messenger.service`, `.github/workflows/ci.yml` + `release.yml`, `scripts/*`.

Strong points: scratch image running as 65532 with pinned base digests, binary self-healthcheck (no shell in image), `no-new-privileges`, memory/pids limits, log rotation, loopback-only published port with an opt-in Caddy TLS profile, pinned Caddy digest, systemd `StateDirectory`+`UMask=0077`, release workflow with provenance attestation, SHA-pinned actions, Dependabot.

---

## D-1. Compose and systemd examples don't set `PRIVATE_MESSENGER_ENV=production`

- **Severity:** High
- **Location:** `deploy/docker-compose.yml` (env block), `deploy/systemd/private-messenger.service`
- **Problem:** The config defaults to `development`, and `ValidateServe`'s production guardrails (non-loopback listener requires trusted proxies; metrics listener must be loopback/private) only fire in production mode. Operators copying the reference deployments run in development mode indefinitely — and any future dev-only relaxations quietly apply to real instances.
- **Recommended fix:** Set `PRIVATE_MESSENGER_ENV: production` in both examples; consider logging a prominent warning at startup when serving on a non-loopback address in development mode.
- **Blocker before production:** Yes (one-line change to the examples).

## D-2. Neither reference deployment sets a setup token

- **Severity:** High (paired with security S-1)
- **Location:** `deploy/docker-compose.yml`, systemd unit / `server/config.example.env`
- **Problem:** `PRIVATE_MESSENGER_SETUP_TOKEN` is absent from both reference deployments. In the systemd + host-proxy topology this makes first-boot owner takeover possible (S-1); in Compose it merely means setup must occur from inside the network namespace. `config.example.env` should be checked to prominently require it (it exists but the deployments don't reference it).
- **Recommended fix:** Both examples should require an explicit token (compose: `PRIVATE_MESSENGER_SETUP_TOKEN: "CHANGE-ME"` with a comment; better, refuse to start in production env without either a token or completed setup). See S-1 for the code-side fail-closed fix.
- **Blocker before production:** Yes.

## D-3. No automated backup story in the reference deployments

- **Severity:** Medium
- **Location:** `deploy/` (nothing schedules `messenger-server backup`); `docs/recovery.md`
- **Problem:** The backup CLI is well built (manifest, checksums, blob verification, staged restore with rollback) but nothing runs it. The scratch image has no cron; Compose defines no sidecar/ofelia job; the systemd dir has no `veritra-backup.timer`. Self-hosters will discover backups the day they need one. Also note: `backup` writes into `DataDir/backups` by default — same volume/disk as the live data, so a disk failure takes both.
- **Recommended fix:** Ship a `veritra-backup.service` + `.timer` pair for systemd and a documented `docker compose run messenger backup /backups/…` pattern with a second volume; document off-host copy expectations. Add retention pruning of old backups.
- **Blocker before production:** Yes for the docs/timer; the CLI itself is ready.

## D-4. Single-instance assumptions are real — document the guardrails

- **Severity:** Medium–Low
- **Location:** SQLite writer + in-memory hub/rate-limiter/typing state
- **Problem:** Realtime fan-out, rate limits, and typing throttles are all process-local; running two replicas behind one proxy would half-deliver events and double limits, and two processes on one SQLite file is prevented only by busy-timeouts (the CLI probes exclusivity for restore/reset, the server does not take an exclusive startup lock or PID file).
- **Recommended fix:** Take an advisory startup lock (e.g., `BEGIN EXCLUSIVE` probe or flock on a lockfile in DataDir) and refuse to start a second instance; state "exactly one replica" in deployment docs.
- **Blocker before production:** No (Compose can't trivially double-run it), but the startup lock is cheap insurance against systemd+docker double-starts.

## D-5. Metrics port is unreachable in Compose as shipped — and unprotected if exposed carelessly

- **Severity:** Low
- **Location:** `app.go` management server (`127.0.0.1:9090` default), compose file (no port mapping, no `PRIVATE_MESSENGER_ENABLE_METRICS`)
- **Problem:** With metrics enabled in a container, `127.0.0.1:9090` is only reachable via `docker exec` (no shell in scratch → effectively unreachable). Operators will "fix" this by setting `PRIVATE_MESSENGER_MANAGEMENT_ADDR=:9090` and publishing it — the endpoint has no auth (production validation at least restricts it to loopback/private IPs). 
- **Recommended fix:** Document the supported pattern (management addr on the compose network + a scrape sidecar, not a published port); consider optional bearer-token auth on `/metrics`.
- **Blocker before production:** No.

## D-6. Graceful shutdown drops in-flight uploads at 10 s

- **Severity:** Low
- **Location:** `app.go:122-133` (shutdown context 10 s), route deadline 15 min for uploads
- **Problem:** A deploy/restart during a large attachment/backup upload kills it (client must retry whole upload; no resumable protocol). `Hub.Drain` before `server.Shutdown` also closes sockets before the HTTP listener stops accepting, so a client can reconnect its WS to a dying instance and be dropped again — harmless with the client's backoff, but noisy.
- **Recommended fix:** Acceptable v1; document that deploys interrupt uploads. Longer term: resumable uploads (tus-style or content-addressed chunks).
- **Blocker before production:** No.

## D-7. Release/runtime version drift risks

- **Severity:** Low
- **Location:** CI `go-version: "1.25.0"` vs Dockerfile `golang:1.26`; `flutter-version: "3.44.0"` pinned
- **Problem:** Tests run on Go 1.25, the shipped binary builds on Go 1.26 — subtle toolchain differences (GC, stdlib behavior) are untested. Minor, but free to fix.
- **Recommended fix:** Align CI Go version with the Dockerfile (or build/test the container image in CI — the compose smoke job partially covers this).
- **Blocker before production:** No.

## D-8. Operational docs gaps for self-hosters

- **Severity:** Medium
- **Problem:** No single "production install" runbook covering: required env (`ENV=production`, setup token, trusted proxies, VAPID keygen), TLS via the Caddy profile, backup timer, upgrade procedure (image pull → migrate happens automatically on start — is downgrade safe? No migration down-paths exist), disk-full behavior, and log expectations. Pieces exist across README/docs but not as one checklist; the systemd unit could also use more hardening (`ProtectHome=yes`, `CapabilityBoundingSet=`, `RestrictAddressFamilies`, `SystemCallFilter=@system-service`, `ProtectKernelTunables`).
- **Recommended fix:** `docs/deploy-production.md` runbook + systemd hardening pass. Note explicitly: **no downgrade migrations** — restore from backup is the rollback path (the backup manifest already records migration versions, good).
- **Blocker before production:** Runbook: yes for a self-hosted product; hardening: no.

---

**Priority order:** D-1 + D-2 (same PR, minutes of work) → D-3 → D-8 → D-4 → D-5/D-6/D-7.
