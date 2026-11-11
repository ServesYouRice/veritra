#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GO_VERSION="$(tr -d '[:space:]' < "$ROOT/.go-version")"

# An unset PRIVATE_MESSENGER_ENV means production, so the local server says
# development explicitly (tokenless loopback setup, no proxy requirement).
if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/server" && PRIVATE_MESSENGER_ENV=development go run ./cmd/messenger-server serve)
else
  docker run --rm -it -p 127.0.0.1:8080:8080 -v "$ROOT:/workspace" -w /workspace/server -e PRIVATE_MESSENGER_ENV=development -e PRIVATE_MESSENGER_ADDR=:8080 -e PRIVATE_MESSENGER_DATA_DIR=/workspace/data "golang:${GO_VERSION}@sha256:7af425da11f4fc1a9308eb704369e3f6d1c44e35bac0f874a59ade3f20fdc07e" go run ./cmd/messenger-server serve
fi
