#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_ROOT=$(mktemp -d)
PORT=${VERITRA_CONTRACT_PORT:-18081}
BASE_URL="http://127.0.0.1:$PORT"
# The device-link contract (L1-3) runs against its own server: a link needs
# six requests on the per-address credential budget (ten a minute), which
# the main contract test already spends.
LINK_PORT=${VERITRA_CONTRACT_LINK_PORT:-$((PORT + 1))}
LINK_BASE_URL="http://127.0.0.1:$LINK_PORT"
# The sealed sender contract (L2-3) needs the switch on, which the other
# two servers keep off.
SEALED_PORT=${VERITRA_CONTRACT_SEALED_PORT:-$((PORT + 2))}
SEALED_BASE_URL="http://127.0.0.1:$SEALED_PORT"
SERVER_PIDS=""

cleanup() {
  for pid in $SERVER_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

(cd "$ROOT/server" && go build -trimpath -o "$TEMP_ROOT/veritra-server" ./cmd/messenger-server)
(cd "$ROOT/crypto/rust" && cargo build --locked --release)

# start_server NAME PORT [SEALED]: a fresh development server with its own
# data; SEALED 1 turns on sealed sender.
start_server() {
  PRIVATE_MESSENGER_SEALED_SENDER=${3:-0} \
  PRIVATE_MESSENGER_ENV=development \
  PRIVATE_MESSENGER_SETUP_TOKEN=contract-setup-token \
  PRIVATE_MESSENGER_LOG_LEVEL=error \
  "$TEMP_ROOT/veritra-server" serve \
    --addr "127.0.0.1:$2" \
    --data-dir "$TEMP_ROOT/data-$1" >"$TEMP_ROOT/server-$1.log" 2>&1 &
  SERVER_PIDS="$SERVER_PIDS $!"
}

# wait_ready NAME BASE_URL
wait_ready() {
  ready=0
  # Each probe is bounded too, so one hung request cannot stall the wait:
  # at most 80 x (2 s + 0.25 s).
  for _ in $(seq 1 80); do
    if curl --fail --silent --connect-timeout 1 --max-time 2 "$2/healthz" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.25
  done
  if [ "$ready" -ne 1 ]; then
    echo "contract server $1 did not become ready" >&2
    sed -n '1,120p' "$TEMP_ROOT/server-$1.log" >&2
    exit 1
  fi
}

start_server main "$PORT"
start_server link "$LINK_PORT"
start_server sealed "$SEALED_PORT" 1
wait_ready main "$BASE_URL"
wait_ready link "$LINK_BASE_URL"
wait_ready sealed "$SEALED_BASE_URL"

# flutter test resolves the project from the current directory, not from the
# path it is given, so it must run from the Flutter project root.
cd "$ROOT/mobile"
VERITRA_CONTRACT_BASE_URL="$BASE_URL" \
VERITRA_CONTRACT_LINK_BASE_URL="$LINK_BASE_URL" \
VERITRA_CONTRACT_SEALED_BASE_URL="$SEALED_BASE_URL" \
VERITRA_CRYPTO_LIBRARY="$ROOT/crypto/rust/target/release/libprivate_messenger_crypto.so" \
  flutter test test/api_contract_test.dart
