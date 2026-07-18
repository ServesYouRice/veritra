# Deployment

## Single Binary

```sh
messenger-server migrate
messenger-server serve
```

Environment:

- `PRIVATE_MESSENGER_ADDR`, default `:8080`
- `PRIVATE_MESSENGER_DATA_DIR`, default `./data`
- `PRIVATE_MESSENGER_DB_PATH`, default `<data>/private-messenger.db`
- `PRIVATE_MESSENGER_STORAGE_PATH`, default `<data>/blobs`
- `PRIVATE_MESSENGER_ENV`, `development` by default; set to `production` to enable fail-fast safety checks
- `PRIVATE_MESSENGER_LOG_LEVEL`, one of `debug`, `info`, `warn`, or `error`
- `PRIVATE_MESSENGER_LOG_FORMAT`, `text` or aggregation-friendly `json`
- `PRIVATE_MESSENGER_SYNC_EVENT_RETENTION_DAYS`, durable sync-log retention from 1 to 3650 days (default 30)
- `PRIVATE_MESSENGER_SETUP_TOKEN`, high-entropy one-time secret required for remote first-owner setup
- `PRIVATE_MESSENGER_MANAGEMENT_ADDR`, loopback/private metrics listener, default `127.0.0.1:9090`
- `PRIVATE_MESSENGER_TRUSTED_PROXIES`, comma-separated CIDRs whose `X-Forwarded-For` headers may be trusted for rate limiting
- `PRIVATE_MESSENGER_VAPID_SUBSCRIBER`, `PRIVATE_MESSENGER_VAPID_PUBLIC_KEY`, and `PRIVATE_MESSENGER_VAPID_PRIVATE_KEY`, optional all-or-none encrypted Web Push configuration

An example environment file is available at `server/config.example.env`.

Encrypted Web Push is disabled unless all three VAPID variables are present.
The subscriber must be a `mailto:` or HTTPS URI. Store the private key only in
the root-readable environment file; it is never returned by the API or logged.

Generate the setup token out of band, keep it out of logs and command-line
arguments, and remove it from the environment after the owner is created.
Tokenless setup is accepted only over a loopback connection.

## Health Check

`messenger-server healthcheck` probes the locally running server's `/healthz`
endpoint and exits non-zero on failure. The minimal scratch container image ships no
shell or `curl`, so the binary performs the probe itself; the Compose file wires
this as the container `HEALTHCHECK`.

Set `PRIVATE_MESSENGER_ENABLE_METRICS=1` to expose `GET /metrics` on the separate
management listener with local
aggregate HTTP counters, bounded route-pattern latency histograms, active
request counts, and a realtime-connection gauge for operator scraping. Route
labels come from registered patterns, so IDs and arbitrary request paths never
become labels. The endpoint does not include
account IDs, request bodies, tokens, message content, or ciphertext. Do not
publish the management listener to the Internet.

Recommended starter alerts are: `/readyz` failing for two minutes, any sustained
5xx increase, p95 request latency above the instance's SLO, or realtime
connections approaching the configured single-node capacity. Alert receivers
and paging policy remain operator-managed; Veritra does not send telemetry.

The systemd example binds to `127.0.0.1:8080`, stores data in a private
`StateDirectory`, and optionally reads `/etc/private-messenger/private-messenger.env`.
Place TLS reverse-proxy and setup-token settings in that root-readable file.

## Docker Compose

Use `deploy/docker-compose.yml`. By default the plain-HTTP port is published on
loopback only (`127.0.0.1:8080`) so it is never exposed to the network without
TLS.

For any public deployment, run the Caddy profile, which is the intended
production path:

```sh
docker compose --profile caddy up -d
```

Set `PRIVATE_MESSENGER_ENV=production` for a public deployment. In production,
Veritra refuses a non-loopback application listener unless a trusted reverse
proxy network is declared, and refuses to expose metrics on a public address.

Caddy terminates HTTPS on 80/443, provisions/renews certificates automatically,
reverse-proxies to the server over the internal network, and sets HSTS at the
edge. Replace the placeholder `email` and domain in `deploy/caddy/Caddyfile`
before deploying.

When running behind Caddy or any reverse proxy, set
`PRIVATE_MESSENGER_TRUSTED_PROXIES` to the proxy network CIDR. Without it, the
rate limiter sees the proxy address instead of the original client IP and can
bucket the whole instance as one client.

The bundled Compose file creates a dedicated `172.28.250.0/24` network and sets
`PRIVATE_MESSENGER_TRUSTED_PROXIES` to that subnet. If you change the Compose
network subnet, update the environment variable too.

## Single-Node Constraint

This is a single-node deployment by construction and a deliberate v1 boundary:

- SQLite is a single local database file (one writer, a bounded reader pool).
- Encrypted blobs live on the local disk.
- The realtime hub is an in-process map ([`server/internal/realtime/hub.go`](../server/internal/realtime/hub.go)).

Running more than one server replica against the same data is **not supported**:
replicas would not see each other's realtime `Publish` calls, so clients
connected to a different replica would silently miss live events (they would
still recover them via `/api/v1/sync/events`, but fan-out is not cross-node).
Horizontal scaling would require externalizing all three (e.g. Postgres, object
storage, and a Redis/NATS fan-out) and is intentionally deferred.

Blob access is isolated behind a streaming storage interface so an object-store
backend can be added without changing API authorization or ciphertext handling.
The current release deliberately configures local storage only; do not assume
S3 compatibility or multi-node safety until a backend and its backup contract
are implemented and reviewed.

## Backups and rollback

`messenger-server backup [directory]` creates one manifest-backed snapshot of
the SQLite database and every referenced encrypted blob. Copy the completed
directory off-host only after the command succeeds; incomplete directories are
not valid backups. `messenger-server restore <directory>` requires downtime,
validates database and blob checksums in staging, and keeps pre-restore rollback
copies beside the live data.

Schedule the command with the host scheduler and rotate only completed backup
directories. Choose retention from the instance's RPO; a daily off-host copy
gives an RPO of up to 24 hours. Perform a periodic restore rehearsal on a
separate host. Schema changes are expand/contract and migrations are never
edited after release; binary rollback across an incompatible migration requires
restoring the matching pre-deploy backup.

## Network Modes

- LAN/private mode: bind to a private address and use local trust.
- Tailscale/ZeroTier mode: bind on the private interface and keep public exposure closed.
- Public VPS: run behind Caddy with automatic HTTPS.
