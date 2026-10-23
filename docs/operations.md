# Production operations

Veritra supports one server process and one local data directory. The server
rejects a second writer with an OS lock on `.veritra-server.lock`. The kernel
releases it if the process dies (SIGKILL, OOM, node loss), so a leftover file
never blocks a restart; do not delete it by hand. Keep the data directory on
local disk or a block volume (flock is unreliable on NFS/SMB). Backup
verification stages its restore drill under `.veritra-restore-drill/` in the
data directory, so no `/tmp` is needed; leave room for one extra restored
copy and keep that folder out of external backups.

## First setup and secret rotation

Set `PRIVATE_MESSENGER_ENV=production` and generate a 32-byte base64url
`PRIVATE_MESSENGER_SETUP_TOKEN` with `messenger-server generate-setup-token`.
Place it in the root-readable environment file before the first start. Complete owner setup, remove the token, and restart. A fresh
production database fails closed without the token; an initialized database no
longer needs or retains this one-time capability.

Rotate the owner password through the authenticated client. For offline owner
recovery, stop the server and use `reset-owner-password --account ...
--password-file ...` with a mode-0600 password file. Rotating VAPID keys
requires clients to register new push subscriptions; never place private keys
in command arguments or logs.

New password hashes are Argon2id (64 MiB, 2 passes, 1 lane), stored as
self-describing PHC strings. Existing bcrypt hashes keep working, and each one
is replaced by an Argon2id hash after that account's next fully successful
sign-in or reauthentication; plaintext is never stored or logged. At most three
hashes run at once (one reserved for signed-in users), so a sign-in burst holds
about 192 MiB of hash buffers; set `GOMEMLIMIT` (for example 768MiB in a 1 GiB
container) so the Go runtime reclaims them promptly.
`PRIVATE_MESSENGER_BCRYPT_COST` (10 through 15) now only sets the cost of the
timing-equalising bcrypt comparison while bcrypt hashes remain; match it to
the cost your existing hashes use. Measurements:
`testing/evidence/T37C-password-sessions.md`.

Sessions end after `PRIVATE_MESSENGER_SESSION_IDLE_DAYS` (default 14) without
use, or `PRIVATE_MESSENGER_SESSION_ABSOLUTE_DAYS` (default 30) after the last
password and device-secret check, whichever comes first. Reauthenticating
rotates the session token; the old token works for two more minutes so
requests in flight finish, without recent-auth rights. Sign-out, password
change, sign-out of other devices and device removal revoke both tokens.

Recovery download capabilities are sent only in the `X-Recovery-Token` request
header to `GET /api/v1/recovery`; they are never URL credentials. Each new
backup rotates the previous capability, and an approved transfer expires after
15 minutes or is consumed after its final byte. If a capability may have been
exposed, immediately upload a fresh backup (which invalidates the old one),
then purge application, container and reverse-proxy logs covering the exposure
window according to the host's retention tooling. Do not copy the capability
into tickets, shell history or diagnostic bundles.

Native FCM and APNs use the matching `PRIVATE_MESSENGER_FCM_*` and
`PRIVATE_MESSENGER_APNS_*` environment secrets. Push payloads are fixed generic
wake events. Calls require a self-hosted coturn-compatible shared secret via
`PRIVATE_MESSENGER_TURN_URLS` and `PRIVATE_MESSENGER_TURN_SHARED_SECRET`; TURN
relays see DTLS-SRTP ciphertext, not call media plaintext.

## Mobile first-run connection

The mobile connect flow starts with an empty server origin and accepts HTTPS
only. It probes `GET /api/v1/setup/status` before showing the next action:
fresh instances offer owner setup, initialized instances offer sign-in when
the local device identity matches that origin, and otherwise offer invite
registration with device linking available under “Other ways to connect”.
DNS, timeout, TLS, wrong-server and unreachable results are shown as separate
recoverable states. The client never accepts a cleartext exception or trusts a
QR/deep-link origin without explicit confirmation and a successful probe.

For a public server, use the Compose+Caddy profile or another reverse proxy
with a trusted certificate. For a private LAN server, Caddy's `tls internal`
mode is the supported direction; install the corresponding CA certificate on
the device. iOS also declares local-network usage so the OS can present its
LAN permission prompt.

