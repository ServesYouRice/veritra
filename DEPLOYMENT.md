# Deployment facts for infra

What the owner's `infra` repository cannot read from its own files, as the
handbook asks of every app (`new-projects.md`). The Kubernetes manifests
live only in infra (`apps/veritra`; handbook ALL-02, owner decision
2026-11-21); this repository keeps the Compose, systemd and Caddy files that
self-hosters run. `infra` and the handbook win over this page. Everything
else, for any self-hoster, is in [`docs/operations.md`](docs/operations.md).

## Process

- One image, `ghcr.io/servesyourice/veritra`, entry point
  `messenger-server`, default command `serve`. It runs as uid 65532 on a
  read-only root and writes only to `/data` and `/tmp`.
- **Exactly one copy.** The server refuses a second writer on its data
  directory, so the Deployment has one replica and `strategy: Recreate`.
  Expect a short outage per deploy; clients reconnect and resync.
- **No migration Job.** `serve` migrates at start under the same lock, so a
  Job would find the old pod holding it and Flux would never retry it
  (2026-11-12 rehearsal). Per environment, an app entry with no `-migrate`
  entry (the app entry applies the namespace too) and an ops entry that
  depends on it; the app timeout covers the Recreate stop (up to 40 s) and
  the startup probe (up to 300 s).
- **Rollback.** Reverting the release commit is safe only when every
  migration between the two releases is additive. The older binary's migrate
  step leaves newer migrations alone
  (`TestOlderBinaryMigrateIsANoOpOnANewerSchema`) and it passes `/readyz`,
  but it answers 500 where a table changed. Across a non-additive migration
  (0092 and 0094 are such contract steps) roll forward, or restore the
  pre-upgrade backup together with its binary (the `restore` admin run with
  the older digest); never revert the release commit alone (operations.md,
  "Upgrade and rollback", "The rollback rule"). Run `backup-now` before
  promoting a release that adds a migration.

## Ports and health

| Port | What |
|---|---|
| 8080 | HTTP behind Traefik. TLS ends at Traefik |
| 9090 | Private metrics, only with `PRIVATE_MESSENGER_ENABLE_METRICS=1`, bound to the pod IP (production refuses a public or wildcard address) |

| Path | Use |
|---|---|
| `/livez` | Startup and liveness probes |
| `/readyz` | Readiness: storage healthy and not draining |
| `/healthz` | The external uptime check |

## Settings infra sets

| Variable | Value on k3s | Why |
|---|---|---|
| `PRIVATE_MESSENGER_ENV` | `production` | Unset also means production |
| `PRIVATE_MESSENGER_PUBLIC_ORIGIN` | `https://<permanent host>` | Account recovery and automatic backups stay off without it. Clients bind device identity to this host: pick it once |
| `PRIVATE_MESSENGER_TRUSTED_PROXIES` | `10.42.0.0/16` | k3s's pod network. If wrong, every user shares one rate limit |
| `PRIVATE_MESSENGER_LOG_FORMAT` | `json` | One JSON object per line; no message text, bodies, tokens or secrets |
| `PRIVATE_MESSENGER_LIMIT_INSTANCE_STORAGE_MIB` | volume MiB × 0.9 / (`PRIVATE_MESSENGER_BACKUP_KEEP` + 3): 3686 for 40Gi, 184 for 2Gi | local-path volumes report the node's disk, so it cannot be derived. Change it with the volume size. The account limit (512 by default) follows a smaller value |
| `GOMEMLIMIT` | About 75% of `limits.memory` | Argon2id sign-ins hold up to 192 MiB at once |
| `PRIVATE_MESSENGER_ENABLE_METRICS`, `PRIVATE_MESSENGER_MANAGEMENT_ADDR` | `1`, `$(POD_IP):9090` | `POD_IP` from the downward API; production refuses a public or wildcard address |
| `PRIVATE_MESSENGER_SETUP_TOKEN_FILE` | `/run/secrets/veritra/setup-token` | Only until the owner account exists; then remove the key and the variable |
| `PRIVATE_MESSENGER_PASSKEYS` | unset (off) | Stays off until Veritra has its final domain (handbook OWN-07) |

Every other variable, with its default, is in
[`server/config.example.env`](server/config.example.env) and operations.md.
Push providers (VAPID, FCM, APNs) and TURN are optional; without them the
server starts and that feature is off.

**Measured** on the 2026-11-12 rehearsal: 26 MB steady, 308 MB with eight
sign-ups at once. Infra runs 64Mi / 512Mi with `GOMEMLIMIT` 384MiB, as the
handbook suggests; Compose and systemd keep 1 GiB and 768MiB for
self-hosters. Writes are refused while the data volume's file system has
less free space than the smaller of 5% and 2 GiB. On local-path that file
system is the node's one disk, shared with every app, so the disk alert must
fire well before that.

