#!/usr/bin/env bash
# Hardened deployment smoke for the supported Compose stack (card T46).
# Runs locally; there is no hosted CI.
#
#   scripts/smoke-deploy.sh [--image REF] [--keep]
#
#   --image REF  test this image (a release digest, or a local tag) instead
#                of building server/Dockerfile from `git archive HEAD`
#   --keep       keep the temporary directory (state, logs) for inspection
#
# It runs deploy/docker-compose.yml unchanged (read-only root, all
# capabilities dropped, uid 65532, secrets only as *_FILE mounts) with the
# caddy profile, plus scripts/smoke-deploy/compose.smoke.yml (loopback test
# ports, a localhost `tls internal` Caddyfile derived from
# deploy/caddy/Caddyfile, and coturn). Then, through Caddy:
#   startup and health, owner setup with the file-mounted setup token,
#   login, attachment upload/download, a 96 MiB encrypted backup and its
#   recovery download, WebSocket upgrade with Origin checks, a Web Push test
#   wake (to an unresolvable endpoint: real delivery needs a device, G24),
#   TURN credential issuance and a relay allocation on coturn with it;
# then the backup job with an off-host directory, verify-backup of the
# off-host copy, a graceful stop inside the 30 s grace, a restore into a
# fresh data volume, and the same checks against the restored server. It
# fails if any secret, token, ID or payload prefix shows up in the server or
# Caddy logs, in `docker compose config` or in `docker inspect`.
#
# Needs bash, docker with compose v2.24+, and go (builds the stdlib-only
# client in scripts/smoke-deploy/). Uses Compose projects veritra-smoke and
# veritra-smoke-restore, the fixed network 172.28.250.0/24 and loopback
# ports SMOKE_HTTP_PORT (18080) and SMOKE_HTTPS_PORT (18443). Run as root
# (or with sudo) to test the documented secret-file ownership (uid 65532,
# mode 0400); otherwise the throwaway secrets are mode 0444 inside a private
# temporary directory.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE=""
KEEP=0
HTTP_PORT="${SMOKE_HTTP_PORT:-18080}"
HTTPS_PORT="${SMOKE_HTTPS_PORT:-18443}"
COTURN_IMAGE="coturn/coturn:4.18.0-alpine@sha256:c29135c08565810d37053f384584392b7c24b69570fc81a721b878d6fe63e04e"
TURN_IP="172.28.250.30"
TURN_URLS="turn:$TURN_IP:3478?transport=udp"

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="${2:?--image needs a value}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() { echo "smoke-deploy: FAIL: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
pass() { echo "ok: $*"; }

for tool in docker go; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed"
done
docker compose version >/dev/null 2>&1 || fail "docker compose v2 is required"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/veritra-smoke.XXXXXX")"
chmod 0700 "$TMP"
SECRETS="$TMP/secrets"
OFFSITE="$TMP/offsite"
LOGS="$TMP/logs"
mkdir -p "$SECRETS" "$OFFSITE" "$LOGS" "$TMP/turn"
chmod 0755 "$SECRETS" "$TMP/turn"

export VERITRA_SECRETS_DIR="$SECRETS"
export PRIVATE_MESSENGER_BACKUP_OFFSITE_PATH="$OFFSITE"
export SMOKE_HTTP_PORT="$HTTP_PORT" SMOKE_HTTPS_PORT="$HTTPS_PORT"
export SMOKE_CADDYFILE="$TMP/Caddyfile"
export SMOKE_TURN_CONF="$TMP/turn/turnserver.conf"
export PRIVATE_MESSENGER_SETUP_TOKEN_FILE=/run/secrets/setup_token
export PRIVATE_MESSENGER_TURN_SHARED_SECRET_FILE=/run/secrets/turn_shared_secret
export PRIVATE_MESSENGER_VAPID_PRIVATE_KEY_FILE=/run/secrets/vapid_private_key
export PRIVATE_MESSENGER_VAPID_SUBSCRIBER="mailto:smoke@example.org"
export PRIVATE_MESSENGER_TURN_URLS="$TURN_URLS"
unset PRIVATE_MESSENGER_SETUP_TOKEN PRIVATE_MESSENGER_TURN_SHARED_SECRET PRIVATE_MESSENGER_VAPID_PRIVATE_KEY || true

