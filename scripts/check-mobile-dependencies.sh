#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MOBILE="$ROOT/mobile"
ANDROID="$MOBILE/android"

if [ ! -s "$MOBILE/pubspec.lock" ]; then
  echo "mobile dependency check blocked: mobile/pubspec.lock is missing" >&2
  exit 1
fi
if ! grep -Eq '^packages:' "$MOBILE/pubspec.lock" || ! grep -Eq '^sdks:' "$MOBILE/pubspec.lock"; then
  echo "mobile dependency check failed: pubspec.lock is not a complete lockfile" >&2
  exit 1
fi
hosted_count="$(grep -Ec '^    source: hosted$' "$MOBILE/pubspec.lock")"
hash_count="$(grep -Ec '^[[:space:]]+sha256:' "$MOBILE/pubspec.lock")"
if [ "$hosted_count" -eq 0 ] || [ "$hosted_count" -ne "$hash_count" ] || \
   grep -Ev '^[[:space:]]+sha256: "?[0-9a-f]{64}"?$' "$MOBILE/pubspec.lock" | grep -Eq '^[[:space:]]+sha256:'; then
  echo "mobile dependency check failed: hosted lock entries lack verified hashes" >&2
  exit 1
fi
if ! command -v dart >/dev/null 2>&1; then
  echo "mobile dependency check blocked: dart is required for retraction scanning" >&2
  exit 1
fi

OUTDATED="$(mktemp)"
cleanup() { rm -f "$OUTDATED"; }
trap cleanup EXIT INT TERM
if ! (cd "$MOBILE" && dart pub outdated --json --show-all > "$OUTDATED"); then
  echo "mobile dependency check blocked: dart pub outdated failed" >&2
  exit 1
fi
if ! python3 "$ROOT/scripts/check-dart-retractions.py" "$OUTDATED"; then
  echo "mobile dependency check failed: a retracted Dart package is present" >&2
  exit 1
fi

WRAPPER="$ANDROID/gradle/wrapper/gradle-wrapper.properties"
if [ ! -s "$WRAPPER" ] || ! grep -Eq '^distributionUrl=.*gradle-[0-9]+\.[0-9]+(\.[0-9]+)?-(bin|all)\.zip' "$WRAPPER"; then
  echo "mobile dependency check failed: Gradle wrapper is not pinned" >&2
  exit 1
fi
if grep -R -n -E 'https?://|jcenter\(\)|mavenLocal\(\)' "$ANDROID" --include='*.gradle' --include='*.gradle.kts' | grep -q .; then
  echo "mobile dependency check failed: unreviewed or insecure Gradle repository found" >&2
  exit 1
fi
if grep -R -n -E ':(latest|release|snapshot|[0-9]+\.[0-9]+\.[0-9]+\+)' "$ANDROID/app/build.gradle.kts"; then
  echo "mobile dependency check failed: dynamic Gradle dependency version found" >&2
  exit 1
fi

echo "mobile dependency policy passed: pub lock/retractions and pinned Gradle inputs"
