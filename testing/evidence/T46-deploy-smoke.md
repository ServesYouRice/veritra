# T46 — Hardened deployment smoke and k3s rehearsal

Date: 2026-10-23. Branch base `89a437e`. Server fixes in `a06d828`; smoke
in `593c603`; deploy/docs changes in the commit that adds this file.

## Host

| | |
|---|---|
| Host | Throwaway cloud sandbox, Ubuntu 24.04.5, kernel 6.18 (Firecracker VM), 4 vCPU shared with five other jobs, 15 GB RAM, ~13 GB free disk |
| Docker | 29.9.1 (containerd image store), Compose 5.6.0, buildx 0.38.0 |
| Go | server toolchain go1.26.10 (from `.go-version`); smoke client built with host go1.24.7 (stdlib only, no module) |
| Images tested | `veritra-t46:a` = `89a437e` (before the fixes), `:b` = `a06d828` (index `sha256:17ac0064…0b52310`), `:c` = `593c603` (index `sha256:f678bc42…152bc5408`) |
| Pinned helpers | `caddy:2.11.4@sha256:af5fdcd7…` (repo pin), `coturn/coturn:4.18.0-alpine@sha256:c29135c0…`, `rclone/rclone:1.75.1@sha256:45401ad7…` (repo pin), `rancher/k3s:v1.34.12-k3s1`, kubectl v1.34.12, kubeconform v0.7.0, cert-manager v1.19.1 CRDs, Flux v2.7.0 CRDs. Tools were downloaded to a scratch directory with their published SHA-256 sums checked, and are not in the repo |

Sandbox limits that shaped the method (none apply to a normal PC or VPS):
the build container cannot verify the egress proxy's TLS, so these images
were built from `git archive` with a copy of `server/Dockerfile` whose only
change mounts the proxy CA as a BuildKit secret for `go mod download` (the
final stage is unchanged). That means `smoke-deploy.sh` ran with `--image`;
its default build path was not run here. Docker Hub rate-limited one pull, so
Caddy came from `mirror.gcr.io` by the same digest.

## Compose smoke: `scripts/smoke-deploy.sh` — PASS

`scripts/smoke-deploy.sh --image veritra-t46:c`, run as root and again as an
unprivileged member of the docker group; both passed and cleaned up (no
containers, volumes or temp files left). About 3 minutes per run.

| Check | Result |
|---|---|
| `deploy/docker-compose.yml` unchanged plus `scripts/smoke-deploy/compose.smoke.yml` (test ports, localhost `tls internal` Caddyfile derived from `deploy/caddy/Caddyfile`, coturn) | runs |
| Server: read-only root, `CapDrop [ALL]`, no CapAdd, uid 65532, no-new-privileges, memory and pids limits, `GOMEMLIMIT`, healthcheck healthy; Caddy read-only with only `NET_BIND_SERVICE` | pass |
| Secrets only as `*_FILE` (uid 65532, mode 0400 as root; 0444 otherwise): none in `docker compose config` or `docker inspect` | pass |
| Through Caddy: health, HSTS from the proxy, each security header once | pass |
| Owner setup with the file-mounted setup token (refused without it), password and device login | pass |
| Attachment 8 MiB upload, download, range request, SHA-256 | pass |
| Encrypted backup 96 MiB upload through the proxy, recovery download | pass |
| WebSocket upgrade through Caddy (Host kept); foreign Origin refused (403) | pass |
| Web Push: VAPID private key from file, plain-HTTP endpoint refused, subscription stored, test wake to an `.invalid` endpoint attempted (result `failed`), second wake rate-limited | pass |
| TURN: credential from the file-mounted secret is `HMAC-SHA1(secret, "<expiry>:<account>")`, about 10 minutes; coturn (`use-auth-secret`) allocated relays and carried 40/40 client-to-client messages with it; a wrong credential was refused | pass |
| `scheduled-backup` beside the running server: backup, restore drill, off-host copy verified | pass |
| Graceful stop within the 30 s grace, exit code 0 | pass (under 1 s idle) |
| Fresh volume: `verify-backup` of the off-host copy, `restore`, `doctor`, start; owner login, attachment and backup blobs intact, new writes, push registration kept | pass |
| Log privacy: 19 values (setup token, TURN secret, VAPID key, password, session tokens, device secret, recovery token, TURN credential, push endpoint and keys, account/device/conversation/attachment IDs, ciphertext prefixes) absent from server, Caddy and job output | pass |

## Bugs the smoke found (fixed)

1. **TURN URLs as documented stopped startup.** `server/config.example.env`
   shows `turns:turn.example.com:5349?transport=tcp` (RFC 7065, what WebRTC
   parses), but the validator required `url.Host`, so the server restart-looped
   with `invalid PRIVATE_MESSENGER_TURN_URLS entry` (seen with image `:a`).
   Only `turn://host` passed, which WebRTC reads as host `//host`. Fixed in
   `server/internal/config`: RFC 7065 form accepted and canonical; `turn://`
   rewritten; table test.
2. **Caddy logged the setup token.** The supported Caddyfile's access-log
   filter kept `X-Veritra-Setup-Token`. Found the same day by the I29 test
   work on the main branch, whose fix (access and error logs drop the URI and
   every credential header, `TestCaddyLogsDropURIsAndCredentialHeaders`) is
   the one kept after merging; this branch's first fix (no access log) was
   dropped. Its security headers were also sent twice (app and Caddy); now
   deferred, sent once.
