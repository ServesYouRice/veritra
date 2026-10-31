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

# The wrapper must download a pinned Gradle over https from services.gradle.org
# (and a distributionSha256Sum, when set, must be well formed); every Gradle
# build, settings and version-catalog file, comments skipped, must be free of
# +, range, latest.* and SNAPSHOT versions. Fails if the app build script is
# missing or any input cannot be read.
if ! python3 "$ROOT/scripts/check-gradle-inputs.py" "$ANDROID"; then
  echo "mobile dependency check failed: Gradle wrapper or Gradle versions are not pinned" >&2
  exit 1
fi
# Repository declarations are what matter here; a URL inside a comment is not
# one. Strip the file:line prefix and skip lines that are entirely a comment.
gradle_repo_hits="$(
  find "$ANDROID" \( -name '*.gradle' -o -name '*.gradle.kts' \) -type f -print0 |
    xargs -0 grep -n -H -E 'https?://|jcenter\(\)|mavenLocal\(\)' |
    awk '{ body = $0; sub(/^[^:]*:[0-9]+:/, "", body); if (body !~ /^[[:space:]]*(\/\/|\/\*|\*|#)/) print }'
)"
if [ -n "$gradle_repo_hits" ]; then
  echo "mobile dependency check failed: unreviewed or insecure Gradle repository found" >&2
  echo "$gradle_repo_hits" >&2
  exit 1
fi
echo "mobile dependency policy passed: pub lock/retractions and pinned Gradle inputs"
