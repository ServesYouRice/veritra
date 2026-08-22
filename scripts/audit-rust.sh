#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CRATE="$ROOT/crypto/rust"

# OpenMLS 0.8.1 is the latest released coordinated stack. The parseable policy
# owns the six narrowly scoped exceptions, their rationale and the UTC review
# deadline. Fail if the unused AEAD crates enter the normal build graph or if
# Veritra stops pinning the reviewed classical suite.
sh "$ROOT/scripts/check-rust-audit-expiry.sh" --self-test
ignore_flags=$(sh "$ROOT/scripts/check-rust-audit-expiry.sh" --print-ignores)
expected_audit_version=$(sh "$ROOT/scripts/check-rust-audit-expiry.sh" --print-cargo-audit-version)
if ! command -v cargo >/dev/null 2>&1; then
  echo "Rust audit blocked: cargo is not installed" >&2
  exit 1
fi
actual_audit_version=$(cargo audit --version | awk '{print $2}')
if [ "$actual_audit_version" != "$expected_audit_version" ]; then
  echo "cargo-audit version mismatch: expected $expected_audit_version, got $actual_audit_version" >&2
  exit 1
fi
tree=$(cd "$CRATE" && cargo tree --locked --target all -e normal --prefix none)
for package in libcrux-aesgcm libcrux-chacha20poly1305; do
  if printf '%s\n' "$tree" | grep -q "^${package} v"; then
    echo "Rust audit exception is unsafe: ${package} entered the build graph" >&2
    exit 1
  fi
done

suite='const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;'
if ! grep -Fqx "$suite" "$CRATE/src/mls.rs"; then
  echo "Rust audit exceptions require the reviewed classical MLS ciphersuite" >&2
  exit 1
fi

cd "$CRATE"
# Re-check immediately before the audit so a long dependency-graph scan cannot
# carry an exception across its UTC deadline.
sh "$ROOT/scripts/check-rust-audit-expiry.sh"
# Policy IDs are validated before they reach this command. Split only the
# checker-produced option list, then pass each option as a quoted argument.
set -- $ignore_flags
cargo audit "$@"
