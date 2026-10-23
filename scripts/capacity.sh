#!/usr/bin/env bash
# Capacity run for one host tier (card I47, docs/operations.md "Capacity
# contract"). Builds the server and server/cmd/veritra-load, starts the
# server in production mode in a container limited to the tier's CPU and
# memory, seeds it with the tier's synthetic dataset through the public API,
# runs one scenario and prints the report plus peak container CPU/memory.
#
#   scripts/capacity.sh <s|m> [load|backup|restart] [veritra-load flags...]
#
#   load     busy-hour load only
#   backup   scheduled-backup (VACUUM INTO + restore drill) a third into the
#            measured window
#   restart  `docker restart -t 30` (SIGTERM, 25 s drain) a third into the
#            measured window
#
# Needs Go, Docker and the busybox:1.37.0 image. Everything is local and
# synthetic; the data directory is deleted afterwards unless
# VERITRA_CAPACITY_KEEP=1. Results go to $VERITRA_CAPACITY_DIR (default a
# new temporary directory). A soak on the owner's host, for example:
#   scripts/capacity.sh s load -rate 2 -duration 2h
set -euo pipefail

tier=${1:?usage: scripts/capacity.sh <s|m> [load|backup|restart] [veritra-load flags...]}
scenario=${2:-load}
shift $(( $# >= 2 ? 2 : $# ))
case "$tier" in
  s) cpus=1; memory=1g ;;
  m) cpus=2; memory=2g ;;
  *) echo "tier must be s or m" >&2; exit 2 ;;
esac
case "$scenario" in load|backup|restart) ;; *) echo "scenario must be load, backup or restart" >&2; exit 2 ;; esac

# seconds converts a Go-style duration with one s, m or h unit.
seconds() {
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *) echo "$1" ;;
  esac
}
duration=120
args=("$@")
for ((i = 0; i + 1 < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = -duration ]; then duration=$(seconds "${args[$((i + 1))]}"); fi
done

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=${VERITRA_CAPACITY_DIR:-$(mktemp -d)}
name="veritra-capacity-$tier"
port=${VERITRA_CAPACITY_PORT:-18080}
metrics_port=$((port + 1010))
mkdir -p "$work/bin" "$work/data" "$work/secrets"
result="$work/result-$tier-$scenario"

stats_pid=
cleanup() {
  if [ -n "$stats_pid" ]; then kill "$stats_pid" 2>/dev/null || true; fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  if [ "${VERITRA_CAPACITY_KEEP:-0}" != 1 ]; then rm -rf "$work/data" "$work/secrets"; fi
}
trap cleanup EXIT

(cd "$root/server" && CGO_ENABLED=0 go build -trimpath -o "$work/bin/messenger-server" ./cmd/messenger-server \
  && go build -o "$work/bin/veritra-load" ./cmd/veritra-load)
docker build -q -t veritra-capacity:local -f - "$work/bin" >/dev/null <<'EOF'
FROM busybox:1.37.0
COPY messenger-server /usr/local/bin/messenger-server
# Production refuses a wildcard metrics listener, so bind the container IP.
ENTRYPOINT ["/bin/sh", "-c", "PRIVATE_MESSENGER_MANAGEMENT_ADDR=$(hostname -i):9090 exec /usr/local/bin/messenger-server serve"]
EOF

"$work/bin/messenger-server" generate-setup-token > "$work/secrets/setup_token"
chmod 600 "$work/secrets/setup_token"
docker rm -f "$name" >/dev/null 2>&1 || true
# The container sees the load tool through Docker's bridge gateway; trusting
# 172.16.0.0/12 lets each simulated device keep its own X-Forwarded-For
# address, as phones behind Traefik do.
docker run -d --name "$name" --user "$(id -u):$(id -g)" \
  --cpus "$cpus" --memory "$memory" --memory-swap "$memory" \
  -p "127.0.0.1:$port:8080" -p "127.0.0.1:$metrics_port:9090" \
  -v "$work/data:/data" -v "$work/secrets:/run/secrets:ro" --tmpfs /tmp:size=64m \
  -e PRIVATE_MESSENGER_ENV=production -e PRIVATE_MESSENGER_DATA_DIR=/data \
  -e PRIVATE_MESSENGER_ADDR=:8080 -e PRIVATE_MESSENGER_TRUSTED_PROXIES=172.16.0.0/12 \
  -e PRIVATE_MESSENGER_SETUP_TOKEN_FILE=/run/secrets/setup_token \
  -e PRIVATE_MESSENGER_ENABLE_METRICS=1 -e PRIVATE_MESSENGER_LOG_FORMAT=json \
  ${VERITRA_CAPACITY_GOMEMLIMIT:+-e GOMEMLIMIT=$VERITRA_CAPACITY_GOMEMLIMIT} \
  veritra-capacity:local >/dev/null

ready() { curl -fsS -o /dev/null "http://127.0.0.1:$port/readyz" 2>/dev/null; }
for _ in $(seq 1 60); do ready && break; sleep 1; done

: > "$work/stats.txt"
(while :; do docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$name" >> "$work/stats.txt" 2>/dev/null || true; sleep 5; done) &
stats_pid=$!

"$work/bin/veritra-load" -target "http://127.0.0.1:$port" -setup-token-file "$work/secrets/setup_token" \
  -profile "$tier" -metrics "http://127.0.0.1:$metrics_port/metrics" -out "$result.json" "$@" > "$result.log" 2>&1 &
load_pid=$!
if [ "$scenario" != load ]; then
  until grep -q '^load: measuring' "$result.log" || ! kill -0 "$load_pid" 2>/dev/null; do sleep 1; done
  sleep $(( duration / 3 ))
  start=$(date +%s)
  if [ "$scenario" = backup ]; then
    docker exec "$name" /usr/local/bin/messenger-server scheduled-backup >/dev/null
    echo "scenario: scheduled-backup finished in $(( $(date +%s) - start )) s" | tee -a "$result.log"
  else
    docker restart -t 30 "$name" >/dev/null
    until ready; do sleep 0.5; done
    echo "scenario: ready again $(( $(date +%s) - start )) s after the restart began" | tee -a "$result.log"
  fi
fi
status=0
wait "$load_pid" || status=$?
kill "$stats_pid" 2>/dev/null || true
stats_pid=
cat "$result.log"
awk -v limit="$memory" '{ cpu = $1; sub("%", "", cpu); if (cpu + 0 > maxcpu) maxcpu = cpu + 0
       mem = $2; unit = mem; gsub(/[0-9.]/, "", unit); value = mem; gsub(/[^0-9.]/, "", value)
       f = (unit == "GiB") ? 1024 : (unit == "KiB") ? 1 / 1024 : 1; if (value * f > maxmem) maxmem = value * f }
     END { printf "container peak: cpu %.0f%% of one core, memory %.0f MiB (limit %s)\n", maxcpu, maxmem, limit }' "$work/stats.txt" | tee -a "$result.log"
du -sh "$work/data" 2>/dev/null | awk '{ print "data directory: " $1 }' | tee -a "$result.log"
echo "results: $result.json and $result.log"
exit "$status"