**Disk**, for the handbook's budget of the node's one disk (infra
`apps/veritra/base`): per environment, a 40Gi data volume (database,
encrypted blobs and the seven local backups). local-path does not enforce
it, so `PRIVATE_MESSENGER_LIMIT_INSTANCE_STORAGE_MIB` 3686 keeps the server's
stored content to about 90% of it at the peak of a backup run. On top, up to
20Gi of scratch (`emptyDir` on the node's disk) only while the R2 restore
drill (monthly), `restore-drill-now` or `restore` runs; it holds two copies
of one backup, so it uses about twice the live data. Budget production at
40 GiB standing plus 20 GiB during a drill or restore. Staging has the same
claim but holds only what a test writes, is usually at 0 replicas, and its
CronJobs are suspended; its `restore-drill-now` takes the same 20Gi of
scratch while it runs.

## Secrets and accounts

| Secret | Keys |
|---|---|
| `veritra-secrets` (files in `/run/secrets/veritra`) | `setup-token` (remove after setup); optional `vapid-private-key`, `fcm-private-key`, `apns-private-key`, `turn-shared-secret` |
| `veritra-r2` (backup and drill jobs only) | `rclone.conf` with an R2 token for this one bucket, object read and write only |

Accounts and keys only Veritra needs: a DNS-only record for its host, an R2
bucket with a lock, and optionally FCM, APNs, a VAPID key pair and a TURN
server. The certificate comes from infra's `letsencrypt-production` issuer.

## Ingress

- DNS-only: no `cloudflare-only` middleware and no origin-pull TLS option.
- Traefik's read **and** write timeouts (`respondingTimeouts.readTimeout`
  and `writeTimeout` on the websecure entrypoint) must exceed the server's
  15-minute transfer deadline; 15 minutes is not enough. The read side
  covers uploads, the write side attachment and backup downloads. The owner
  set both to 20 minutes for the whole entrypoint (2026-11-21, handbook
  INF-14 and CHK-INF-3). At 60 s (Traefik's read default, and infra's first
  setting for both), every upload or slow download is cut at 60 s.
- No Buffering middleware: bodies up to 100 MiB stream through, and the
  server enforces its own caps. Keep the `Host` header.

## Release

`scripts/release-image.sh` (add `--no-push` for a dry run) checks, scans,
builds from the committed tree, smoke-tests, pushes, and prints:

```
revision: <full commit>
image:    ghcr.io/servesyourice/veritra@sha256:<digest>
digest:   sha256:<digest>
```

It never writes into infra. Put the digest into the environment's release
file there and commit it as `veritra <env>: <revision[:12]>`. Veritra has
no `APP_REVISION`: the commit is linked into the binary and the image's OCI
label, and `security_posture` logs it.

Hosted CI is allowed for Veritra on every platform (owner decision
2026-11-21, handbook). On a `v*` tag, `.github/workflows/release.yml` also
builds a multi-platform image with CI provenance attestation, but only once
the production release gates pass (`scripts/release-readiness.sh`: signed
mobile evidence G24 and the independent review G25), so today it cannot
publish. Until then the local command above is the only source of a digest,
for staging and rehearsals. Which of the two images production pins once
both exist is the owner's decision.

## Staging checks

After a release lands, before promoting the same digest:

1. `https://<host>/readyz` and `/healthz` answer 200.
2. The pod's first log lines: `security_posture` names the released commit;
   `admission_limits` shows the expected `instance_storage_mib`.
3. An upload and an attachment download that each take longer than 60 s
   finish.
4. Two clients on different networks are rate-limited separately.
5. The collector scrapes `veritra_*` metrics.
6. A backup and a restore drill from R2 have passed (admin runs below).

## Admin commands

`messenger-server <command>`: `serve`, `migrate`, `doctor`, `healthcheck`,
`version`, `backup`, `scheduled-backup`, `verify-backup <path>`,
`restore <path>`, `reset-owner-password --account <name> --password-file
<file>`, `generate-setup-token`.

In the owner's cluster none of them is run by hand:

- **Periodic:** infra's CronJobs: `scheduled-backup` and the copy to R2
  daily at 03:15 UTC, the restore drill from R2 on the 1st at 04:45 UTC.
  Both are suspended in staging, which is usually at 0 replicas.
- **One-off:** admin runs defined in infra under
  `apps/veritra/base/ops/<command>` (infra `docs/admin-runs.md`):
  `backup-now`, `restore-drill-now` and `restore`. A restore refuses to run
  while the server holds the database, so scale the server to 0 through Git
  first.
- `reset-owner-password` has no admin run yet: it reads the new password
  from a file, which in the cluster means a password in a Git-held secret.
  That is the owner's decision.
- `generate-setup-token` prints a secret: run it on the PC, never as an
  admin run, since logs leave the cluster.

operations.md describes the same procedures for other self-hosters, in
whatever way their cluster runs them.
