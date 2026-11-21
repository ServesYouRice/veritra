#!/usr/bin/env bash
# Capacity run for one host tier (card I47, docs/operations.md "Capacity
# contract"). Builds the server and server/cmd/veritra-load, starts the
# server in production mode in a container limited to the tier's CPU and
# memory, seeds it with the tier's synthetic dataset through the public API,
# runs one scenario and prints the report plus peak container CPU/memory.
#
#   scripts/capacity.sh <s|m|c8> [load|backup|restart] [veritra-load flags...]
#
#   load     busy-hour load only
#   backup   scheduled-backup (VACUUM INTO + restore drill) a third into the
#            measured window
#   restart  `docker restart -t 30` (SIGTERM, 25 s drain) a third into the
#            measured window
#
# Tier c8 (package C8, docs/designs/C8-bigger-communities.md) is one group of
# 500 accounts on the m container (2 CPUs, 2 GiB), with the member limit set
# to 500 and deliveries a minute to 1,002, the design's step 2 minimum.
# Resize it with -group-size (the load tool raises the account count to fit).
# Seeding a group above 100 adds the other members one write at a time, and
# every write reserves 1 + the member limit deliveries (501 here), so at 1,002
# a minute one account can add about 2 members a minute and seeding 500 takes
# hours. For a quick run raise the budget for the whole run (and say so when
# reporting): VERITRA_CAPACITY_SERVER_ENV=PRIVATE_MESSENGER_LIMIT_DELIVERIES_PER_MINUTE=100000
# These server settings are forwarded to the container; set
# VERITRA_CAPACITY_SERVER_ENV="PRIVATE_MESSENGER_LIMIT_X=1 PRIVATE_MESSENGER_LIMIT_Y=2"
# to override or add any (a later value wins). The container takes no other
# setting from the host's environment.
#
# Needs Go, Docker and the busybox:1.37.0 image, or, with
# VERITRA_CAPACITY_HOST=1, no Docker: the server then runs as a plain host
# process (scenario load only; no CPU or memory limit unless
# VERITRA_CAPACITY_CPUS="0-1" pins it with taskset and GOMEMLIMIT is set), and
# the peak figures are the process's own (VmHWM, CPU share of one core). Use
# it where Docker cannot run, and label the numbers as host-process numbers. Everything is local and
# synthetic; the data directory is deleted afterwards unless
# VERITRA_CAPACITY_KEEP=1. Results go to $VERITRA_CAPACITY_DIR (default a
# new temporary directory). A soak on the owner's host, for example:
#   scripts/capacity.sh s load -rate 2 -duration 2h
set -euo pipefail

tier=${1:?usage: scripts/capacity.sh <s|m|c8> [load|backup|restart] [veritra-load flags...]}
scenario=${2:-load}
shift $(( $# >= 2 ? 2 : $# ))
case "$tier" in
  s) cpus=1; memory=1g ;;
  m) cpus=2; memory=2g ;;
  c8) cpus=2; memory=2g; tier_env="PRIVATE_MESSENGER_LIMIT_CONVERSATION_MEMBERS=500 PRIVATE_MESSENGER_LIMIT_DELIVERIES_PER_MINUTE=1002" ;;
  *) echo "tier must be s, m or c8" >&2; exit 2 ;;
esac
tier_env=${tier_env:-}
host_mode=${VERITRA_CAPACITY_HOST:-0}
if [ "$host_mode" = 1 ] && [ "$scenario" != load ]; then echo "VERITRA_CAPACITY_HOST=1 runs the load scenario only" >&2; exit 2; fi
# server_env holds the NAME=value settings handed to the server, in order.
# shellcheck disable=SC2206
server_env=($tier_env ${VERITRA_CAPACITY_SERVER_ENV:-})
for entry in "${server_env[@]}"; do
  case "$entry" in PRIVATE_MESSENGER_*=*) ;; *) echo "VERITRA_CAPACITY_SERVER_ENV takes PRIVATE_MESSENGER_NAME=value entries" >&2; exit 2 ;; esac
done
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
server_pid=
cleanup() {
  if [ -n "$stats_pid" ]; then kill "$stats_pid" 2>/dev/null || true; fi
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  if [ "$host_mode" != 1 ]; then docker rm -f "$name" >/dev/null 2>&1 || true; fi
  if [ "${VERITRA_CAPACITY_KEEP:-0}" != 1 ]; then rm -rf "$work/data" "$work/secrets"; fi
}
trap cleanup EXIT

(cd "$root/server" && CGO_ENABLED=0 go build -trimpath -o "$work/bin/messenger-server" ./cmd/messenger-server \
  && go build -o "$work/bin/veritra-load" ./cmd/veritra-load)
