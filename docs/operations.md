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

The per-source limiter allows 240 general requests/minute (requests
without a valid session; see below for signed-in ones), 10 credential
requests/minute (including login and reauthentication), and 5 enrollment
requests/minute. IPv6 sources are grouped by /64.

People behind one router (a household, an office, a carrier NAT) share
one source address. A request with a session token is admitted on that
address's signed-in budget only. Once the token has been looked up, a valid
session is charged to that account's own budget at the address, so people
there do not use up each other's requests. A token that does not resolve
(guessed, expired, revoked) is charged to the address's 240 instead, which
it shares with anonymous requests and credential attempts, as before; past
the 240 such a token is answered 429 rather than 401. The public routes,
which never look a token up (`/livez`, `/healthz`, `/readyz`,
`/api/v1/health`, `/setup`, `/api/v1/setup/status`), always use the 240,
with or without a token: a junk token there buys nothing. A token on a
path with no route is charged to the 240 after its 404, which costs no
more than a 429 would. Credential and enrollment routes
(setup, login, reauthentication, registration, recovery, device-link claim
and claim status, and the setup, registration and device-link enrollment
reservations) always use the address budgets, with or without a token.

| `PRIVATE_MESSENGER_RATE_LIMIT_...` | Default | Range | Counts per minute |
|---|---|---|---|
| `ADDRESS_PER_MINUTE` | 240 | 60-100,000 | requests from one address without a session that resolves, including credential and enrollment routes |
| `ACCOUNT_PER_MINUTE` | 240 | 60-100,000 | requests with a valid session, per account at one address (an account on several networks gets this at each, as before) |
| `SIGNED_IN_ADDRESS_PER_MINUTE` | 1,200 | 60-1,000,000, at least `ACCOUNT_PER_MINUTE` | all requests carrying a session token from one address, valid or not, every account together |

The credential (10) and enrollment (5) budgets are fixed. The trade-offs:

- One address with valid sessions of five or more accounts can send up to
  1,200 signed-in requests a minute instead of 240 in all; a single account
  still gets 240 at an address.
- Anonymous requests and stale tokens cannot refuse the signed-in people
  at an address. A device stuck retrying with an expired session uses up
  the address's 240 (so signed-out neighbours there wait, as with any
  anonymous flood), but neighbours with a valid session keep their own
  budgets. Only the shared signed-in ceiling is common to all of them, and
  tokens that do not resolve count against it too, so a retry loop has to
  send 1,200 requests a minute to refuse its neighbours.
- In return, the number of token lookups from one address is bounded by
  `SIGNED_IN_ADDRESS_PER_MINUTE` (1,200 by default) rather than by the 240:
  past the 240 a bad token is still refused, but after its lookup (one
  indexed read of a token hash). Session tokens are 256-bit random values,
  so this rate does not make guessing feasible; it is a load bound.
  Raising `SIGNED_IN_ADDRESS_PER_MINUTE` for a large office raises it.

Set `SIGNED_IN_ADDRESS_PER_MINUTE` equal to `ACCOUNT_PER_MINUTE` to give a
whole address no more than one account's budget; raise it for a large
office. A refusal is 429 with `Retry-After`;
`veritra_rate_limit_rejections_total` counts it by scope (`general`,
`auth`, `enrollment`, `account`, `signed_in`). Realtime sockets have their
own limits: 10 per account and 3 per device, 20 per address, and for IPv6 a
separate cap on all addresses of one /64 (default 200,
`PRIVATE_MESSENGER_LIMIT_SOCKETS_PER_IPV6_PREFIX`, 20-10,000; an office or home
network hands out many addresses, so the /64 cap is higher than the address
cap). IPv4 clients behind one NAT share their address's 20. The server logs
the resolved values at start (`rate_limits`, `admission_limits`).

