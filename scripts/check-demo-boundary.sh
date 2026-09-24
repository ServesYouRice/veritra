#!/usr/bin/env sh
# Decision D11: demo builds run unreviewed crypto through
# mobile/lib/main_demo.dart only. Release builds use mobile/lib/main.dart,
# which must keep crypto unavailable. This check keeps the two apart.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MAIN="$ROOT/mobile/lib/main.dart"
DEMO="$ROOT/mobile/lib/main_demo.dart"
fail=0

if ! grep -q 'UnavailableCryptoService()' "$MAIN"; then
  echo "demo boundary: mobile/lib/main.dart must keep UnavailableCryptoService" >&2
  fail=1
fi
if grep -Eq 'native_crypto_service|NativeCryptoService|main_demo|TransportPolicy\.demo|demo: true' "$MAIN"; then
  echo "demo boundary: mobile/lib/main.dart must not reference demo wiring" >&2
  fail=1
fi
if ! grep -q "bool.fromEnvironment('VERITRA_DEMO')" "$DEMO"; then
  echo "demo boundary: main_demo.dart must stay guarded by VERITRA_DEMO" >&2
  fail=1
fi
# Only main_demo.dart may construct the native service or the demo transport.
offenders=$(grep -rlE 'NativeCryptoService\(|TransportPolicy\.demo' "$ROOT/mobile/lib" \
  | grep -v -e '/main_demo\.dart$' -e '/crypto/native_crypto_service\.dart$' \
      -e '/core/transport_policy\.dart$' || true)
if [ -n "$offenders" ]; then
  echo "demo boundary: demo wiring outside main_demo.dart:" >&2
  echo "$offenders" >&2
  fail=1
fi
for workflow in "$ROOT"/.github/workflows/release*.yml; do
  [ -f "$workflow" ] || continue
  if grep -Eq 'main_demo|VERITRA_DEMO' "$workflow"; then
    echo "demo boundary: $workflow must not build the demo entry point" >&2
    fail=1
  fi
done

[ "$fail" -eq 0 ] || exit 1
echo "demo boundary intact: release entry keeps crypto unavailable"
