# I06 — Harden proxy, setup, and throttles

Goal: supported reverse proxies cannot bypass setup authorization or collapse realtime limits.

Read:

- trusted-proxy/client-IP code under `server/internal/httpapi/`
- setup, auth, enrollment, and realtime handlers/tests
- `deploy/Caddyfile`, Compose, and systemd examples

Do:

1. Use one spoof-resistant client identity resolver for HTTP and WebSocket limits.
2. Require safe production mode and setup-token behavior in reference deployments.
3. Apply strict enrollment limits and privacy-safe account login backoff.
4. Return bounded retry guidance without logging identifiers or secrets.
5. Add proxy-topology integration tests.

Done when: spoofed forwarding is ignored, trusted clients remain distinct, and production setup fails closed.

Verify:

```powershell
Push-Location server; go test ./internal/httpapi; Pop-Location
docker compose config
```
