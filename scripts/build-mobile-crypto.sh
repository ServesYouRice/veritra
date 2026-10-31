#!/bin/sh
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

build_android() {
  ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
  if [ -z "$ndk" ] && [ -n "${ANDROID_SDK_ROOT:-}" ]; then
    ndk=$(find "$ANDROID_SDK_ROOT/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)
  fi
  if [ -z "$ndk" ] || [ ! -d "$ndk/toolchains/llvm/prebuilt" ]; then
    echo "Android NDK not found" >&2
    exit 1
  fi
  host=$(find "$ndk/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  bin="$host/bin"
  api=23
  output="$ROOT/mobile/android/app/src/main/jniLibs"
  rm -rf "$output"
  mkdir -p "$output"

  build_android_target aarch64-linux-android arm64-v8a "$bin/aarch64-linux-android${api}-clang" AARCH64_LINUX_ANDROID
  build_android_target armv7-linux-androideabi armeabi-v7a "$bin/armv7a-linux-androideabi${api}-clang" ARMV7_LINUX_ANDROIDEABI
  build_android_target x86_64-linux-android x86_64 "$bin/x86_64-linux-android${api}-clang" X86_64_LINUX_ANDROID

  metadata="$ROOT/mobile/android/app/src/main/assets/veritra-crypto"
  rm -rf "$metadata"
  write_metadata "$metadata"
}

build_android_target() {
  target=$1
  abi=$2
  linker=$3
  env_name=$4
  if [ ! -x "$linker" ]; then
    echo "Android linker missing for $target" >&2
    exit 1
  fi
  # Pin the output directory over CARGO_TARGET_DIR and build.target-dir, and
  # remove the old binary so a build that writes nothing cannot package it.
  rm -f "$CRATE/target/$target/release/libprivate_messenger_crypto.so"
  env "CARGO_TARGET_${env_name}_LINKER=$linker" \
    "CC_${target}=$linker" \
    cargo build --manifest-path "$CRATE/Cargo.toml" --locked --release --target "$target" \
      --target-dir "$CRATE/target"
  mkdir -p "$output/$abi"
  cp "$CRATE/target/$target/release/libprivate_messenger_crypto.so" "$output/$abi/"
}

build_ios() {
  output="$ROOT/mobile/ios/Frameworks/VeritraCrypto.xcframework"
  staging="$CRATE/target/veritra-ios-simulator"
  rm -rf "$output" "$staging"
  mkdir -p "$staging"
  for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    rm -f "$CRATE/target/$target/release/libprivate_messenger_crypto.a"
    cargo build --manifest-path "$CRATE/Cargo.toml" --locked --release --target "$target" \
      --target-dir "$CRATE/target"
  done
  lipo -create \
    "$CRATE/target/aarch64-apple-ios-sim/release/libprivate_messenger_crypto.a" \
    "$CRATE/target/x86_64-apple-ios/release/libprivate_messenger_crypto.a" \
    -output "$staging/libprivate_messenger_crypto.a"
  xcodebuild -create-xcframework \
    -library "$CRATE/target/aarch64-apple-ios/release/libprivate_messenger_crypto.a" -headers "$CRATE/include" \
    -library "$staging/libprivate_messenger_crypto.a" -headers "$CRATE/include" \
    -output "$output"
  write_metadata "$ROOT/mobile/ios/Frameworks/veritra-crypto-metadata"
}

case "$PLATFORM" in
  android) capture_provenance; build_android ;;
  ios) capture_provenance; build_ios ;;
  *) echo "usage: $0 android|ios" >&2; exit 2 ;;
esac
