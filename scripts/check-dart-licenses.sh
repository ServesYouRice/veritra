#!/usr/bin/env sh
set -eu

cache=${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev
if [ ! -d "$cache" ]; then
  echo "Dart package cache is unavailable; run flutter pub get first" >&2
  exit 1
fi

missing=0
count=0
for package in "$cache"/*; do
  [ -d "$package" ] || continue
  count=$((count + 1))
  if ! find "$package" -maxdepth 1 -type f \
    \( -iname 'LICENSE*' -o -iname 'COPYING*' \) | grep -q .; then
    echo "Dart dependency lacks a packaged license: $(basename "$package")" >&2
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  exit 1
fi
echo "Dart dependency license files present: $count packages"
