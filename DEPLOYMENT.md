# Deployment facts for infra

What the owner's `infra` repository cannot read from its own files, as the
handbook asks of every app (`new-projects.md`). `infra` and the handbook win
over this page. Everything else, for any self-hoster, is in
[`docs/operations.md`](docs/operations.md).

## Process

- One image, `ghcr.io/servesyourice/veritra`, entry point
  `messenger-server`, default command `serve`. It runs as uid 65532 on a
  read-only root and writes only to `/data` and `/tmp`.
- **Exactly one copy.** The server refuses a second writer on its data
  directory, so the Deployment has one replica and `strategy: Recreate`.
  Expect a short outage per deploy; clients reconnect and resync.
- **No migration Job.** `serve` migrates at start under the same lock, so a
  Job would find the old pod holding it and Flux would never retry it
  (2026-11-12 rehearsal). One Flux entry per environment, with no `-migrate`
  entry; its timeout covers the Recreate stop (up to 40 s) and the startup
  probe (up to 300 s).
- **Rollback** is reverting the release commit. The older binary's migrate
  step leaves newer migrations alone
  (`TestOlderBinaryMigrateIsANoOpOnANewerSchema`); across a migration the old
  code cannot use, restore the matching backup instead (operations.md,
  "Upgrade and rollback").

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
| `PRIVATE_MESSENGER_ENABLE_METRICS`, `PRIVATE_MESSENGER_MANAGEMENT_ADDR` | `1`, `$(POD_IP):9090` | From `deploy/kubernetes/examples/monitoring` |
| `PRIVATE_MESSENGER_SETUP_TOKEN_FILE` | `/run/secrets/veritra/setup-token` | Only until the owner account exists; then remove the key and the variable |
| `PRIVATE_MESSENGER_PASSKEYS` | unset (off) | Stays off until Veritra has its final domain (handbook OWN-07) |

Every other variable, with its default, is in
[`server/config.example.env`](server/config.example.env) and operations.md.
Push providers (VAPID, FCM, APNs) and TURN are optional; without them the
server starts and that feature is off.

**Measured** on the 2026-11-12 rehearsal: 26 MB steady, 308 MB with eight
sign-ups at once. The handbook's suggestion for infra is 64Mi / 512Mi with
`GOMEMLIMIT` 384MiB; `deploy/kubernetes/base` keeps 1Gi and 768MiB for
self-hosters. Writes are refused while the data volume's file system has
less free space than the smaller of 5% and 2 GiB. On local-path that file
system is the node's one disk, shared with every app, so the disk alert must
fire well before that.

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
- Traefik's read timeout must exceed the server's 15-minute transfer
  deadline (16 minutes in `examples/traefik-helmchartconfig.yaml`). With
  infra's 60 s, every upload is cut at 60 s (handbook INF-14).
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
file there and commit it as `veritra <env>: <revision[:12]>`.

## Staging checks

After a release lands, before promoting the same digest:

1. `https://<host>/readyz` and `/healthz` answer 200.
2. The pod's first log lines: `security_posture` names the released commit;
   `admission_limits` shows the expected `instance_storage_mib`.
3. An upload that takes longer than 60 s finishes.
4. Two clients on different networks are rate-limited separately.
5. The collector scrapes `veritra_*` metrics.
6. A backup and a restore drill from R2 have passed (admin runs below).

## Admin commands

`messenger-server <command>`: `serve`, `migrate`, `doctor`, `healthcheck`,
`version`, `backup`, `scheduled-backup`, `verify-backup <path>`,
`restore <path>`, `reset-owner-password --account <name> --password-file
<file>`, `generate-setup-token`.

In the owner's cluster none of them is run by hand:

- **Periodic:** the base's CronJobs: `scheduled-backup` and the copy to R2
  daily at 03:15 UTC, the restore drill from R2 on the 1st at 04:45 UTC.
- **One-off** (back up now, drill now, restore, reset the owner's password):
  admin runs defined in infra under `apps/veritra/base/ops/<command>`
  (infra `docs/admin-runs.md`). A restore refuses to run while the server
  holds the database, so scale the server to 0 through Git first.
- `generate-setup-token` prints a secret: run it on the PC, never as an
  admin run, since logs leave the cluster.

The `kubectl create job`, `kubectl apply` and `flux suspend` steps in
operations.md are for self-hosters who do not follow infra's rules.