3. **VAPID `sub` claim was `mailto:mailto:…`.** webpush-go prefixes `mailto:`
   to anything not starting with `https:`. Found reading the push path for the
   smoke; fixed in `server/internal/push` with a request-capturing test (fails
   without the fix).
4. **Traefik redirect silently ignored.** In the chart k3s v1.34.12 bundles
   (40.1), the HTTP→HTTPS redirect must be under `ports.web.http`; the
   example's `ports.web.redirections` produced no argument. Fixed.
5. **Restore Job had no resource limits** (handbook: every workload). Added,
   with `GOMEMLIMIT`.

## k3s rehearsal — PASS (with the gaps below)

Single-node `rancher/k3s:v1.34.12-k3s1` in Docker: API on loopback only,
`--secrets-encryption` (status: Enabled), Traefik and kube-router network
policies as bundled. Sandbox-only settings: containerd
`restrict_oom_score_adj` (the sandbox has no `CAP_SYS_RESOURCE`), eviction at
1 GiB free and image GC off (shared disk nearly full), images imported from
`docker save` because the node cannot resolve external names. The overlay was
the repo's `examples/overlay` (including the monitoring component) plus
rehearsal patches: local digest, host `localhost`, TURN and VAPID settings,
an `rclone serve s3` stand-in for R2 in its own namespace, and one
NetworkPolicy letting the backup jobs reach it (the base allows only public
HTTPS, as for R2).

| Step | Result |
|---|---|
| `kubectl kustomize` base and example overlay; kubeconform `-strict` (k8s 1.34 + CRD schemas), 39 resources incl. the Flux example | 39/39 valid |
| Flux `Kustomization` example, server-side dry run against Flux v2.7.0 CRDs | accepted |
| Apply: no Pod Security warnings; a root pod in `veritra` refused (`violates PodSecurity "restricted:latest"`) | pass |
| Server pod: no service-account token volume or `/var/run/secrets/kubernetes.io`; limits set; `GOMEMLIMIT=768MiB` | pass |
| Network policy: pod in `default` → server:8080 refused; from the server pod's network: DNS works, S3 stand-in and API server refused | pass |
| API smoke through Traefik (setup, login, attachment, 32 MiB backup + recovery, WebSocket, push, TURN, HSTS) | pass |
| Traefik timeout: 90 s throttled upload completes with `examples/traefik-helmchartconfig.yaml`; control without it: cut at 60 s (HTTP 502) | pass |
| Backup CronJob (by hand): `scheduled-backup`, rclone `--checksum --immutable` to the stand-in; second run copies only the new backup | pass |
| Restore-drill CronJob (`veritra-restore-drill-manual-1`): newest backup from the stand-in, `verify-backup` | pass |
| Upgrade B→C (digest change, as a Flux reconcile would): Recreate, sampled every 0.5 s, never two server pods; data kept | pass |
| Rollback C→B (revert the digest): same, old pod exited `Succeeded`; data kept | pass |
| Recovery: second backup, `veritra` namespace and volume deleted, rebuilt from manifests, scaled to 0, `examples/restore-job.yaml` restored the newest backup from the stand-in into the fresh volume, scaled up: owner login, blobs, writes, push registration | pass |
| Prune protection: namespace and PVC carry `kustomize.toolkit.fluxcd.io/prune: disabled` | applied |

## Not possible here

- **Real push delivery.** Needs a device, provider keys and public egress
  (G24). The server's public-only dialer rightly refuses a local fake.
- **cert-manager issuance.** quay.io is blocked here; only the CRDs were
  installed, so the `Certificate` was schema-checked and TLS used a
  self-signed localhost secret. Production uses Cloudflare DNS-01 (owner
  token).
- **Flux reconciling from Git.** No infra repo or reachable Git server; the
  digest changes were applied with `kubectl apply` of the same overlay.
- **R2 itself:** bucket lock, lifecycle rule, token scope and the R2
  checksum behaviour. The stand-in is S3-compatible only.
- **Schema skew on rollback:** images B and C share a schema.
- **systemd at runtime** (no systemd PID 1). `systemd-analyze verify`
  passed offline for all three units; `systemd-analyze security --offline`:
  server 1.4 OK, backup 0.6 SAFE.
- **`release-image.sh`** (needs Trivy, cargo-audit and a GHCR push) and the
  smoke's default build path (stock Dockerfile cannot fetch modules here).
- **Rate limits per client** behind Traefik with two real networks.
- **In-flight upload during shutdown** at runtime (unit-tested in
  `internal/app`).

## Checks

| Command | Result |
|---|---|
| `cd server && go test ./cmd/messenger-server ./internal/app` | pass |
| `./scripts/lint.sh` | pass |
| `./scripts/test.sh` (Go, Rust, Flutter: 293 passed, 23 skipped) | pass |
| `go test ./internal/config ./internal/push` (new TURN-URL and VAPID-subject tests; the VAPID test fails without its fix) | pass |
| `TestDeployMemoryLimitsCarryGOMEMLIMIT` (Compose, systemd, k8s limit and `GOMEMLIMIT` pairs) | pass |
| `systemd-analyze verify` (offline root) on the three units | pass |

## Reproduce

Compose: `scripts/smoke-deploy.sh` (builds from `git archive HEAD`) or
`scripts/smoke-deploy.sh --image <ref>`. k3s: the steps in
`docs/operations.md` (Kubernetes, Deploying with Flux, rebuilt-cluster
recovery); the rehearsal driver was a scratch script and was not committed.
