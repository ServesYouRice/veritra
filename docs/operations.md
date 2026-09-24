# Production operations

Veritra supports one server process and one local data directory. The server
rejects a second writer with `.veritra-server.lock`. If startup reports a stale
lock after a hard crash, verify that no Veritra process uses the directory
before removing it.

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

Shutdown marks `/readyz` unavailable first, closes realtime connections, lets
active HTTP uploads finish within the server's 25-second shutdown deadline,
and then closes storage. Clients recover missed realtime events through durable
sync.

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
identifiers.

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
