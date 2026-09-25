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

write_metadata() {
  destination=$1
  mkdir -p "$destination"
  {
    echo "source_revision=$(git -C "$ROOT" rev-parse HEAD)"
    if command -v sha256sum >/dev/null 2>&1; then
      echo "cargo_lock_sha256=$(sha256sum "$CRATE/Cargo.lock" | awk '{print $1}')"
    else
      echo "cargo_lock_sha256=$(shasum -a 256 "$CRATE/Cargo.lock" | awk '{print $1}')"
    fi
    rustc -Vv
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
    (cd "$CRATE" && cargo build --locked --release)
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
    for target in aarch64-apple-darwin x86_64-apple-darwin; do
      cargo build --manifest-path "$CRATE/Cargo.toml" --locked --release --target "$target"
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
