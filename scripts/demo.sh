#!/bin/sh
# One-command local demo server (Stage 1.8, decisions D10-D12).
#
#   scripts/demo.sh            build and start the server on 127.0.0.1:8080
#   scripts/demo.sh --reset    wipe the demo data first
#   scripts/demo.sh --port N   use another port
#
# The server listens on loopback only. Demo apps reach it over plain HTTP,
# which they accept for loopback hosts only (D12). The Android emulator
# reaches it through `adb reverse`, which this script sets up when adb is
# available. Data lives in data/demo (git-ignored).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEMO_DIR="$ROOT/data/demo"
PORT=8080
RESET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --reset) RESET=1 ;;
    --port)
      shift
      PORT=${1:?--port needs a number}
      ;;
    -h | --help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown option: $1 (try --help)" >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$RESET" -eq 1 ]; then
  echo "Removing demo data in $DEMO_DIR"
  rm -rf "$DEMO_DIR"
fi
mkdir -p "$DEMO_DIR/server"

if ! command -v go >/dev/null 2>&1; then
  echo "Go is required: install the version in .go-version from https://go.dev/dl/" >&2
  exit 1
fi

echo "Building the server..."
(cd "$ROOT/server" && go build -trimpath -o "$DEMO_DIR/veritra-server" ./cmd/messenger-server)

if command -v cargo >/dev/null 2>&1; then
  echo "Building the crypto library for desktop apps..."
  (cd "$ROOT/crypto/rust" && cargo build --locked --release --quiet)
else
  echo "Skipping the crypto library: cargo not found (only needed for desktop apps)."
fi

# The setup token only matters until the owner account exists. Keep it with
# the demo data so a restart before setup shows the same one.
TOKEN_FILE="$DEMO_DIR/setup-token"
if [ ! -s "$TOKEN_FILE" ]; then
  (umask 077 && "$DEMO_DIR/veritra-server" generate-setup-token >"$TOKEN_FILE")
fi
SETUP_TOKEN=$(tr -d '[:space:]' <"$TOKEN_FILE")

ANDROID_NOTE="start an emulator, then run: adb reverse tcp:$PORT tcp:$PORT"
if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
  if adb reverse "tcp:$PORT" "tcp:$PORT" >/dev/null 2>&1; then
    ANDROID_NOTE="adb reverse is set up for the running emulator"
  fi
fi

cat <<EOF

Veritra demo server
  Server URL (every app):  http://localhost:$PORT
  Setup token (first run): $SETUP_TOKEN
  Android emulator:        $ANDROID_NOTE
  Data:                    $DEMO_DIR

Start an app (from mobile/):
  flutter run -t lib/main_demo.dart --dart-define=VERITRA_DEMO=true
See docs/demo.md for the full walkthrough. Press Ctrl+C to stop.

EOF

PRIVATE_MESSENGER_ENV=development \
PRIVATE_MESSENGER_SETUP_TOKEN="$SETUP_TOKEN" \
PRIVATE_MESSENGER_INSTANCE_NAME="Veritra demo" \
  exec "$DEMO_DIR/veritra-server" serve \
  --addr "127.0.0.1:$PORT" \
  --data-dir "$DEMO_DIR/server"
