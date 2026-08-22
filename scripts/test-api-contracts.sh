#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_ROOT=$(mktemp -d)
PORT=${VERITRA_CONTRACT_PORT:-18081}
BASE_URL="http://127.0.0.1:$PORT"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

(cd "$ROOT/server" && go build -trimpath -o "$TEMP_ROOT/veritra-server" ./cmd/messenger-server)
(cd "$ROOT/crypto/rust" && cargo build --locked --release)

PRIVATE_MESSENGER_SETUP_TOKEN=contract-setup-token \
PRIVATE_MESSENGER_LOG_LEVEL=error \
"$TEMP_ROOT/veritra-server" serve \
  --addr "127.0.0.1:$PORT" \
  --data-dir "$TEMP_ROOT/data" >"$TEMP_ROOT/server.log" 2>&1 &
SERVER_PID=$!

ready=0
for _ in $(seq 1 80); do
  if curl --fail --silent "$BASE_URL/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.25
done
if [ "$ready" -ne 1 ]; then
  echo "contract server did not become ready" >&2
  sed -n '1,120p' "$TEMP_ROOT/server.log" >&2
  exit 1
fi

VERITRA_CONTRACT_BASE_URL="$BASE_URL" \
VERITRA_CRYPTO_LIBRARY="$ROOT/crypto/rust/target/release/libprivate_messenger_crypto.so" \
  flutter test "$ROOT/mobile/test/api_contract_test.dart"
