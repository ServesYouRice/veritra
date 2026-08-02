#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CRATE="$ROOT/crypto/rust"

# OpenMLS 0.8.1 is the latest released coordinated stack. Its HPKE 0.6 lock
# includes a libcrux backend that Veritra does not enable, plus SHAKE support
# used only by experimental/PQ KEM branches. Fail if the unused AEAD crates
# ever enter the normal build graph or if Veritra stops pinning the reviewed
# classical suite. Re-review and remove these exceptions when OpenMLS releases
# support for hpke-rs 0.7+; next mandatory review: 2026-08-29.
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
cargo audit \
  --ignore RUSTSEC-2026-0209 \
  --ignore RUSTSEC-2026-0211 \
  --ignore RUSTSEC-2026-0124 \
  --ignore RUSTSEC-2026-0212 \
  --ignore RUSTSEC-2026-0207 \
  --ignore RUSTSEC-2026-0208
