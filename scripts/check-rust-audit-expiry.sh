#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for argument in "$@"; do
  case "$argument" in
    --now|--now=*)
    echo "clock overrides are accepted only by the direct policy test interface" >&2
    exit 1
    ;;
  esac
done
if [ -n "${VERITRA_RUST_AUDIT_NOW+x}" ]; then
  echo "clock overrides are accepted only by the direct policy test interface" >&2
  exit 1
fi

exec python3 "$ROOT/scripts/check-rust-audit-policy.py" \
  "$ROOT/crypto/rust/audit-policy.json" "$@"
