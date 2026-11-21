#!/bin/sh
set -eu
# C7 full mode end to end: real OpenMLS clients against a local server the
# test starts with PRIVATE_MESSENGER_C7_HISTORY=1 (mobile/test/c7_e2e_test.dart).
# Set VERITRA_CRYPTO_LIBRARY to use an already built crypto library;
# otherwise this builds it.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TEMP_ROOT"' EXIT INT TERM

(cd "$ROOT/server" && go build -trimpath -o "$TEMP_ROOT/veritra-server" ./cmd/messenger-server)
if [ -z "${VERITRA_CRYPTO_LIBRARY:-}" ]; then
  (cd "$ROOT/crypto/rust" && cargo build --locked --release)
  VERITRA_CRYPTO_LIBRARY="$ROOT/crypto/rust/target/release/libprivate_messenger_crypto.so"
fi
mkdir -p "$TEMP_ROOT/data"

cd "$ROOT/mobile"
VERITRA_C7_E2E_SERVER="$TEMP_ROOT/veritra-server" \
VERITRA_C7_E2E_DATA="$TEMP_ROOT/data" \
VERITRA_C7_E2E_PORT="${VERITRA_C7_E2E_PORT:-18093}" \
VERITRA_CRYPTO_LIBRARY="$VERITRA_CRYPTO_LIBRARY" \
  flutter test test/c7_e2e_test.dart
