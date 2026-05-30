#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/server" && gofmt -l . > /tmp/private-messenger-gofmt.txt && test ! -s /tmp/private-messenger-gofmt.txt && go vet ./...)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/server golang:1.25 sh -c 'gofmt -l . > /tmp/private-messenger-gofmt.txt && test ! -s /tmp/private-messenger-gofmt.txt && go vet ./...'
fi

if command -v cargo >/dev/null 2>&1; then
  (cd "$ROOT/crypto/rust" && cargo fmt --check && cargo clippy --all-targets -- -D warnings)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/crypto/rust rust:1.82 sh -c 'rustup component add rustfmt clippy >/dev/null && cargo fmt --check && cargo clippy --all-targets -- -D warnings'
fi

if command -v flutter >/dev/null 2>&1; then
  (cd "$ROOT/mobile" && flutter pub get && flutter analyze)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/mobile ghcr.io/cirruslabs/flutter:stable sh -c 'flutter pub get && flutter analyze'
fi
