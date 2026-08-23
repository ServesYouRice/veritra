#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PLATFORM=${1:-}

verify_symbols() {
  symbols=$1
  echo "$symbols" | grep -q 'pm_crypto_abi_version'
  echo "$symbols" | grep -q 'pm_crypto_available'
  echo "$symbols" | grep -q 'pm_crypto_device_create'
  echo "$symbols" | grep -q 'pm_crypto_device_link_transcript_hash'
  echo "$symbols" | grep -q 'pm_crypto_buffer_free'
}

case "$PLATFORM" in
  android)
    ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
    if [ -z "$ndk" ] && [ -n "${ANDROID_SDK_ROOT:-}" ]; then
      ndk=$(find "$ANDROID_SDK_ROOT/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)
    fi
    llvm_nm=$(find "$ndk/toolchains/llvm/prebuilt" -path '*/bin/llvm-nm' | head -n 1)
    for abi in arm64-v8a armeabi-v7a x86_64; do
      library="$ROOT/mobile/android/app/src/main/jniLibs/$abi/libprivate_messenger_crypto.so"
      test -f "$library"
      verify_symbols "$("$llvm_nm" -D --defined-only "$library")"
    done
    ;;
  ios)
    device="$ROOT/mobile/ios/Frameworks/VeritraCrypto.xcframework/ios-arm64/libprivate_messenger_crypto.a"
    simulator="$ROOT/mobile/ios/Frameworks/VeritraCrypto.xcframework/ios-arm64_x86_64-simulator/libprivate_messenger_crypto.a"
    test -f "$device"
    test -f "$simulator"
    verify_symbols "$(nm -gU "$device")"
    verify_symbols "$(nm -gU "$simulator")"
    lipo "$simulator" -verify_arch arm64 x86_64
    ;;
  *) echo "usage: $0 android|ios" >&2; exit 2 ;;
esac

grep -q 'PM_CRYPTO_UNAVAILABLE' "$ROOT/crypto/rust/src/lib.rs"
