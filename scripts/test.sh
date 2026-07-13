#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/server" && go test ./...)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/server golang:1.25 go test ./...
fi

if command -v cargo >/dev/null 2>&1; then
  (cd "$ROOT/crypto/rust" && cargo test)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/crypto/rust rust:1.82 cargo test
fi

if command -v flutter >/dev/null 2>&1; then
  (cd "$ROOT/mobile" && flutter pub get --enforce-lockfile && flutter test)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/mobile ghcr.io/cirruslabs/flutter:3.44.0 sh -c 'flutter pub get --enforce-lockfile && flutter test'
fi
