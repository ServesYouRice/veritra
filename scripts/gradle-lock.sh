#!/bin/sh
# Writes or checks the Android Gradle dependency locks and checksums.
#
#   scripts/gradle-lock.sh write [--dry-run]   regenerate gradle/locks/*.lockfile
#                                              and gradle/verification-metadata.xml
#   scripts/gradle-lock.sh check               validate what is committed
#
# `write` needs a host with JDK 17, Flutter (the pinned version), the Rust
# toolchain for the Android crypto libraries and the Android SDK: Gradle must
# configure the real Android build to resolve its dependencies. It cannot run on
# a machine without them, so it is run by the owner or a CI job and the result
# is committed in a reviewed pull request. The repository's build never writes
# the files itself. Not run in this repository's authoring session (no SDK).
#
# Why both files: the lockfiles pin the version of every resolved dependency
# (a changed version fails the build); the verification metadata pins the
# sha256 of every artifact, including the Gradle and Android plugins, which the
# lockfiles do not cover (settings.gradle.kts `plugins {}`).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ANDROID="$ROOT/mobile/android"
MODE=${1:-}
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1

usage() { echo "usage: $0 write [--dry-run] | check" >&2; exit 2; }

run() {
  echo "+ $*"
  [ "$DRY" -eq 1 ] || "$@"
}

case $MODE in
  check)
    exec python3 "$ROOT/scripts/check-gradle-locks.py" "$ANDROID" --require-files
    ;;
  write)
    [ "$DRY" -eq 1 ] || {
      [ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ] || { echo "gradle-lock: set ANDROID_HOME to the Android SDK" >&2; exit 1; }
      . "$ROOT/scripts/repro/env.sh"
      check_java
      check_flutter
    }
    # Start from nothing: a stale lock would pin what it already knows and
    # hide a dependency that is no longer used.
    run rm -rf "$ANDROID/gradle/locks" "$ANDROID/gradle/verification-metadata.xml"
    run sh "$ROOT/scripts/build-mobile-crypto.sh" android
    run sh -c "cd '$ROOT/mobile' && flutter pub get --enforce-lockfile"
    # One normal build creates local.properties, gradlew and the plugin list.
    run sh -c "cd '$ROOT/mobile' && flutter build apk --release --flavor play --no-tree-shake-icons"
    # Both flavors and the debug types resolve different configurations.
    run sh -c "cd '$ANDROID' && ./gradlew --write-locks --write-verification-metadata sha256 dependencies :app:assemblePlayRelease :app:assembleFdroidRelease :app:assemblePlayDebug"
    run python3 "$ROOT/scripts/check-gradle-locks.py" "$ANDROID" --require-files
    echo "Review the diff of mobile/android/gradle/ and commit it in a pull request."
    ;;
  *) usage ;;
esac
