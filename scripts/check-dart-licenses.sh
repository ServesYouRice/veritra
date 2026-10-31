#!/usr/bin/env sh
# Every resolved Dart dependency (hosted, git, path and SDK) must ship a
# license file. The inventory is what pub resolved for mobile/, read from
# mobile/.dart_tool/package_config.json and matched against pubspec.lock,
# not whatever happens to be in the pub cache. See check-dart-licenses.py.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG="$ROOT/mobile/.dart_tool/package_config.json"
if [ ! -f "$CONFIG" ]; then
  echo "Dart package configuration is unavailable ($CONFIG); run flutter pub get first" >&2
  exit 1
fi
exec python3 "$ROOT/scripts/check-dart-licenses.py" --config "$CONFIG" --lock "$ROOT/mobile/pubspec.lock"