FILES=(-f "$ROOT/deploy/docker-compose.yml" -f "$ROOT/scripts/smoke-deploy/compose.smoke.yml")
COMPOSE=(docker compose -p veritra-smoke "${FILES[@]}" --profile caddy)
RESTORE=(docker compose -p veritra-smoke-restore "${FILES[@]}" --profile caddy)

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "smoke-deploy: failed; recent server logs (route names and error codes only):" >&2
    "${COMPOSE[@]}" logs --no-color --tail 40 messenger caddy >&2 2>/dev/null || true
    "${RESTORE[@]}" logs --no-color --tail 40 messenger caddy >&2 2>/dev/null || true
  fi
  "${COMPOSE[@]}" --profile backup down --volumes --remove-orphans >/dev/null 2>&1 || true
  "${RESTORE[@]}" --profile backup down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [ "$KEEP" -eq 1 ]; then
    echo "kept $TMP (throwaway test secrets inside; delete it when done)"
  else
    if [ "$(id -u)" -ne 0 ]; then
      # Backups written by uid 65532 cannot be removed by this user.
      docker run --rm --user 0 -v "$TMP:/smoke" --entrypoint rm "$COTURN_IMAGE" -rf /smoke/offsite >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP"
  fi
  exit "$status"
}
trap cleanup EXIT

step "image"
if [ -z "$IMAGE" ]; then
  command -v git >/dev/null 2>&1 || fail "git is needed to build the image (or pass --image)"
  cd "$ROOT"
  commit="$(git rev-parse HEAD)"
  IMAGE="veritra-smoke:$(git rev-parse --short=12 HEAD)"
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "note: building committed files only (git archive HEAD); uncommitted changes are not in the image"
  fi
  git archive --format=tar HEAD | docker build --platform linux/amd64 -f server/Dockerfile \
    --build-arg "GO_VERSION=$(tr -d '[:space:]' < .go-version)" \
    --build-arg "VERSION=smoke" --build-arg "COMMIT=$commit" -t "$IMAGE" - >"$LOGS/build.log" 2>&1 \
    || { tail -20 "$LOGS/build.log" >&2; fail "image build failed"; }
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null || fail "image $IMAGE not found"
export VERITRA_IMAGE="$IMAGE"
pass "image $IMAGE ($(docker run --rm "$IMAGE" version))"

