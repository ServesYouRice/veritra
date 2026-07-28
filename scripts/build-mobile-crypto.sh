#!/bin/sh
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
  env "CARGO_TARGET_${env_name}_LINKER=$linker" \
    "CC_${target}=$linker" \
    cargo build --manifest-path "$CRATE/Cargo.toml" --locked --release --target "$target"
  mkdir -p "$output/$abi"
  cp "$CRATE/target/$target/release/libprivate_messenger_crypto.so" "$output/$abi/"
}

build_ios() {
  output="$ROOT/mobile/ios/Frameworks/VeritraCrypto.xcframework"
  staging="$CRATE/target/veritra-ios-simulator"
  rm -rf "$output" "$staging"
  mkdir -p "$staging"
  cargo build --manifest-path "$CRATE/Cargo.toml" --locked --release --target aarch64-apple-ios
  cargo build --manifest-path "$CRATE/Cargo.toml" --locked --release --target aarch64-apple-ios-sim
  cargo build --manifest-path "$CRATE/Cargo.toml" --locked --release --target x86_64-apple-ios
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
  android) build_android ;;
  ios) build_ios ;;
  *) echo "usage: $0 android|ios" >&2; exit 2 ;;
esac