Login and reauthentication also use bounded backoff scopes: the first two
failures are unauthorized responses, the third starts a 1-second delay that
progresses to 60 seconds, and entries expire after 15 minutes. A login
counts every failure against its source scope (client address, device and
username). A second scope, username plus device from any address, is counted
and enforced only for a request that presented that device's valid secret,
so someone who only knows a username cannot lock its owner out by failing
logins from elsewhere; for such requests a right and a wrong password look
the same and change nothing else. Whoever holds the device secret is limited
across addresses as before. When the backoff table is full it evicts the
entry with the fewest failures first, so filler identities do not push out
an account that is being guessed. The controls sweep expired state; they do
not expose usernames, addresses, device IDs or tokens in metrics.

Address budgets and per-account budgets are kept in two tables of 65,536
entries each (IPv6 sources count per /64). When a table is full, a new key
first replaces an expired bucket, then the least used live bucket that has
used no credential and no enrollment budget; those two budgets are never
reset before their minute ends. Only if every sampled bucket has used one
does the new key share an overflow bucket, one of 256 chosen by a salted hash
of its network (a /48 for IPv6, a /24 for IPv4), so a network that fills the
table and burns its overflow bucket affects itself and the few networks that
hash alongside it, not everyone's first request. One account seen from many
addresses evicts only other account budgets, never an address's credential
budget. `veritra_rate_limit_buckets` counts both tables.
`veritra_rate_limit_evictions_total` counts each time a new key found its
table full of live buckets, whether it evicted a credential-free bucket or
went to an overflow bucket; it does not count reset credential budgets. A
steady rise means a table is under pressure (an address flood or very many
networks). Monitor `veritra_rate_limit_buckets`,
`veritra_rate_limit_evictions_total`, `veritra_login_backoff_entries` and
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
and scope metadata. Only messages are paged (`limit`, then `before` with the
previous page's `next_before`): the `categories` object comes with the first
page, and later pages carry an empty `categories`, so a full export holds
every category row once. The mobile client writes the bounded pages to a local
`veritra-account-export-v2-*.json` file without logging its contents.

## Upgrade and rollback

1. Run a completed backup and copy its whole directory off-host.
2. Stop the service and verify the server process exited.
3. Install the pinned release artifact or container, then start one replica.
4. Require `/readyz` to return 200 before sending traffic.
5. If rollback crosses an incompatible migration, stop the server, restore the
   matching pre-upgrade backup, and reinstall its matching binary.

Rolling back past the Argon2id change (migration 0032) is special: the older
binary starts and accepts current sessions, but it cannot verify Argon2id
hashes, so anyone who signed in, registered or changed their password after
the upgrade cannot sign in on it. Prefer rolling forward. Otherwise restore the
pre-upgrade backup (later data is lost), or keep the old binary and recover
only the owner with `reset-owner-password`.

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
writable by uid 65532. Caddy keeps only `NET_BIND_SERVICE`; its access and
error logs drop the request URI and every credential header, and it sends
each security header once. The systemd units
use `ProtectSystem=strict` with the state directory as the only
`ReadWritePaths`, an empty capability set, private `/tmp` and devices, and a
`@system-service` syscall filter. Add a `ReadWritePaths=` line for an
off-host backup mount or an overridden database or blob directory.

**Memory.** Every server process has a memory limit and `GOMEMLIMIT` at about
75% of it: 1 GiB and `768MiB` for the server (Compose `mem_limit`, systemd
`MemoryMax`, Kubernetes `limits.memory`), 512 MiB and `384MiB` for the backup,
drill and restore jobs. Each Argon2id login hash takes 64 MiB and up to three
run at once, so without `GOMEMLIMIT` a login burst can reach the limit before
the Go runtime collects. Change the two together;
`TestDeployMemoryLimitsCarryGOMEMLIMIT` checks the pairs.

**TURN URLs.** `PRIVATE_MESSENGER_TURN_URLS` takes RFC 7065 URIs, the form
WebRTC clients parse: `turn:turn.example.com:3478?transport=udp`,
`turns:turn.example.com:5349?transport=tcp`, IPv6 in brackets. A
`turn://host:port` entry is rewritten without the slashes; anything else
stops startup. Point coturn (`use-auth-secret`) at the same shared secret: the
server issues 10-minute credentials (`<expiry>:<account>`, HMAC-SHA1) and
never connects to TURN itself.

**Smoke test.** `scripts/smoke-deploy.sh [--image REF]` runs this hardened
Compose stack (with Caddy on a local `tls internal` copy of the Caddyfile and
a coturn container) and checks owner setup, attachments, a 96 MiB encrypted
backup and its recovery download, WebSocket Host/Origin handling, a Web Push
test wake, TURN credentials on a real relay, the backup job with an off-host
directory, a graceful stop, and a restore into a fresh volume. It fails if a
secret, token, ID or payload prefix appears in the logs, `docker compose
config` or `docker inspect`. Run it before each release; it needs Docker
(Compose 2.24+) and Go, and takes about three minutes. Real push delivery
needs a device and provider keys (G24).

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
stops on any HIGH or CRITICAL finding or embedded secret; runs
`scripts/smoke-deploy.sh` on that exact image (`--skip-smoke` skips it, and
the release record should say so); pushes
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
  capabilities dropped, seccomp `RuntimeDefault`; requests and limits on
  every container, with `GOMEMLIMIT` set (see Memory above);
- the namespace and `veritra-data` volume annotated
  `kustomize.toolkit.fluxcd.io/prune: disabled`, so a file missing from infra
  never makes Flux delete the data (local-path deletes it with the claim);
- a Traefik `IngressRoute` with an HSTS headers middleware and a cert-manager
  `Certificate` (Cloudflare DNS-01, so the DNS-only hostname works);
- default-deny network policies that admit only Traefik to the server, DNS,
  HTTPS to public addresses for push providers, and HTTPS for the R2 jobs;
- the backup and restore-drill CronJobs described below.

Cluster-wide pieces live in infra; `examples/` has one of each:
`traefik-helmchartconfig.yaml` raises the websecure read timeout to 16
minutes, redirects HTTP to HTTPS and sets `externalTrafficPolicy: Local` so
Traefik sees real client addresses; `cluster-issuer.yaml`;
`secrets.example.yaml` (encrypt with SOPS); `flux-kustomization.yaml`. The
timeout matters: in the 2026-10-23 rehearsal a 90-second upload was cut off
at 60 s (HTTP 502) by Traefik's default and completed with this file. With
the Traefik chart k3s bundles, the redirect must sit under `ports.web.http`;
a top-level `ports.web.redirections` is silently ignored.
Traefik streams bodies without a size limit (no Buffering middleware) and
keeps the `Host` header, which the WebSocket Origin check compares; the
server enforces its own caps (50 MiB attachments, 100 MiB backups).

`PRIVATE_MESSENGER_TRUSTED_PROXIES` is `10.42.0.0/16`, k3s's default pod
network; change it if the cluster uses another `--cluster-cidr`. If it, or
the client address reaching Traefik, is wrong, all users share one rate
limit. After the first deploy, check that two clients on different networks
are limited separately.

### Deploying with Flux

`examples/flux-kustomization.yaml` is the one Flux `Kustomization` Veritra
needs. In infra, keep a copy of `deploy/kubernetes/base` taken at the release
commit (`apps/veritra/base`) and the overlay next to it
(`apps/veritra/production`, with `resources: [../base]`), so infra holds
exactly what is applied. `scripts/release-image.sh --infra-dir
apps/veritra/production` writes the tested digest there and commits; pushing
infra deploys. Rolling back is reverting that commit. Secrets
(`veritra-secrets`, `veritra-r2`) are SOPS-encrypted with age in the same
folder; Flux decrypts them with the `sops-age` Secret.

There is no migration Job, unlike the handbook's pattern for other apps. The
server applies its migrations at startup under the single-writer lock (each
migration and its record in one transaction), so a Job using the new image
would find the old pod still holding the lock. On rollback, the older binary
checks the checksums of the migrations it knows and leaves newer ones alone,
so it starts; it works only if those newer migrations were additive. Across
an incompatible migration, restore the matching backup instead (see Restore
safety). The rehearsal's upgrade and rollback used images with the same
schema, so schema skew is untested.

The Kustomization waits for the Deployment and the Certificate with a
10-minute timeout, which covers the Recreate stop (up to 40 s) and the
startup probe (up to 300 s for migrations). While a restore runs, suspend it
(`flux suspend kustomization veritra`) so Flux does not scale the server back
up, and resume it afterwards.


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
data volume read-only. rclone copies and never deletes, so the bucket's own
rules do the expiry and the protection:

- **Bucket:** one bucket for Veritra only (the `offsite` remote points at
  `<bucket>/veritra`, objects land under `veritra/backups/veritra-*`).
- **Lifecycle rule:** delete objects older than 35 days.
- **Bucket lock:** a retention rule of 30 days on the whole bucket, shorter
  than the lifecycle rule so expiry still works. A compromised server can
  then neither delete nor overwrite the last 30 days of backups.
- **Token:** an R2 API token with *Object Read & Write* on this bucket only.
  It cannot change the lock or lifecycle rules (that needs an admin token,
  which never enters the cluster).

Expect about 30 daily copies in R2 against 7 on the volume; size the bucket
for that (R2 is free up to 10 GB, then $0.015 per GB a month).

The `veritra-restore-drill` CronJob runs monthly (or on demand with
`kubectl -n veritra create job --from=cronjob/veritra-restore-drill veritra-restore-drill-manual-1`; keep the `veritra-restore-drill-` prefix so a failure alerts):
it downloads the newest R2 backup into scratch space and runs
`verify-backup` on it. A failed Job is a failed drill; alert on it, and on a
failed backup Job. Run the drill once before the server holds real
conversations. For a real restore, use `examples/restore-job.yaml`: suspend
Flux, scale the server to zero, restore a named backup into the volume, then
scale back up.

**On a rebuilt cluster** (server lost, R2 intact), rehearsed on 2026-10-23
with an S3 stand-in for R2 (`testing/evidence/T46-deploy-smoke.md`):

1. Bootstrap k3s and Flux from infra with the age key; Flux creates the
   namespace, Secrets, an empty volume and the server. With no setup token
   configured (see below) it refuses to start on the empty volume and
   restarts until the restore; that is expected.
2. `flux suspend kustomization veritra`, then
   `kubectl -n veritra scale deployment/veritra --replicas=0` and wait for
   the pod to go.
3. In a copy of `examples/restore-job.yaml`, set the image to the digest
   the server runs and `BACKUP` to the newest name from
   `rclone lsf offsite:backups`; apply it and wait for it to complete. The
   empty database is kept aside under a `.pre-restore-*` name.
4. Delete the Job, scale back to 1, `flux resume kustomization veritra`,
   then check `/readyz`, owner sign-in and an attachment download.

The restored instance keeps the owner, devices, sessions and push
registrations. Once the owner is set up, remove the setup-token key from
`veritra-secrets` and its `PRIVATE_MESSENGER_SETUP_TOKEN_FILE` patch from the
overlay (one without the other stops startup). A rebuilt server then
refuses to start empty instead of offering owner setup before the restore.

## Pre-launch checklist

Before the server holds real conversations. Items marked *owner* need
accounts or decisions only the owner has.

- [ ] *owner* Hostname chosen once (clients bind device identity to it),
  one level under the domain; DNS-only A/AAAA record to the VPS (not
  proxied: uploads exceed the proxy's 100 MB cap, and TLS ends on the VPS).
- [ ] *owner* Cloudflare API token for cert-manager: DNS edit on that one zone.
- [ ] *owner* R2 bucket with the lifecycle rule, the bucket lock and the
  bucket-scoped token above; `veritra-r2` encrypted in infra.
- [ ] *owner* age key in the password manager plus one offline copy;
  `veritra-secrets` (setup token, VAPID/FCM/APNs keys, TURN secret)
  encrypted with SOPS in infra.
- [ ] *owner* GHCR token to push images; a read-only pull secret if the
  package is private.
- [ ] Host: firewall open only for 80, 443 (and TURN, if coturn runs on the
  same VPS); 6443 and 10250 closed, `kubectl` over an SSH tunnel or
  WireGuard; k3s started with `--secrets-encryption`.
- [ ] `scripts/smoke-deploy.sh` passed on the release commit, and
  `scripts/release-image.sh --infra-dir ...` produced the digest in infra.
- [ ] `examples/traefik-helmchartconfig.yaml` applied: the Traefik pod's
  arguments show `readTimeout=16m` and the `web` redirect.
- [ ] `PRIVATE_MESSENGER_TRUSTED_PROXIES` matches the cluster CIDR; two
  clients on different networks are rate-limited separately.
- [ ] Owner set up, then the setup-token key and its `_FILE` patch removed.
- [ ] One backup Job and one restore drill from R2 succeeded
  (`veritra-restore-drill-manual-1`); the full restore above tried once.
- [ ] External uptime check on `https://<host>/healthz`; the alerts from
  [Monitoring and alerts](#monitoring-and-alerts) loaded.
- [ ] *owner* TURN: where coturn runs (host network on the VPS, like
  nextra, or a separate box), its ports and its shared secret.

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

How a provider's refusal is treated:

- Retired (subscription disabled, jobs removed): HTTP 410 from FCM or APNs,
  an FCM error whose `error.details` carry `errorCode` `UNREGISTERED`, an APNs
  reason `Unregistered`. Only the exact fields count, not words found
  anywhere in a body.
- Dropped, subscription kept: APNs `BadDeviceToken` and `DeviceTokenNotForTopic`,
  and an FCM 404 without `UNREGISTERED`. Apple also answers `BadDeviceToken`
  for a valid token sent to the wrong (sandbox or production) environment,
  and a 404 can come from the FCM project, so neither proves the target dead,
  and retrying would be refused again. These jobs count as `abandoned`. A
  subscription refused this way 10 times over more than 24 hours with no
  successful send in between is then retired. That count is in memory: a
  restart only delays retiring a dead target. A persistent `abandoned` rate
  for one provider means a configuration problem (the `Sandbox` environment,
  the bundle ID or the FCM project), not dead devices.
- Retried with backoff until the 24-hour job age: any other failure
  (timeouts, 5xx, 429, authentication).
- An APNs key that is not P-256 is refused at startup; an APNs key and
  `Sandbox` setting apply to every subscription.
- A Web Push endpoint must resolve to a globally routable address: private,
  loopback, link-local, shared address space (100.64.0.0/10), benchmarking,
  documentation and reserved ranges, NAT64 and 6to4 are refused.

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
When the damage is past the first chunk served, the response has already
started and the server breaks the transfer: its `http_request` log line then
carries `outcome=aborted` with the status it had sent, and
`veritra_http_aborted_requests_total` counts it (the request also counts in
the usual totals; a request aborted before its status line has status 0 and
no status class).

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

## Capacity alerts and runbooks

Card I47. Measurements and method: `testing/evidence/T47-capacity.md`.

**Supported host tiers.** One server process, SQLite WAL and blobs on a
local SSD.

| Tier | Container | Volume | Synthetic dataset | Rated busy hour |
|---|---|---|---|---|
| S | 1 vCPU, 1 GiB | 40 GiB (the shipped PVC) | 50 accounts, 25 DMs and 15 groups of 5, 20k messages, 200 attachments | 50 accounts (75 clients) at 4 messages per device per minute, about 3 messages/s |
| M | 2 vCPU, 2 GiB | 100 GiB | 250 accounts, 125 DMs and 75 groups of 5, 100k messages, 1,000 attachments | 250 accounts (375 clients) at 4 messages per device per minute, about 13 messages/s, with a fifth of the devices catching up from deep history |

On tier M, a device that catches up from the middle of a 100k-event history
spends about 10-15 ms per sync page (p99 under 100 ms up to 8 messages per
device per minute); before the T49 cursor follow-up it was 0.1-0.5 s and
missed every step.

"Rated" is half the highest load at which every target below held. The
workload model: every device keeps its sync socket open; sends follow a
Poisson process; one message in 20 carries a 256 KiB attachment (one
attachment in 25 is 25 MiB) that every online recipient downloads; every
realtime event triggers the app's catch-up (`GET /sync/events` until empty);
each device reads its conversation list and one history page every two
minutes; half the accounts have a second client; a fifth of the devices
catch up once from the middle of history, as after a night offline.

**Targets.** Interactive requests (send, sync page, conversation list,
history): p95 ≤ 150 ms and p99 ≤ 500 ms; realtime delivery p99 ≤ 2 s; a
cold catch-up page p99 ≤ 1 s; errors < 0.1% and no 5xx; writer wait p99
≤ 100 ms; Go memory ≤ 50% of the container limit. A stalled push provider
loses no wake job and its backlog drains within 5 minutes of recovery. A
restart is ready within 30 s, loses no acknowledged message, and leased wake
jobs resume after their 30 s lease. The retention backlog stays below 1,200
rows after two sweeps.

**Disk budget.** Each scheduled backup copies every blob, and its restore
drill restores one more copy, so a backup run peaks at about
`(PRIVATE_MESSENGER_BACKUP_KEEP + 3) × live data`. With the default of 7
that is ten times the live data: the 40 GiB volume holds about 3.6 GiB of
live data with 10% free. Lower the keep count or grow the volume before
raising storage quotas.

**Request limits.** Signed-in requests are limited to 240 a minute per
account at one client address, and 1,200 for all accounts at one address
(see [Credential abuse controls](#credential-abuse-controls)). At the S
rating a device and its companion use about 40 together; at four times
that rate one very active account reaches its 240 before the server slows
(`veritra_rate_limit_rejections_total`), but other people behind the same
router keep their own budgets.

**Measure your own host.** `scripts/capacity.sh s load -rate 1,4,8,16`
(also `m`, and the `backup` and `restart` scenarios) runs the server in a
container with the tier's limits, seeds it through the public API with
`server/cmd/veritra-load` and prints the report; add `-duration 2h` for a
soak. `go test -run Scenario ./internal/app` replays a provider stall and a
restart with wake work in flight. Run `promtool test rules
veritra-alerts.test.yml` in `deploy/kubernetes/examples/monitoring` after
changing a rule.

**Metrics added for this contract.** SQLite pool waits and writer wait
(`veritra_sqlite_pool_*`, `veritra_sqlite_writer_acquire_duration_seconds`),
file-system free and size and database, WAL and blob bytes
(`veritra_storage_*`, rounded down to 64 MiB so a size never matches one
upload), the last backup attempt and restore drill, push send duration,
timeouts and oldest queued job, realtime events dropped for a full socket
buffer and refused sockets, rate-limit rejections by scope, retention sweep
time, process start time and Go memory. All are instance-wide; labels come
from fixed sets.

**Hosted metrics.** Below about 20 users, per-route counts, the socket count
and goroutines read as an activity timeline of those people. When metrics
leave the host (Grafana Cloud), send only the series the alerts need: see
the `write_relabel_configs` example in `scrape-config.yml`.

| Alert | Means | First thing to do |
|---|---|---|
| `VeritraRestoreDrillOverdue` (warning) | No passing R2 drill in 35 days, or never | Start one: `kubectl -n veritra create job --from=cronjob/veritra-restore-drill veritra-restore-drill-manual-1` |
| `VeritraLocalRestoreDrillFailed` (critical) | The last backup's restore drill failed | Read the `scheduled-backup` log; run `messenger-server verify-backup` on the newest backup; treat it as unusable |
| `VeritraServerRestarting` (warning) | More than 3 starts in an hour | `kubectl -n veritra describe pod`; look for OOM kills, probe failures, a crash at startup |
| `VeritraServerOOMKilled` (warning) | The container hit its memory limit | Raise `limits.memory` or set `GOMEMLIMIT` to about 70% of it; check `veritra_realtime_connections` and large downloads |
| `VeritraMemoryHigh` (warning) | Go holds over 80% of 1 GiB | As above; the rule's threshold must follow the limit |
| `VeritraHTTPErrorsHigh` (warning) | Over 2% of requests return 5xx | Server log `level=ERROR`/`WARN`; `/readyz`; disk free; then `VeritraWriterSaturated` |
| `VeritraLatencyHigh` (warning) | Interactive p99 over 500 ms | Check CPU throttling and writer wait; compare with the tier rating; a long backup run overlapping the busy hour shows here |
| `VeritraWriterSaturated` (warning) | Requests queue for the single SQLite writer | Look for a long transaction (retention sweep, account export, restore); move the backup schedule off the busy hour; then a bigger tier |
| `VeritraRateLimitStorm` (warning) | Over 5% of requests get 429 | Usually `PRIVATE_MESSENGER_TRUSTED_PROXIES` is wrong and every client shares one address; check two clients on different networks |
| `VeritraPushFailing` (warning) | Most wakes to one provider fail | Provider status page; credentials (`_PRIVATE_KEY_FILE`), clock skew, egress network policy |
| `VeritraPushBacklogStalled` (warning) | Wakes queue for 15 min with none delivered | As above; jobs expire after 24 h, messages are still delivered on the next sync |
| `VeritraRetentionBacklogHigh` (warning) | Over 1,200 expired rows after two sweeps | Server log `retention_prune_failed`; disk errors; run with more sweep time only after finding the cause |
| `VeritraRetentionStalled` (warning) | No finished sweep in 7 h, or rows older than 13 h | The sweeper runs in `serve`; check for a stuck pod or a database lock (`VeritraWriterSaturated`) |
| `VeritraDataDiskLow` (critical) | Under 10% free where the database or blobs live | Free space now: lower `PRIVATE_MESSENGER_BACKUP_KEEP`, delete old local backups, grow the volume; writes fail when it is full |
| `VeritraDataDiskFillsSoon` (warning) | Free space runs out within 3 days at the 24 h trend | Same as above, before it is urgent; check for an upload burst against the quota |
| `VeritraWALLarge` (warning) | The SQLite WAL is over 256 MiB | A long read blocks checkpoints: look for a running export or backup copy; it shrinks after the next checkpoint |

## Admission limits

Card I49 (T49D). Per-account limits bound what one account can make the
instance store or fan out. Each is an environment variable; a value out of
range stops startup, and the server logs the resolved values at start
(`admission_limits`). Defaults come from the tier S measurements in
`testing/evidence/T47-capacity.md`. Stored limits are checked inside the
write transaction, so concurrent requests cannot both take the last slot.

| `PRIVATE_MESSENGER_LIMIT_...` | Default | Range | Counts | Refusal |
|---|---|---|---|---|
| `INSTANCE_STORAGE_MIB` | volume × 0.9 / (backup keep + 3), at most 10,240; 3,686 on the 40 GiB PVC | 64-16,777,216 | encrypted attachments and backups on the instance | 507 `storage_quota_exceeded` |
| `ACCOUNT_STORAGE_MIB` | 512, never above the instance limit | 16-1,048,576 | the same, per account | 507 `storage_quota_exceeded` |
| `ACCOUNT_BLOBS` | 10,000 | 100-1,000,000 | attachments and backups per account (each takes at least 4 KiB on disk) | 507 `storage_quota_exceeded` |
| `DEVICES_PER_ACCOUNT` | 10 (the realtime hub allows 10 sockets per account) | 1-10 | active devices; also at most 3 open device links | 409 `device_limit_reached`, `device_link_limit_reached` |
| `CONVERSATION_MEMBERS` | 100 | 2-1,000 | members of a group, a community and each of its channels | 409 `conversation_member_limit_reached` |
| `CONVERSATIONS_PER_ACCOUNT` | 1,000 | 10-10,000 | conversations an account belongs to | 409 `conversation_limit_reached` to that account; adding an account that is full answers 403 `forbidden`, as a block does |
| `KEY_PACKAGE_CLAIMS_PER_TARGET` | 25 (half the 50 single-use key packages a device may hold) | 1-50 | key packages one account claims from one device of another account in 24 hours; claiming from its own devices is not limited | 429 `key_package_claim_limit` with `Retry-After`; adding devices to an existing group skips a device over its limit, as it skips one with no package left |
| `DELIVERIES_PER_MINUTE` | 1,000 | 60-1,000,000, and at least 2 × (1 + members) | per account, each fan-out write counts 1 plus every account it is published to | 429 `write_rate_limited` with `Retry-After` |
| `WRITE_MIB_PER_HOUR` | 64 | 16-65,536 | request bodies of those writes | 429 `write_rate_limited` |
| `ATTACHMENT_MIB` | 48 | 1-48 | the largest file one attachment may hold (plaintext with its padding; the upload route allows the chunk framing on top) | 413 `upload_too_large` |
| `SOCKETS_PER_IPV6_PREFIX` | 200 | 20-10,000 | realtime sockets of all addresses in one IPv6 /64 (one address always gets at most 20) | 429 `realtime_connection_limit` |

Why these defaults: a realtime delivery costs the server 4-10 ms of CPU;
one account at 1,000 a minute (17/s) is about a third of the 47/s tier S
served within its latency targets. A message counts 1 plus every member
account it reaches (the sender's own included, for its other devices), so
that is about 330 DMs a minute but 10 messages a minute into a full
100-member group, after a burst of the same size; raise it for large busy
groups. At 1,000 memberships a sync page
costs 14-18 ms against 28-30 ms at 2,000. One 1 KiB message becomes 3.8 KiB
of database, so 64 MiB an hour caps one account's database growth at about
240 MiB an hour, while heavy text use writes about 1 MiB a day. The write
budget is in memory: a restart refills it, and a bulk import through the
API proceeds at its pace.

**Attachment size cap.** `PRIVATE_MESSENGER_LIMIT_ATTACHMENT_MIB` is the
per-file cap. The server reports it to apps as `max_attachment_bytes` in
`GET /api/v1/setup/status`, and the app refuses a larger file before it
encrypts or uploads anything. 48 is the most the app can encrypt, so the
setting can only lower it.

**Attachment padding.** Apps pad each file with zeros inside the encryption
to a size bucket about 5% apart (Signal's buckets, at least 541 bytes), so
the server sees the bucket, not the exact size (`docs/crypto.md`,
attachment manifest v2). Stored sizes, the account and instance storage
quotas and the hourly write budget therefore count padded bytes: up to 5%
more per file, and at least 541 bytes for a tiny one. Padding never passes
the cap above: a file just under it is padded only up to the cap, so the
cap still means the largest file a user can send. The app reads the cap from
`setup/status` at send time; if that call fails it pads up to 48 MiB, and on
a server with a lower cap a file within 5% of it may then be refused with
413 until the call works again.

**Write guard.** With less free space than the smaller of 5% and 2 GiB on
the database or blob file system, the server answers new messages, MLS
messages and uploads with 507 `server_storage_low`; reads continue.
`VeritraDataDiskLow` pages at 10%.

**Upgrading.** The instance storage limit used to be a fixed 10 GiB. On a
small volume an instance already above the derived value keeps its data
but refuses uploads; `messenger-server doctor` prints usage against the
limit. Set `PRIVATE_MESSENGER_LIMIT_INSTANCE_STORAGE_MIB` when the blob
directory shares its file system with other data: k3s `local-path` volumes
live on the node's root disk, so set it from the PVC size (3,686 for 40 GiB
with seven backups). The derivation reads `PRIVATE_MESSENGER_BACKUP_KEEP`;
set the same value on the server if you change it for the backup job.

| Alert | Means | First thing to do |
|---|---|---|
| `VeritraWritesRefusedLowDisk` (critical) | Under 5% (or 2 GiB) free; new messages and uploads get 507 | Free space now (see `VeritraDataDiskLow`); writes resume within 30 s of the next sample above the threshold |
| `VeritraWriteBudgetRefusals` (warning) | An account keeps exceeding its fan-out or byte budget | Usually a misbehaving client or abuse; the account's other requests still work. Raise the limit only for a known heavy use such as a large busy group |
| `VeritraStorageQuotaRefusals` (warning) | Uploads are refused by a storage quota | `doctor` shows instance usage; raise the account or instance limit only after sizing the volume with the disk budget above |