**Demo builds only (D11, D12).** `mobile/lib/main_demo.dart`, built with
`--dart-define=VERITRA_DEMO=true`, also accepts plain `http://` for loopback
hosts (`localhost`, `127.0.0.0/8`, `::1`) so it can reach
`scripts/demo.sh`. Every other host still needs HTTPS, QR origins stay
HTTPS-only, and release builds (`main.dart`) never accept cleartext. See
[demo.md](demo.md).

## Credential abuse controls

The per-source limiter allows 240 general requests/minute, 10 credential
requests/minute (including login and reauthentication), and 5 enrollment
requests/minute. IPv6 sources are grouped by /64. Login and reauthentication
also use bounded account, source/device and session backoff scopes: the first
two failures are unauthorized responses, the third starts a 1-second delay that
progresses to 60 seconds, and entries expire after 15 minutes. The controls
evict under bounded-table pressure and sweep expired state; they do not expose
usernames, addresses, device IDs or tokens in metrics. Monitor
`veritra_rate_limit_buckets`, `veritra_rate_limit_evictions_total`,
`veritra_login_backoff_entries` and
`veritra_login_backoff_evictions_total` as aggregate pressure signals.
Sessions enforce a 30-day idle limit and a 30-day absolute lifetime using
server-side last-use state. Token rotation is deferred until the client/server
refresh exchange is idempotent; logout, device revocation, password change and
offline owner reset still revoke sessions immediately.

## Account export

`GET /api/v1/account/export` requires a password-authenticated session within
the previous five minutes. It returns manifest `v2` pages containing account
and device metadata, protocol/public key material, operational metadata, and
message envelopes. Message bodies are exported as their stored ciphertext and
are never decrypted by the server; JSON byte fields use standard base64 (and
the reaction/key-package fields use their documented hex representation).
Attachment and backup entries contain ciphertext hashes, sizes and crypto
metadata, not server blob bytes. Push subscription exports retain endpoint
metadata needed for portability but omit the reusable `auth_secret`; bearer,
session and recovery capabilities are never export fields. Server audit history
is intentionally excluded; the export audit record contains only fixed schema
and scope metadata. The mobile client writes the bounded pages to a local
`veritra-account-export-v2-*.json` file without logging its contents.

## Upgrade and rollback

1. Run a completed backup and copy its whole directory off-host.
2. Stop the service and verify the server process exited.
3. Install the pinned release artifact or container, then start one replica.
4. Require `/readyz` to return 200 before sending traffic.
5. If rollback crosses an incompatible migration, stop the server, restore the
   matching pre-upgrade backup, and reinstall its matching binary.

Shutdown fits a 25-second budget, below the 30-second stop grace of the
supported Compose service (`stop_grace_period`) and systemd unit
(`TimeoutStopSec`); keep both above 25 seconds if you change them. It marks
`/readyz` unavailable, closes realtime connections, and gives in-flight HTTP
requests, uploads included, 18 seconds to finish. Connections still busy are
then closed, their handlers get the rest of the budget to clean up partial
blobs, and only then is storage closed. Transfers keep their 15-minute route
deadline while the server runs; one cut off by shutdown is retried by the
client after restart. Clients recover missed realtime events through durable
sync.

## Supported deployment profile

**Artifact.** `deploy/docker-compose.yml` runs only the released image, by
digest. Download the release's `container-image-digest.txt`, verify it with
`gh attestation verify container-image-digest.txt --repo <owner>/<repo>`, and
set `VERITRA_IMAGE` to its line (`ghcr.io/<owner>/<repo>:<tag>@sha256:<digest>`).
Compose refuses to start without it. A tag without `@sha256:` is mutable and
unsupported. `deploy/docker-compose.build.yml` builds from a checkout for
development and CI only. For systemd, install the release binary checked
against `SHA256SUMS` and its attestation.

