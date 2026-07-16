#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

NOTICES="$ROOT/THIRD_PARTY_NOTICES.md"
missing=0

check_notice() {
  component="$1"
  if ! grep -Fq "$component" "$NOTICES"; then
    echo "missing THIRD_PARTY_NOTICES.md entry: $component" >&2
    missing=1
  fi
}

check_notice "modernc.org/sqlite"
check_notice "golang.org/x/crypto"

if grep -Eq '^openmls[[:space:]]*=' "$ROOT/crypto/rust/Cargo.toml"; then
  check_notice "aes-gcm"
  check_notice "openmls"
  check_notice "openmls_basic_credential"
  check_notice "openmls_rust_crypto"
  check_notice "openmls_traits"
  check_notice "tls_codec"
fi

if grep -Eq '^[[:space:]]+flutter_secure_storage:' "$ROOT/mobile/pubspec.yaml"; then
  check_notice "flutter_secure_storage"
fi

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "license notices: direct dependency entries present"
echo "release note: still run a full transitive license scan before publishing."
