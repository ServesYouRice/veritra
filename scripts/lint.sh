#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
sh "$ROOT/scripts/check-go-toolchain.sh"
GO_VERSION="$(tr -d '[:space:]' < "$ROOT/.go-version")"

# Keep gofmt and go vet as distinct checks so a formatting failure does not mask
# vet output (and vice versa); each reports its own result.
go_lint='unformatted="$(gofmt -l .)"; if [ -n "$unformatted" ]; then echo "gofmt needed:"; echo "$unformatted"; exit 1; fi; go vet ./...'
if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/server" && sh -c "$go_lint")
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/server "golang:${GO_VERSION}@sha256:6c2a5538f964f1c82f97ad14988bf05de100d922d159d0e398b54c7b0ca0c6c9" sh -c "$go_lint"
fi

if command -v cargo >/dev/null 2>&1; then
  (cd "$ROOT/crypto/rust" && cargo fmt --check && cargo clippy --all-targets -- -D warnings)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/crypto/rust rust:1.91@sha256:867f1d1162913c401378a8504fb17fe2032c760dc316448766f150a130204aad sh -c 'rustup component add rustfmt clippy >/dev/null && cargo fmt --check && cargo clippy --all-targets -- -D warnings'
fi

if command -v flutter >/dev/null 2>&1; then
  (cd "$ROOT/mobile" && flutter pub get --enforce-lockfile && flutter analyze && dart format --set-exit-if-changed .)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/mobile ghcr.io/cirruslabs/flutter:3.44.0@sha256:46691e311715845de03a3ba4753a475476936805b29431b1f00f1816981033f8 sh -c 'flutter pub get --enforce-lockfile && flutter analyze && dart format --set-exit-if-changed .'
fi