"$work/bin/messenger-server" generate-setup-token > "$work/secrets/setup_token"
chmod 600 "$work/secrets/setup_token"
if [ "$host_mode" = 1 ]; then
  # Host process: no container, so no CPU or memory limit of its own. The
  # load tool and the server share the machine; trust loopback so each
  # simulated device keeps its own X-Forwarded-For address.
  (
    cd "$work"
    exec env PRIVATE_MESSENGER_ENV=production PRIVATE_MESSENGER_DATA_DIR="$work/data" \
      PRIVATE_MESSENGER_ADDR="127.0.0.1:$port" PRIVATE_MESSENGER_MANAGEMENT_ADDR="127.0.0.1:$metrics_port" \
      PRIVATE_MESSENGER_TRUSTED_PROXIES=127.0.0.0/8 \
      PRIVATE_MESSENGER_SETUP_TOKEN_FILE="$work/secrets/setup_token" \
      PRIVATE_MESSENGER_ENABLE_METRICS=1 PRIVATE_MESSENGER_LOG_FORMAT=json \
      ${VERITRA_CAPACITY_GOMEMLIMIT:+GOMEMLIMIT=$VERITRA_CAPACITY_GOMEMLIMIT} \
      "${server_env[@]}" \
      ${VERITRA_CAPACITY_CPUS:+taskset -c "$VERITRA_CAPACITY_CPUS"} "$work/bin/messenger-server" serve
  ) > "$work/server.log" 2>&1 &
  server_pid=$!
else
  docker build -q -t veritra-capacity:local -f - "$work/bin" >/dev/null <<'EOF'
FROM busybox:1.37.0
COPY messenger-server /usr/local/bin/messenger-server
# Production refuses a wildcard metrics listener, so bind the container IP.
ENTRYPOINT ["/bin/sh", "-c", "PRIVATE_MESSENGER_MANAGEMENT_ADDR=$(hostname -i):9090 exec /usr/local/bin/messenger-server serve"]
EOF
  docker rm -f "$name" >/dev/null 2>&1 || true
  # The container sees the load tool through Docker's bridge gateway; trusting
  # 172.16.0.0/12 lets each simulated device keep its own X-Forwarded-For
  # address, as phones behind Traefik do.
  env_flags=()
  for entry in "${server_env[@]}"; do env_flags+=(-e "$entry"); done
  docker run -d --name "$name" --user "$(id -u):$(id -g)" \
    --cpus "$cpus" --memory "$memory" --memory-swap "$memory" \
    -p "127.0.0.1:$port:8080" -p "127.0.0.1:$metrics_port:9090" \
    -v "$work/data:/data" -v "$work/secrets:/run/secrets:ro" --tmpfs /tmp:size=64m \
    -e PRIVATE_MESSENGER_ENV=production -e PRIVATE_MESSENGER_DATA_DIR=/data \
    -e PRIVATE_MESSENGER_ADDR=:8080 -e PRIVATE_MESSENGER_TRUSTED_PROXIES=172.16.0.0/12 \
    -e PRIVATE_MESSENGER_SETUP_TOKEN_FILE=/run/secrets/setup_token \
    -e PRIVATE_MESSENGER_ENABLE_METRICS=1 -e PRIVATE_MESSENGER_LOG_FORMAT=json \
    ${VERITRA_CAPACITY_GOMEMLIMIT:+-e GOMEMLIMIT=$VERITRA_CAPACITY_GOMEMLIMIT} \
    "${env_flags[@]}" \
    veritra-capacity:local >/dev/null
fi

ready() { curl -fsS -o /dev/null "http://127.0.0.1:$port/readyz" 2>/dev/null; }
for _ in $(seq 1 60); do ready && break; sleep 1; done

: > "$work/stats.txt"
if [ "$host_mode" = 1 ]; then
  # CPU is the share of one core over the 5 s interval (utime + stime ticks),
  # memory the process's peak resident set so far (VmHWM), in MiB.
  (prev=$(awk '{print $14 + $15}' "/proc/$server_pid/stat" 2>/dev/null || echo 0)
   while kill -0 "$server_pid" 2>/dev/null; do
     sleep 5
     now=$(awk '{print $14 + $15}' "/proc/$server_pid/stat" 2>/dev/null || echo "$prev")
     hwm=$(awk '/^VmHWM:/ {print $2 / 1024}' "/proc/$server_pid/status" 2>/dev/null || echo 0)
     awk -v d=$(( now - prev )) -v h="$hwm" -v hz="$(getconf CLK_TCK)" 'BEGIN { printf "%.0f%% %.1fMiB\n", d / hz / 5 * 100, h }' >> "$work/stats.txt"
     prev=$now
   done) &
else
  (while :; do docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$name" >> "$work/stats.txt" 2>/dev/null || true; sleep 5; done) &
fi
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
if [ "$host_mode" = 1 ]; then peak_what="host process"; peak_limit="none"; else peak_what=container; peak_limit=$memory; fi
awk -v limit="$peak_limit" -v what="$peak_what" '{ cpu = $1; sub("%", "", cpu); if (cpu + 0 > maxcpu) maxcpu = cpu + 0
       mem = $2; unit = mem; gsub(/[0-9.]/, "", unit); value = mem; gsub(/[^0-9.]/, "", value)
       f = (unit == "GiB") ? 1024 : (unit == "KiB") ? 1 / 1024 : 1; if (value * f > maxmem) maxmem = value * f }
     END { printf "%s peak: cpu %.0f%% of one core, memory %.0f MiB (limit %s)\n", what, maxcpu, maxmem, limit }' "$work/stats.txt" | tee -a "$result.log"
# Other work on the machine changes every latency above; the load average is
# the way to see that afterwards.
if [ -r /proc/loadavg ]; then echo "host load average at the end (1/5/15 min): $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) CPUs" | tee -a "$result.log"; fi
du -sh "$work/data" 2>/dev/null | awk '{ print "data directory: " $1 }' | tee -a "$result.log"
echo "results: $result.json and $result.log"
exit "$status"
