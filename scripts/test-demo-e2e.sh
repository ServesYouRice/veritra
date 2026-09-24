#!/bin/sh
set -eu
# Live test of the demo message flow (Stages 1.9 and 4): real OpenMLS
# clients against a local server that the test starts, stops and restarts
# to check offline use.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TEMP_ROOT"' EXIT INT TERM

(cd "$ROOT/server" && go build -trimpath -o "$TEMP_ROOT/veritra-server" ./cmd/messenger-server)
(cd "$ROOT/crypto/rust" && cargo build --locked --release)

# flutter test resolves the project from the current directory, not from the
# path it is given, so it must run from the Flutter project root.
cd "$ROOT/mobile"
VERITRA_DEMO_E2E_SERVER="$TEMP_ROOT/veritra-server" \
VERITRA_DEMO_E2E_DATA="$TEMP_ROOT/data" \
VERITRA_DEMO_E2E_PORT="${VERITRA_DEMO_E2E_PORT:-18082}" \
VERITRA_CRYPTO_LIBRARY="$ROOT/crypto/rust/target/release/libprivate_messenger_crypto.so" \
  flutter test test/demo_e2e_test.dart
