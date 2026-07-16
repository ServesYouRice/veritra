#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

# Keep gofmt and go vet as distinct checks so a formatting failure does not mask
# vet output (and vice versa); each reports its own result.
go_lint='unformatted="$(gofmt -l .)"; if [ -n "$unformatted" ]; then echo "gofmt needed:"; echo "$unformatted"; exit 1; fi; go vet ./...'
if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/server" && sh -c "$go_lint")
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/server golang:1.25@sha256:c138bff780910acf4254ab3a6f7ff0f64bbd841f27bd82bfa986fe122c109538 sh -c "$go_lint"
fi

if command -v cargo >/dev/null 2>&1; then
  (cd "$ROOT/crypto/rust" && cargo fmt --check && cargo clippy --all-targets -- -D warnings)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/crypto/rust rust:1.90@sha256:e227f20ec42af3ea9a3c9c1dd1b2012aa15f12279b5e9d5fb890ca1c2bb5726c sh -c 'rustup component add rustfmt clippy >/dev/null && cargo fmt --check && cargo clippy --all-targets -- -D warnings'
fi

if command -v flutter >/dev/null 2>&1; then
  (cd "$ROOT/mobile" && flutter pub get --enforce-lockfile && flutter analyze && dart format --set-exit-if-changed .)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/mobile ghcr.io/cirruslabs/flutter:3.44.0@sha256:46691e311715845de03a3ba4753a475476936805b29431b1f00f1816981033f8 sh -c 'flutter pub get --enforce-lockfile && flutter analyze && dart format --set-exit-if-changed .'
fi