**Hardening.** The Compose services run as uid 65532 with a read-only root
filesystem, all capabilities dropped, `no-new-privileges` and a small
in-memory `/tmp`. The data volume is the only writable application path. The
backup service keeps its restore-drill scratch on that volume and has no
network; its `/offsite` mount must be
writable by uid 65532. Caddy keeps only `NET_BIND_SERVICE`. The systemd units
use `ProtectSystem=strict` with the state directory as the only
`ReadWritePaths`, an empty capability set, private `/tmp` and devices, and a
`@system-service` syscall filter. Add a `ReadWritePaths=` line for an
off-host backup mount or an overridden database or blob directory.

**Secrets.** `PRIVATE_MESSENGER_SETUP_TOKEN`, `_VAPID_PRIVATE_KEY`,
`_FCM_PRIVATE_KEY`, `_APNS_PRIVATE_KEY` and `_TURN_SHARED_SECRET` each accept
a `_FILE` variant naming a file that holds the value (at most 64 KiB; one
trailing newline is ignored). Setting both forms is an error. Errors name the
setting and path, never the value, and the server's config output redacts
secrets. Compose forwards only the `_FILE` variables (plus the one-time setup
token): put each secret in its own file in `VERITRA_SECRETS_DIR` (default
`deploy/secrets`, mounted read-only at `/run/secrets`), owned by uid 65532
with mode 0400, and set for example
`PRIVATE_MESSENGER_TURN_SHARED_SECRET_FILE=/run/secrets/turn_shared_secret`.
Under systemd, prefer `LoadCredential=` with `..._FILE=%d/<name>`, as shown in
the unit.

**Storage ownership.** Storage commands resolve the data directory,
`PRIVATE_MESSENGER_DB_PATH` and `PRIVATE_MESSENGER_STORAGE_PATH` to absolute
paths with symlinks resolved. They refuse layouts where the blob directory is,
or contains, the data directory or the database, or where either overlaps the
data directory's `backups/`. Besides `.veritra-server.lock` in the data
directory, `serve` holds OS locks on `<database>.veritra-server.lock` and
`<blob dir>/.veritra-server.lock`, so two data directories cannot share one
database or blob directory. These two locks are released by the OS when the
process exits and never go stale.

## Release image

`scripts/release-image.sh` is the one local release command (no hosted CI).
It refuses a dirty tree; runs gofmt, go vet, the server tests, govulncheck
and `scripts/audit-rust.sh`; builds `server/Dockerfile` from `git archive
HEAD` (only committed files reach the build); scans the image with Trivy and
stops on any HIGH or CRITICAL finding or embedded secret; pushes
`ghcr.io/servesyourice/veritra:<commit>`; and prints the digest. With
`--infra-dir <folder>` it also writes that digest into the folder's
`kustomization.yaml` and commits it there; push the infra repository to
deploy. Log in first with `docker login ghcr.io`. It needs bash, git, Go,
cargo-audit, Docker with buildx and Trivy; on Windows run it from WSL (or Git
Bash with Docker Desktop). `--no-push` builds and scans only.


## Kubernetes (k3s)

`deploy/kubernetes/base` is a kustomize base for a single-node k3s cluster
managed by Flux from a separate infra repository; `examples/overlay` shows
the overlay that sets the image digest, hostname, settings and secret files.
The base holds:

- namespace `veritra` with Pod Security `restricted` enforced, and a service
  account with no token mounted;
- one `veritra-data` volume (ReadWriteOnce, node-local; SQLite must not sit
  on NFS) sized for the data plus seven backups;
- one Deployment replica with `strategy: Recreate`, so the old pod stops
  before the new one starts (expect a short outage per deploy; clients
  reconnect); `/livez`, `/readyz` probes; non-root, read-only root, all
  capabilities dropped, seccomp `RuntimeDefault`;
- a Traefik `IngressRoute` with an HSTS headers middleware and a cert-manager
  `Certificate` (Cloudflare DNS-01, so the DNS-only hostname works);
- default-deny network policies that admit only Traefik to the server, DNS,
  HTTPS to public addresses for push providers, and HTTPS for the R2 jobs;
- the backup and restore-drill CronJobs described below.

