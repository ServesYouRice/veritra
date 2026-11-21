#!/bin/sh
set -eu
# The Android rules that are plain Java (wake protocol, push endpoint, room
# calls, screen rules under mobile/android/app/src/main/java) and their JVM tests
# (mobile/android/wake-tests). Only a JDK is needed, no Android SDK; every
# *Test class is run and must exit 0.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Only the app's own package: Flutter writes a GeneratedPluginRegistrant
# under io/flutter that needs the Android SDK.
SOURCES="$ROOT/mobile/android/app/src/main/java/org/veritra/private_messenger"
TESTS="$ROOT/mobile/android/wake-tests"

if ! command -v javac >/dev/null 2>&1 || ! command -v java >/dev/null 2>&1; then
  echo "test-android-rules: javac and java (JDK 17 or newer) are required" >&2
  exit 1
fi

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT INT TERM

find "$SOURCES" "$TESTS" -name '*.java' | sort > "$OUT/sources"
# The package's Java sources compile against the JDK alone; one that needs
# the Android SDK does not belong in it (Kotlin is the place for that).
javac --release 17 -d "$OUT/classes" @"$OUT/sources"

ran=0
for test in $(cd "$TESTS" && find . -name '*Test.java' | sort); do
  class=$(printf '%s\n' "$test" | sed -e 's|^\./||' -e 's|\.java$||' -e 's|/|.|g')
  echo "== $class"
  java -ea -cp "$OUT/classes" "$class"
  ran=$((ran + 1))
done
if [ "$ran" -lt 2 ]; then
  echo "test-android-rules: expected at least 2 test classes, found $ran" >&2
  exit 1
fi
echo "test-android-rules: $ran test classes passed"
