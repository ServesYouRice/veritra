#!/usr/bin/env sh
# Decision D11: demo builds run unreviewed crypto through
# mobile/lib/main_demo.dart only. Release builds use mobile/lib/main.dart,
# which must keep crypto unavailable. This check keeps the two apart.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$ROOT/mobile/lib"
MAIN="$LIB/main.dart"
DEMO="$LIB/main_demo.dart"
NATIVE="$LIB/crypto/native_crypto_service.dart"
TRANSPORT="$LIB/core/transport_policy.dart"
fail=0

# forbid LABEL PATTERN [ALLOWED_FILE...]: every file under mobile/lib whose
# text matches the extended regex PATTERN fails the check, unless its path is
# exactly one of ALLOWED_FILE. Symlinks are followed; a scan error fails.
forbid() {
  label=$1
  pattern=$2
  shift 2
  status=0
  matches=$(grep -RlE -e "$pattern" "$LIB") || status=$?
  if [ "$status" -gt 1 ]; then
    echo "demo boundary: cannot scan mobile/lib for $label" >&2
    fail=1
    return 0
  fi
  offenders=
  saved_ifs=$IFS
  IFS='
'
  set -f
  for file in $matches; do
    allowed_file=0
    for allowed in "$@"; do
      if [ "$file" = "$allowed" ]; then
        allowed_file=1
      fi
    done
    if [ "$allowed_file" -eq 0 ]; then
      offenders="$offenders  $file
"
    fi
  done
  set +f
  IFS=$saved_ifs
  if [ -n "$offenders" ]; then
    echo "demo boundary: $label outside its allowed files:" >&2
    printf '%s' "$offenders" >&2
    fail=1
  fi
  return 0
}

if [ ! -d "$LIB" ]; then
  echo "demo boundary: mobile/lib is missing" >&2
  exit 1
fi

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
# Only main_demo.dart may reach the native service or the demo transport. Any
# mention counts (constructor, tear-off, static member, type, alias), and any
# reference to the native service library (import, export, conditional
# import, re-export). Exemptions are exact paths and per pattern.
forbid "the native crypto service" \
  '(^|[^A-Za-z0-9_$])NativeCryptoService([^A-Za-z0-9_$]|$)' "$DEMO" "$NATIVE"
forbid "the native crypto service library" 'native_crypto_service\.dart' "$DEMO"
forbid "the demo transport" \
  'TransportPolicy[[:space:]]*\.[[:space:]]*demo([^A-Za-z0-9_$]|$)' "$DEMO" "$TRANSPORT"
# TransportPolicy(allowLoopbackHttp: true) is the demo transport by another name.
forbid "a loopback HTTP transport" 'allowLoopbackHttp[[:space:]]*:' "$TRANSPORT"
for workflow in "$ROOT"/.github/workflows/release*.yml; do
  [ -f "$workflow" ] || continue
  if grep -Eq 'main_demo|VERITRA_DEMO' "$workflow"; then
    echo "demo boundary: $workflow must not build the demo entry point" >&2
    fail=1
  fi
done

[ "$fail" -eq 0 ] || exit 1
echo "demo boundary intact: release entry keeps crypto unavailable"