step "client and throwaway secrets"
(cd "$ROOT/scripts/smoke-deploy" && go build -o "$TMP/smoke-client" smoke-client.go) || fail "smoke client build failed"
CLIENT="$TMP/smoke-client"
docker run --rm "$IMAGE" generate-setup-token > "$SECRETS/setup_token"
docker run --rm "$IMAGE" generate-setup-token > "$SECRETS/turn_shared_secret"
VAPID_PUBLIC="$("$CLIENT" vapid-keys -private-out "$SECRETS/vapid_private_key")"
export PRIVATE_MESSENGER_VAPID_PUBLIC_KEY="$VAPID_PUBLIC"
if [ "$(id -u)" -eq 0 ]; then
  chown 65532:65532 "$SECRETS"/* "$OFFSITE"
  chmod 0400 "$SECRETS"/*
  pass "secret files owned by uid 65532, mode 0400 (documented layout)"
else
  chmod 0444 "$SECRETS"/*
  chmod 0777 "$OFFSITE"
  pass "secret files mode 0444 in a private directory (not root: cannot chown to 65532)"
fi
# label<TAB>value lines that must never appear in logs or config dumps.
: > "$TMP/sensitive.tsv"
for name in setup_token turn_shared_secret vapid_private_key; do
  printf '%s\t%s\n' "$name" "$(tr -d '\r\n' < "$SECRETS/$name")" >> "$TMP/sensitive.tsv"
done
cut -f2 "$TMP/sensitive.tsv" > "$TMP/patterns.txt"

# leak_check FILE...: fail if any checked value is in a file. Reports the
# label and the line with the value replaced, never the value.
leak_check() {
  local file label value found=0
  for file in "$@"; do
    grep -F -q -f "$TMP/patterns.txt" "$file" || continue
    while IFS=$'\t' read -r label value; do
      grep -F -q -- "$value" "$file" || continue
      found=1
      echo "leak: $label in $(basename "$file"):" >&2
      grep -F -- "$value" "$file" | head -3 | awk -v v="$value" -v l="[$label]" \
        '{ while ((i = index($0, v)) > 0) $0 = substr($0, 1, i - 1) l substr($0, i + length(v)); print "  " $0 }' >&2
    done < "$TMP/sensitive.tsv"
  done
  return "$found"
}
{
  echo "listening-port=3478"
  echo "realm=veritra-smoke.invalid"
  echo "use-auth-secret"
  echo "static-auth-secret=$(cat "$SECRETS/turn_shared_secret")"
  echo "no-tls"
  echo "no-dtls"
  echo "no-cli"
  echo "fingerprint"
  echo "min-port=49160"
  echo "max-port=49200"
  echo "log-file=stdout"
  echo "pidfile=/tmp/turnserver.pid"
  echo "no-multicast-peers"
} > "$SMOKE_TURN_CONF"
chmod 0444 "$SMOKE_TURN_CONF"

# The production Caddyfile with only the site changed to localhost on
# Caddy's internal CA; everything else (log filter, forwarding headers,
# security headers) is what operators run.
awk '
  /^\{$/ && !global { print; print "\tskip_install_trust"; global = 1; next }
  /^messenger\.example\.com \{$/ { print "localhost {"; print "\ttls internal"; site = 1; next }
  { print }
  END { if (!global || !site) exit 3 }
' "$ROOT/deploy/caddy/Caddyfile" > "$SMOKE_CADDYFILE" || fail "deploy/caddy/Caddyfile no longer has the expected global block and site line"

step "configuration dump"
docker compose -p veritra-smoke -f "$ROOT/deploy/docker-compose.yml" --profile caddy --profile backup config > "$TMP/compose-config.yml"
leak_check "$TMP/compose-config.yml" || fail "a secret value appears in docker compose config"
pass "docker compose config holds *_FILE paths only, no secret values"

step "start the hardened stack"
"${COMPOSE[@]}" up -d --wait --wait-timeout 180 messenger caddy coturn >"$LOGS/up.log" 2>&1 \
  || { cat "$LOGS/up.log" >&2; fail "stack did not start"; }
pass "messenger healthy, caddy and coturn running"

check_hardening() {
  local project=("$@")
  local server caddy
  server="$("${project[@]}" ps -q messenger)"
  caddy="$("${project[@]}" ps -q caddy)"
  [ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$server")" = "true" ] || fail "server root filesystem is writable"
  [ "$(docker inspect --format '{{json .HostConfig.CapDrop}}' "$server")" = '["ALL"]' ] || fail "server keeps capabilities"
  [ "$(docker inspect --format '{{json .HostConfig.CapAdd}}' "$server")" = 'null' ] || fail "server adds capabilities"
  [ "$(docker inspect --format '{{.Config.User}}' "$server")" = "65532:65532" ] || fail "server is not uid 65532"
  docker inspect --format '{{json .HostConfig.SecurityOpt}}' "$server" | grep -q 'no-new-privileges:true' || fail "server lacks no-new-privileges"
  [ "$(docker inspect --format '{{.HostConfig.Memory}}' "$server")" -gt 0 ] || fail "server has no memory limit"
  [ "$(docker inspect --format '{{.HostConfig.PidsLimit}}' "$server")" -gt 0 ] || fail "server has no pids limit"
  [ "$(docker inspect --format '{{.State.Health.Status}}' "$server")" = "healthy" ] || fail "server healthcheck is not healthy"
  [ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$caddy")" = "true" ] || fail "caddy root filesystem is writable"
  [ "$(docker inspect --format '{{json .HostConfig.CapDrop}}' "$caddy")" = '["ALL"]' ] || fail "caddy keeps capabilities"
  docker inspect --format '{{json .HostConfig.CapAdd}}' "$caddy" | grep -q 'NET_BIND_SERVICE' || fail "caddy lacks NET_BIND_SERVICE"
  docker inspect "$server" "$caddy" > "$TMP/inspect.json"
  leak_check "$TMP/inspect.json" || fail "a secret value appears in docker inspect"
}
check_hardening "${COMPOSE[@]}"
pass "read-only root, no capabilities (caddy: NET_BIND_SERVICE), uid 65532, no-new-privileges, limits; no secret in docker inspect"

caddy_ca() {
  local project=("${@:2}")
  for _ in $(seq 1 30); do
    if "${project[@]}" cp caddy:/data/caddy/pki/authorities/local/root.crt "$1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  fail "caddy did not create its internal CA"
}
BASE="https://localhost:$HTTPS_PORT"
caddy_ca "$TMP/caddy-root.crt" "${COMPOSE[@]}"
"$CLIENT" wait -base "$BASE" -ca "$TMP/caddy-root.crt"
"$CLIENT" wait -base "http://127.0.0.1:$HTTP_PORT"

step "API smoke through Caddy (TLS, Host header, forwarding)"
"$CLIENT" run -base "$BASE" -ca "$TMP/caddy-root.crt" -state "$TMP/state.json" \
  -sensitive-out "$TMP/client-sensitive.txt" -turn-out "$TMP/turn/credentials" \
  -setup-token-file "$SECRETS/setup_token" -turn-secret-file "$SECRETS/turn_shared_secret" \
  -turn-urls "$TURN_URLS" -vapid-public "$VAPID_PUBLIC"
cat "$TMP/client-sensitive.txt" >> "$TMP/sensitive.tsv"
cut -f2 "$TMP/sensitive.tsv" > "$TMP/patterns.txt"

step "TURN relay with the issued credential"
TURN_USER="$(sed -n 1p "$TMP/turn/credentials")"
TURN_CREDENTIAL="$(sed -n 2p "$TMP/turn/credentials")"
uclient() {
  docker run --rm --network veritra-smoke_messenger-net --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true --entrypoint turnutils_uclient "$COTURN_IMAGE" \
    -y -n 10 -m 1 -u "$TURN_USER" -w "$1" "$TURN_IP"
}
uclient "$TURN_CREDENTIAL" > "$LOGS/turn-relay.log" 2>&1 || { tail -5 "$LOGS/turn-relay.log" >&2; fail "coturn refused the credential Veritra issued"; }
grep -q 'Total lost packets 0 ' "$LOGS/turn-relay.log" || fail "relayed packets were lost"
pass "coturn allocated relays and carried client-to-client data with the issued credential"
if uclient "x$TURN_CREDENTIAL" > "$LOGS/turn-negative.log" 2>&1; then
  fail "coturn accepted a wrong credential"
fi
pass "coturn refused a wrong credential"

step "scheduled backup with an off-host directory (server running)"
"${COMPOSE[@]}" --profile backup run --rm -T backup > "$LOGS/backup.log" 2>&1 || { cat "$LOGS/backup.log" >&2; fail "scheduled backup failed"; }
grep -q '^scheduled backup verified: veritra-' "$LOGS/backup.log" || fail "scheduled backup did not report success"
BACKUP_NAME="$(sed -n 's/^scheduled backup verified: \(veritra-[0-9TZ]*\)$/\1/p' "$LOGS/backup.log")"
[ -n "$BACKUP_NAME" ] || fail "no backup name in the backup output"
pass "backup $BACKUP_NAME written, restore-drilled and copied off-host"

step "graceful stop"
server="$("${COMPOSE[@]}" ps -q messenger)"
started=$(date +%s)
"${COMPOSE[@]}" stop -t 30 messenger >/dev/null 2>&1
elapsed=$(( $(date +%s) - started ))
[ "$(docker inspect --format '{{.State.ExitCode}}' "$server")" = "0" ] || fail "server exited non-zero on SIGTERM"
[ "$elapsed" -lt 30 ] || fail "server took ${elapsed}s to stop (grace is 30s)"
pass "server stopped cleanly in ${elapsed}s"
"${COMPOSE[@]}" logs --no-color messenger caddy > "$LOGS/first.log" 2>&1
"${COMPOSE[@]}" down >/dev/null 2>&1

step "restore into a fresh data volume"
"${RESTORE[@]}" run --rm --no-deps -T -v "$OFFSITE:/restore-source:ro" messenger \
  verify-backup "/restore-source/$BACKUP_NAME" > "$LOGS/verify-backup.log" 2>&1 \
  || { cat "$LOGS/verify-backup.log" >&2; fail "verify-backup of the off-host copy failed"; }
pass "verify-backup of the off-host copy on a clean volume"
"${RESTORE[@]}" run --rm --no-deps -T -v "$OFFSITE:/restore-source:ro" messenger \
  restore "/restore-source/$BACKUP_NAME" > "$LOGS/restore.log" 2>&1 \
  || { cat "$LOGS/restore.log" >&2; fail "restore failed"; }
"${RESTORE[@]}" run --rm --no-deps -T messenger doctor > "$LOGS/doctor.log" 2>&1 \
  || { cat "$LOGS/doctor.log" >&2; fail "doctor failed on the restored data"; }
grep -q '^storage: ok$' "$LOGS/doctor.log" || fail "doctor did not report storage ok"
pass "restore and doctor on the fresh volume"
"${RESTORE[@]}" up -d --wait --wait-timeout 180 messenger caddy >"$LOGS/up-restore.log" 2>&1 \
  || { cat "$LOGS/up-restore.log" >&2; fail "restored stack did not start"; }
check_hardening "${RESTORE[@]}"
caddy_ca "$TMP/caddy-root-restore.crt" "${RESTORE[@]}"
"$CLIENT" wait -base "$BASE" -ca "$TMP/caddy-root-restore.crt"
"$CLIENT" verify -base "$BASE" -ca "$TMP/caddy-root-restore.crt" -state "$TMP/state.json"
"${RESTORE[@]}" logs --no-color messenger caddy > "$LOGS/restored.log" 2>&1

step "log privacy"
leak_check "$LOGS/first.log" "$LOGS/restored.log" "$LOGS/backup.log" "$LOGS/verify-backup.log" \
  "$LOGS/restore.log" "$LOGS/doctor.log" || fail "server, Caddy or job output holds a checked value (see above)"
pass "no secret, token, ID, push endpoint or payload prefix in server, Caddy or job output ($(wc -l < "$TMP/patterns.txt") values checked)"

printf '\nPASS: hardened deployment smoke (%s)\n' "$IMAGE"
