#!/bin/sh
# One reproducible build of an unsigned app, from the checkout this script is in.
#
#   scripts/repro/build.sh crypto-linux|linux|android|macos OUTDIR
#
# crypto-linux  the Rust library only (fast; needs just the pinned Rust)
# linux         the desktop bundle (needs Flutter and the GTK build packages)
# android       the unsigned release APK (needs JDK 17, Android SDK and NDK)
# macos         the unsigned app (macOS only)
# Windows uses scripts\repro\build.ps1. Signing is never done here.
# OUTDIR gets the files and a sorted SHA256SUMS of them.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TARGET=${1:-}
OUT=${2:-}
[ -n "$TARGET" ] && [ -n "$OUT" ] || { echo "usage: $0 crypto-linux|linux|android|macos OUTDIR" >&2; exit 2; }
cd "$ROOT"
. "$ROOT/scripts/repro/env.sh"
check_rust
mkdir -p "$OUT"
[ -z "$(ls -A "$OUT")" ] || fail "OUTDIR $OUT is not empty"
# Uncommitted changes would be built under HEAD's timestamp: refuse, so the
# digests always describe a commit.
[ -z "$(git status --porcelain --untracked-files=normal)" ] ||
  fail "the checkout has uncommitted changes; commit or stash first"
OUT=$(CDPATH= cd -- "$OUT" && pwd)

# Release builds only: the demo entry point (main_demo.dart) is never built here.
flutter_prepare() {
  check_flutter
  (cd mobile && flutter pub get --enforce-lockfile)
}

write_sums() {
  (cd "$OUT" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | sed 's/^\.\///' |
    while IFS= read -r f; do sha256sum "$f"; done > SHA256SUMS)
}

case $TARGET in
  crypto-linux)
    [ "$(uname -s)" = Linux ] || fail "crypto-linux builds on Linux"
    sh scripts/build-desktop-crypto.sh linux
    cp mobile/linux/crypto/libprivate_messenger_crypto.so "$OUT/"
    ;;
  linux)
    [ "$(uname -s)" = Linux ] || fail "linux builds on Linux"
    sh scripts/build-desktop-crypto.sh linux
    flutter_prepare
    (cd mobile && flutter build linux --release)
    cp -R mobile/build/linux/x64/release/bundle/. "$OUT/"
    ;;
  android)
    check_java
    sh scripts/build-mobile-crypto.sh android
    flutter_prepare
    (cd mobile && flutter build apk --release --no-tree-shake-icons)
    # Unsigned on purpose (mobile/android/app/build.gradle.kts). The signing
    # step belongs to the owner and runs on the finished file, not in here.
    # Only the release APK counts: a debug or demo APK left in the checkout
    # must never be picked up and labelled as a release.
    apk=$(find mobile/build/app/outputs -path '*/release/*' -name '*.apk' | LC_ALL=C sort)
    [ -n "$apk" ] && [ "$(printf '%s\n' "$apk" | wc -l)" -eq 1 ] ||
      fail "expected exactly one release APK, found: ${apk:-none}"
    cp "$apk" "$OUT/veritra-release-unsigned.apk"
    ;;
  macos)
    [ "$(uname -s)" = Darwin ] || fail "macos builds on a Mac"
    sh scripts/build-desktop-crypto.sh macos
    flutter_prepare
    (cd mobile && flutter build macos --release)
    cp -R mobile/build/macos/Build/Products/Release/*.app "$OUT/"
    ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac
write_sums
echo "built $TARGET into $OUT"
cat "$OUT/SHA256SUMS" | head -n 20
