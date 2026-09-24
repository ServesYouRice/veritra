#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
sh "$ROOT/scripts/check-go-toolchain.sh"
sh "$ROOT/scripts/check-demo-boundary.sh"
GO_VERSION="$(tr -d '[:space:]' < "$ROOT/.go-version")"
 
if command -v python3 >/dev/null 2>&1; then
  python3 "$ROOT/scripts/check-release-evidence_test.py"
  python3 "$ROOT/scripts/check-dart-retractions_test.py"
  python3 "$ROOT/scripts/check-ci-evidence_test.py"
  python3 "$ROOT/scripts/write-release-evidence_test.py"
  python3 "$ROOT/scripts/check-coverage_test.py"
elif command -v python >/dev/null 2>&1; then
  python "$ROOT/scripts/check-release-evidence_test.py"
  python "$ROOT/scripts/check-dart-retractions_test.py"
  python "$ROOT/scripts/check-ci-evidence_test.py"
  python "$ROOT/scripts/write-release-evidence_test.py"
  python "$ROOT/scripts/check-coverage_test.py"
fi

if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/server" && go test ./...)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/server "golang:${GO_VERSION}@sha256:6c2a5538f964f1c82f97ad14988bf05de100d922d159d0e398b54c7b0ca0c6c9" go test ./...
fi

if command -v cargo >/dev/null 2>&1; then
  (cd "$ROOT/crypto/rust" && cargo test)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/crypto/rust rust:1.91@sha256:867f1d1162913c401378a8504fb17fe2032c760dc316448766f150a130204aad cargo test
fi

if command -v flutter >/dev/null 2>&1; then
  (cd "$ROOT/mobile" && flutter pub get --enforce-lockfile && flutter test)
else
  docker run --rm -v "$ROOT:/workspace" -w /workspace/mobile ghcr.io/cirruslabs/flutter:3.44.0@sha256:46691e311715845de03a3ba4753a475476936805b29431b1f00f1816981033f8 sh -c 'flutter pub get --enforce-lockfile && flutter test'
fi