Cluster-wide pieces live in infra; `examples/` has one of each:
`traefik-helmchartconfig.yaml` raises the websecure read timeout to 16
minutes (Traefik v3 defaults to 60s, which cuts uploads), redirects HTTP to
HTTPS and sets `externalTrafficPolicy: Local` so Traefik sees real client
addresses; `cluster-issuer.yaml`; `secrets.example.yaml` (encrypt with SOPS).
Traefik streams bodies without a size limit and keeps the `Host` header; the
server enforces its own 100 MiB cap.

`PRIVATE_MESSENGER_TRUSTED_PROXIES` is `10.42.0.0/16`, k3s's default pod
network; change it if the cluster uses another `--cluster-cidr`. If it, or
the client address reaching Traefik, is wrong, all users share one rate
limit. After the first deploy, check that two clients on different networks
are limited separately.


## TLS on a LAN install

The app has no custom trust, no trust-on-first-use and no way to skip TLS checks, so a LAN server needs a certificate the phone already trusts.

1. **Recommended: a real certificate through DNS-01.** Use a hostname in a domain you own (for example `chat.home.example.com`), point it at the server's LAN address in local DNS (or a public record to the private IP), and get a public CA certificate with a DNS-01 challenge: Caddy with a DNS provider plugin, or a cert-manager `ClusterIssuer` with a DNS-01 solver. The server does not need to be reachable from the internet. Raw IP addresses and `.local` names are not supported.
2. **Your own CA in the OS trust store.** Issue the server certificate from a private CA (`step-ca`, `mkcert`); the device owner installs the CA. iOS: install the profile, then enable full trust in Certificate Trust Settings. Android 7+ does not trust user-added CAs for apps, so use option 1 on Android unless the CA is installed as a system CA by device management.

Never use self-signed leaf certificates, or plain HTTP outside loopback demo builds.


## Off-host backups in R2

The `veritra-backup` CronJob runs daily at 03:15 UTC on the server's node.
Its first container runs `scheduled-backup` (backup, restore drill, keep 7)
next to the live server; that is safe because the copy uses SQLite's
`VACUUM INTO` and takes no server lock. A second container, rclone pinned by
digest, then copies completed `veritra-*` backups to R2 with `--checksum`
(MD5 verified on upload) and `--immutable`. Veritra itself has no S3 code or
R2 credentials; only rclone reads the `veritra-r2` secret, and it mounts the
data volume read-only. rclone copies and never deletes, so set an R2
lifecycle rule to expire old copies and a bucket lock shorter than that rule.
Use an R2 token limited to that one bucket's objects.

The `veritra-restore-drill` CronJob runs monthly (or on demand with
`kubectl -n veritra create job --from=cronjob/veritra-restore-drill veritra-restore-drill-manual-1`; keep the `veritra-restore-drill-` prefix so a failure alerts):
it downloads the newest R2 backup into scratch space and runs
`verify-backup` on it. A failed Job is a failed drill; alert on it, and on a
failed backup Job. Run the drill once before the server holds real
conversations. For a real restore, use `examples/restore-job.yaml`: suspend
Flux, scale the server to zero, restore a named backup into the volume, then
scale back up.

## Monitoring and alerts

Metrics are off by default. `PRIVATE_MESSENGER_ENABLE_METRICS=1` serves
`/metrics` on `PRIVATE_MESSENGER_MANAGEMENT_ADDR` (default `127.0.0.1:9090`;
production accepts only a loopback or private IP). They hold aggregate counts
and ages only, never users, accounts, conversations, devices, tokens or
endpoints.

**Kubernetes.** `deploy/kubernetes/examples/monitoring` is a kustomize
component (the example overlay includes it): it binds the listener to the
pod IP, adds a headless `veritra-metrics` Service and lets only the
`monitoring` namespace reach port 9090. Scrape it with `servicemonitor.yaml`
(Prometheus Operator) or `scrape-config.yml` (Grafana Alloy, plain
Prometheus); keep `job="veritra-metrics"`. Load the rules as
`prometheus-rules.yaml` or, for Grafana Cloud, `mimirtool rules load
veritra-alerts.rules.yml`. They also need kube-state-metrics, cert-manager's
metrics and node-exporter.

