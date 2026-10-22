# Production operations

Veritra supports one server process and one local data directory. The server
rejects a second writer with an OS lock on `.veritra-server.lock`. The kernel
releases it if the process dies (SIGKILL, OOM, node loss), so a leftover file
never blocks a restart; do not delete it by hand. Keep the data directory on
local disk or a block volume (flock is unreliable on NFS/SMB). Backup
verification stages its restore drill under `.veritra-restore-drill/` in the
data directory, so no `/tmp` is needed; leave room for one extra restored
copy and keep that folder out of external backups.

`serve` also locks the real database file and blob directory (symlinks and
relative paths resolved), so two servers whose `PRIVATE_MESSENGER_DB_PATH` or
`PRIVATE_MESSENGER_STORAGE_PATH` overrides meet in one place cannot both
start. A blob directory that contains the database or the data directory is
rejected. These locks are released by the operating system when the process
exits.

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

New password hashes retain the current bcrypt cost 10 by default. Operators
may set `PRIVATE_MESSENGER_BCRYPT_COST` from 10 through 15; successful login
and reauthentication rehash older bcrypt records without retaining plaintext.
Promoting the default to cost 12 is deferred until the auth benchmark is run
on supported deployment hardware and its p50/p95/p99 CPU results are recorded.

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

## Secrets from files

Each secret can be read from a file instead of the environment: set the
variable with a `_FILE` suffix to the file's path and leave the plain one
unset. This works for `PRIVATE_MESSENGER_SETUP_TOKEN`,
`PRIVATE_MESSENGER_VAPID_PRIVATE_KEY`, `PRIVATE_MESSENGER_FCM_PRIVATE_KEY`,
`PRIVATE_MESSENGER_APNS_PRIVATE_KEY` and
`PRIVATE_MESSENGER_TURN_SHARED_SECRET`. Setting both forms, or naming a
missing, empty or larger-than-64-KiB file, stops startup; errors name the
variable, never the value. Use Docker or Kubernetes secrets, or systemd
`LoadCredential=` (see `deploy/systemd/private-messenger.service`), so
secrets stay out of `docker inspect`, process environments and env files.

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
the device. If you own a domain, a DNS-01 certificate (Caddy's DNS plugins,
or cert-manager on Kubernetes) gives a LAN-only hostname a publicly trusted
certificate with no inbound port and no device CA install. iOS also declares local-network usage so the OS can present its
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

Shutdown marks `/readyz` unavailable first, closes realtime connections, lets
active HTTP requests and background workers finish within
`PRIVATE_MESSENGER_SHUTDOWN_TIMEOUT` (default 25s, 5s to 15m), and then
closes storage. Clients recover missed realtime events through durable sync.
Uploads and downloads may run up to 15 minutes, so a transfer still running
at the deadline is cut and must be retried. The supervisor must wait longer
than the timeout: the shipped Compose (`stop_grace_period: 40s`), systemd
(`TimeoutStopSec=40`) and Kubernetes (`terminationGracePeriodSeconds: 40`)
files fit the default. To never cut a transfer, set the timeout to `15m` and
each grace to about `15m15s`; a deploy then waits for the longest transfer.

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

## Docker Compose

`deploy/docker-compose.yml` runs a released image by digest: set
`VERITRA_IMAGE=ghcr.io/servesyourice/veritra@sha256:<digest>` (for
example in `deploy/.env`); it refuses to start without it. The containers run
as UID 65532 with a read-only root filesystem, no capabilities and
`no-new-privileges`; only `/data` (and a small `/tmp`) is writable. To build
from a checkout for development, add the override:
`VERITRA_IMAGE=veritra-server:dev docker compose -f docker-compose.yml -f
docker-compose.build.yml up --build`. That path is never a supported
deployment.

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
`kubectl -n veritra create job --from=cronjob/veritra-restore-drill drill-1`):
it downloads the newest R2 backup into scratch space and runs
`verify-backup` on it. A failed Job is a failed drill; alert on it, and on a
failed backup Job. Run the drill once before the server holds real
conversations. For a real restore, use `examples/restore-job.yaml`: suspend
Flux, scale the server to zero, restore a named backup into the volume, then
scale back up.


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
`veritra_backup_last_success_age_seconds` is above 90,000 (25 hours) or `-1`
(no verified backup yet), or when `veritra_backup_consecutive_failures` is
above zero. The metrics and `<data dir>/backup-status.json` hold times, a
failure step and a count only.

`messenger-server verify-backup <path>` runs the same restore drill on any
backup, for example on the off-host copy from a clean host.

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
