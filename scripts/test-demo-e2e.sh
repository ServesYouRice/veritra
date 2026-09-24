#!/bin/sh
set -eu
# Live two- and three-client test of the demo message flow (Stage 1.9):
# real OpenMLS clients against a freshly started local server.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_ROOT=$(mktemp -d)
PORT=${VERITRA_DEMO_E2E_PORT:-18082}
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

PRIVATE_MESSENGER_SETUP_TOKEN=demo-e2e-setup-token \
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
  echo "demo e2e server did not become ready" >&2
  sed -n '1,120p' "$TEMP_ROOT/server.log" >&2
  exit 1
fi

# flutter test resolves the project from the current directory, not from the
# path it is given, so it must run from the Flutter project root.
cd "$ROOT/mobile"
VERITRA_DEMO_E2E_BASE_URL="$BASE_URL" \
VERITRA_CRYPTO_LIBRARY="$ROOT/crypto/rust/target/release/libprivate_messenger_crypto.so" \
  flutter test test/demo_e2e_test.dart