| Alert | Means | First thing to do |
|---|---|---|
| `VeritraBackupStale` (critical) | No verified backup for 26 h | `kubectl -n veritra get jobs`; read the newest `veritra-backup` Job's `scheduled-backup` log |
| `VeritraBackupNeverSucceeded` (critical) | No verified backup since install | Run the backup Job by hand: `kubectl -n veritra create job --from=cronjob/veritra-backup backup-now` |
| `VeritraBackupFailing` (warning) | The last backup run(s) failed | `last_failure_step` in `<data dir>/backup-status.json` names the step (backup, verify, ...); check disk space first |
| `VeritraBackupJobFailed` (warning) | A backup Job failed, including the copy to R2 | Read the `copy-to-r2` log; check the R2 token and bucket lock |
| `VeritraRestoreDrillFailed` (critical) | The monthly R2 restore drill failed | Read both container logs; rerun the drill. Treat off-host backups as unproven until it passes |
| `VeritraServerDown` (critical) | Metrics not scraped for 5 min | `kubectl -n veritra get pods`; check the pod, then the NetworkPolicy and collector |
| `VeritraServerNotReady` (critical) | No ready server pod for 5 min | `kubectl -n veritra describe pod`; `/readyz` fails when storage is unhealthy |
| `VeritraCertificateExpiringSoon` (warning) | Certificate expires in under 14 days | `kubectl -n veritra describe certificate veritra`; check the Cloudflare DNS-01 token |
| `VeritraVolumeFilling`, `VeritraNodeDiskFilling` (warning) | Data volume or node disk over 80% | Grow the volume or disk; lowering `PRIVATE_MESSENGER_BACKUP_KEEP` frees the most |

A failed Job keeps its alert firing until the Job is deleted
(`kubectl -n veritra delete job <name>`); do that once the cause is fixed. A
drill started by hand counts only if its name starts with
`veritra-restore-drill-`. k3s `local-path` volumes report no kubelet volume
stats, so there `VeritraNodeDiskFilling` is the disk alert.

**External uptime check.** Monitor `https://<host>/healthz` from outside
(UptimeRobot free tier, HTTP(S) monitor, 5-minute interval, alert on any
non-200). It covers DNS, Traefik and TLS, which in-cluster checks cannot.

**Compose and systemd.** Without Prometheus, a cron job is enough; cron
mails any output. Under systemd, set `PRIVATE_MESSENGER_ENABLE_METRICS=1` in
the env file:

```sh
#!/bin/sh
# */10 * * * * /usr/local/bin/veritra-check
curl -fsS -o /dev/null https://chat.example.org/healthz || echo "veritra: healthz failed"
age=$(curl -fsS http://127.0.0.1:9090/metrics | awk '$1=="veritra_backup_last_success_age_seconds"{print $2}')
[ "${age:--1}" -ge 0 ] && [ "$age" -le 93600 ] || echo "veritra: backup age ${age:-unknown}"
```

