#!/bin/sh
set -eu
# Live end-to-end runs: real OpenMLS clients against a local server that each
# test starts (mobile/test/*_live_e2e_test.dart, mobile/test/live_e2e_harness.dart):
# C1 join, approval and removal, C3 private channels and conversion, C6
# reports, L2-3 sealed sender with the app killed mid-post, and the L1-5 run
# (register, link, message, revoke, recover, and a server that offers a
# device no signed list names).
#
# The L1-5 run needs a server built with the veritra_testhooks tag. That
# binary is built here only; it refuses to serve, and its hook refuses to
# run, outside PRIVATE_MESSENGER_ENV=development, and no release build sets
# the tag (server/cmd/messenger-server/testhooks_guard_test.go).
#
# Set VERITRA_CRYPTO_LIBRARY to use an already built crypto library;
# otherwise this builds it. Pass test file paths to run only those.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TEMP_ROOT"' EXIT INT TERM

(cd "$ROOT/server" && go build -trimpath -o "$TEMP_ROOT/veritra-server" ./cmd/messenger-server)
(cd "$ROOT/server" && go build -trimpath -tags veritra_testhooks -o "$TEMP_ROOT/veritra-server-testhooks" ./cmd/messenger-server)
if [ -z "${VERITRA_CRYPTO_LIBRARY:-}" ]; then
  (cd "$ROOT/crypto/rust" && cargo build --locked --release)
  VERITRA_CRYPTO_LIBRARY="$ROOT/crypto/rust/target/release/libprivate_messenger_crypto.so"
fi
mkdir -p "$TEMP_ROOT/data"

if [ "$#" -eq 0 ]; then
  set -- test/c1_c3_c6_live_e2e_test.dart test/sealed_live_e2e_test.dart test/l1_live_e2e_test.dart
fi

# flutter test resolves the project from the current directory.
cd "$ROOT/mobile"
VERITRA_LIVE_E2E_SERVER="$TEMP_ROOT/veritra-server" \
VERITRA_LIVE_E2E_TESTHOOK_SERVER="$TEMP_ROOT/veritra-server-testhooks" \
VERITRA_LIVE_E2E_DATA="$TEMP_ROOT/data" \
VERITRA_LIVE_E2E_PORT_BASE="${VERITRA_LIVE_E2E_PORT_BASE:-18100}" \
VERITRA_CRYPTO_LIBRARY="$VERITRA_CRYPTO_LIBRARY" \
  flutter test "$@"
