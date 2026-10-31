#!/bin/sh
# Builds the Rust crypto library for the desktop app on this machine and puts
# it where the Flutter CMake build bundles it (Stage 3, decision D10).
#
#   scripts/build-desktop-crypto.sh linux     -> mobile/linux/crypto/
#   scripts/build-desktop-crypto.sh macos     -> mobile/macos/crypto/
#
# macOS links the static library into the app binary
# (mobile/macos/Flutter/Crypto.xcconfig), like iOS.
# Windows uses scripts/build-desktop-crypto.ps1 on a Windows machine.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CRATE="$ROOT/crypto/rust"
PLATFORM=${1:-}
# rustup reads rust-toolchain.toml from the working directory, so run cargo and
# rustc from inside the repository whatever directory the caller started in.
cd "$ROOT"

fail() {
  echo "$*" >&2
  exit 1
}

# is_hex VALUE LENGTH: VALUE is exactly LENGTH lowercase hex characters.
is_hex() {
  [ "${#1}" -eq "$2" ] || return 1
  case $1 in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
}

# Reads what is about to be built before cargo runs. Every value is captured by
# assignment and checked, so a failed or malformed read stops the build instead
# of being written into build-info.txt.
capture_provenance() {
  revision=$(git -C "$ROOT" rev-parse --verify HEAD) ||
    fail "crypto provenance: cannot read the source revision"
  is_hex "$revision" 40 || fail "crypto provenance: malformed source revision: $revision"
  if command -v sha256sum >/dev/null 2>&1; then
    lock_line=$(sha256sum "$CRATE/Cargo.lock") || fail "crypto provenance: cannot hash Cargo.lock"
  else
    lock_line=$(shasum -a 256 "$CRATE/Cargo.lock") || fail "crypto provenance: cannot hash Cargo.lock"
  fi
  lock_hash=${lock_line%% *}
  is_hex "$lock_hash" 64 || fail "crypto provenance: malformed Cargo.lock hash: $lock_hash"
  # Uncommitted or untracked crate sources mean the library is not exactly
  # source_revision. The ignored target directory does not count.
  tree_status=$(git -C "$ROOT" status --porcelain --untracked-files=normal -- crypto/rust) ||
    fail "crypto provenance: cannot read the crypto/rust tree status"
  if [ -n "$tree_status" ]; then
    source_tree_dirty=true
  else
    source_tree_dirty=false
  fi
  rustc_info=$(cd "$CRATE" && rustc -Vv) || fail "crypto provenance: rustc -Vv failed"
  case $rustc_info in
    "rustc "*) ;;
    *) fail "crypto provenance: unexpected rustc -Vv output" ;;
  esac
  printf '%s\n' "$rustc_info" | grep -q '^release: [0-9]' ||
    fail "crypto provenance: rustc -Vv output has no release line"
}

write_metadata() {
  destination=$1
  mkdir -p "$destination"
  {
    echo "source_revision=$revision"
    echo "cargo_lock_sha256=$lock_hash"
    echo "source_tree_dirty=$source_tree_dirty"
    printf '%s\n' "$rustc_info"
  } > "$destination/build-info.txt"
  (cd "$CRATE" && cargo metadata --locked --format-version 1) | \
    python3 "$ROOT/scripts/cargo-license-metadata.py" > "$destination/cargo-metadata.json"
  cp "$CRATE/include/veritra_crypto.h" "$destination/veritra_crypto.h"
}

case "$PLATFORM" in
  linux)
    if [ "$(uname -s)" != "Linux" ]; then
      echo "build the Linux library on Linux (or in WSL2)" >&2
      exit 2
    fi
    capture_provenance
    # Pin the output directory over CARGO_TARGET_DIR and build.target-dir, and
    # remove the old binary so a build that writes nothing cannot package it.
    rm -f "$CRATE/target/release/libprivate_messenger_crypto.so"
    (cd "$CRATE" && cargo build --locked --release --target-dir "$CRATE/target")
    output="$ROOT/mobile/linux/crypto"
    mkdir -p "$output"
    cp "$CRATE/target/release/libprivate_messenger_crypto.so" "$output/"
    write_metadata "$output/metadata"
    echo "Linux crypto library ready in $output"
    ;;
  macos)
    if [ "$(uname -s)" != "Darwin" ]; then
      echo "build the macOS library on a Mac" >&2
      exit 2
    fi
    # Match the Runner's deployment target so the linker does not warn.
    export MACOSX_DEPLOYMENT_TARGET=10.15
    capture_provenance
    for target in aarch64-apple-darwin x86_64-apple-darwin; do
      rm -f "$CRATE/target/$target/release/libprivate_messenger_crypto.a"
      cargo build --manifest-path "$CRATE/Cargo.toml" --locked --release --target "$target" \
        --target-dir "$CRATE/target"
    done
    output="$ROOT/mobile/macos/crypto"
    rm -rf "$output"
    mkdir -p "$output"
    # One universal static library; Xcode force-loads it into the app binary.
    lipo -create \
      "$CRATE/target/aarch64-apple-darwin/release/libprivate_messenger_crypto.a" \
      "$CRATE/target/x86_64-apple-darwin/release/libprivate_messenger_crypto.a" \
      -output "$output/libprivate_messenger_crypto.a"
    write_metadata "$output/metadata"
    echo "macOS crypto library ready in $output"
    ;;
  *)
    echo "usage: $0 linux|macos (use build-desktop-crypto.ps1 on Windows)" >&2
    exit 2
    ;;
esac
