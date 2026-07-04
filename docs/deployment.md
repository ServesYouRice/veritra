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
- `PRIVATE_MESSENGER_TRUSTED_PROXIES`, comma-separated CIDRs whose `X-Forwarded-For` headers may be trusted for rate limiting

An example environment file is available at `server/config.example.env`.

## Health Check

`messenger-server healthcheck` probes the locally running server's `/healthz`
endpoint and exits non-zero on failure. The distroless container image ships no
shell or `curl`, so the binary performs the probe itself; the Compose file wires
this as the container `HEALTHCHECK`.

Set `PRIVATE_MESSENGER_ENABLE_METRICS=1` to expose `GET /metrics` with local
aggregate HTTP counters for operator scraping. The endpoint does not include
account IDs, request bodies, tokens, message content, or ciphertext.

## Docker Compose

Use `deploy/docker-compose.yml`. By default the plain-HTTP port is published on
loopback only (`127.0.0.1:8080`) so it is never exposed to the network without
TLS.

For any public deployment, run the Caddy profile, which is the intended
production path:

```sh
docker compose --profile caddy up -d
```

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

## Network Modes

- LAN/private mode: bind to a private address and use local trust.
- Tailscale/ZeroTier mode: bind on the private interface and keep public exposure closed.
- Public VPS: run behind Caddy with automatic HTTPS.