Under Compose the metrics listener stays inside the container; check
`docker compose ps` health (it runs `messenger-server healthcheck`) and the
backup's exit status: `docker compose --profile backup run --rm backup ||
echo "veritra: backup failed"`.

## Retention capacity

The retention sweeper drains expired messages, calls, operational rows and
blob-deletion work in batches of 500, yielding between batches and stopping
after 64 batches or 10 seconds per class. Monitor
`veritra_retention_backlog_rows` and
`veritra_retention_oldest_age_seconds`; investigate a backlog that remains
above 1,200 rows or an oldest age above one sweep interval after two sweeps.
The metrics contain aggregate counts and ages only.

## Push providers

Configure only the providers you can operate. Clients register with what
`/api/v1/push/config` offers: Android prefers FCM when both the server and the
app build carry FCM settings and falls back to UnifiedPush (Web Push, the only
provider that needs VAPID keys); iOS uses APNs. APNs accepts Apple's `.p8`
(PKCS #8) key. A device registered with one provider is retired from the
others. In the app, Settings → Notifications → "Send a test notification"
sends the ordinary generic wake to that device only (at most once a minute);
use it for the G24 wake matrix. Notifications show one fixed sentence, never
message text, sender or conversation.

## Push wake capacity

Message acceptance queues only generic wake routing work; it never queues
ciphertext, message text or push secrets. Each provider has one bounded worker
that claims at most 64 jobs and sends at most 8 concurrently. Each provider
send has a 10-second deadline, a 30-second lease, jittered retry backoff and a
24-hour maximum job age. Leases are reclaimed after restart. Monitor
`veritra_push_deliveries_total{provider,result}` and
`veritra_push_backlog_jobs{provider}`; provider labels are limited to the
supported provider names and contain no account, device, endpoint or event
identifiers. `delivered` means the provider accepted the wake; `abandoned`
means the job was dropped for good (its subscription is gone or retired);
`failed` means the job stays queued and is tried again. A job whose removal
fails after delivery is sent again after its lease, which only makes the
device sync once more.

## Scheduled backups

`messenger-server scheduled-backup` is the supported backup job. One run:

1. writes a backup to `<data dir>/backups/veritra-<UTC time>`;
2. proves it with a disposable restore drill (restore into a scratch
   directory, migrate, check); a backup is not a success until this passes;
3. copies it to `PRIVATE_MESSENGER_BACKUP_OFFSITE_DIR`, verifies every file
   there against the manifest, and only then publishes it under its name;
4. keeps the newest `PRIVATE_MESSENGER_BACKUP_KEEP` (default 7) scheduled
   backups in each place. Nothing else in those directories is removed.

The off-host directory is a mount from separately controlled storage (NFS,
SMB, an rclone or restic mount). Its credentials live in that mount's own
configuration, so none pass through the server's environment or logs. Run the
job daily with `deploy/systemd/private-messenger-backup.timer`, or with
`docker compose --profile backup run --rm backup` from the host scheduler.

Recovery objectives: with the daily timer the recovery point is at most 24
hours (plus the timer's 15-minute jitter); the recovery time is the restore
below plus a server start, usually minutes for a single node. Alert when
`veritra_backup_last_success_age_seconds` is above 93,600 (26 hours) or `-1`
(no verified backup yet), or when `veritra_backup_consecutive_failures` is
above zero (see [Monitoring and alerts](#monitoring-and-alerts)). The metrics and `<data dir>/backup-status.json` hold times, a
failure step and a count only.

`messenger-server verify-backup <path>` runs the same restore drill on any
backup, for example on the off-host copy from a clean host.

Downloads verify each 64 KiB chunk of an encrypted blob before sending it,
so damage in a part nobody requests is not noticed by downloads. The backup
job hashes every blob in full and fails on a mismatch: a passing daily backup
is also the full blob check. A damaged blob logs `blob_integrity_failed`.

## Restore safety

`restore` copies and verifies the backup into a private staging directory
before it touches anything live, checks free space first, and refuses to run
while the server holds the database. It then writes
`.veritra-restore-journal.json` next to the database and moves the live
database (with its `-wal`/`-shm` files) and blob directory aside under
`.pre-restore-<time>-<random>` names. If the process dies part-way, the next
`serve`, `migrate`, `backup`, `restore` or `doctor` settles it: an unfinished
restore is rolled back to the previous instance, a finished one is kept. A
damaged journal, or one naming other paths, stops startup until an operator
resolves it. Staging directories are removed only when they carry the
`.veritra-staging` marker that this tool writes, so no other path is ever
cleaned. A migration applies its SQL and its `schema_migrations` record in one
transaction; a failing migration leaves the database as it was. Rolling back
across an incompatible migration means restoring the matching backup, never a
hand-written down migration.

## Off-host restore drill

Run `messenger-server backup /secure-staging/veritra-YYYYMMDD`, then copy the
completed directory to separately controlled off-host storage. Never copy its
temporary sibling. On a clean drill host with an empty data directory:

```sh
messenger-server restore /mnt/off-host/veritra-YYYYMMDD
messenger-server doctor
messenger-server serve
```

Verify `/readyz`, owner login, conversation metadata, and encrypted attachment
download authorization. Do not inspect or log ciphertext bodies during the
drill. Destroy the isolated drill data according to the operator's retention
policy after recording the date and result.
