#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GO_VERSION="$(tr -d '[:space:]' < "$ROOT/.go-version")"

# An unset PRIVATE_MESSENGER_ENV means production, so the local server says
# development explicitly (tokenless loopback setup, no proxy requirement).
if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/server" && PRIVATE_MESSENGER_ENV=development go run ./cmd/messenger-server serve)
else
  docker run --rm -it -p 127.0.0.1:8080:8080 -v "$ROOT:/workspace" -w /workspace/server -e PRIVATE_MESSENGER_ENV=development -e PRIVATE_MESSENGER_ADDR=:8080 -e PRIVATE_MESSENGER_DATA_DIR=/workspace/data "golang:${GO_VERSION}@sha256:672c944cfd07599b5f1bb179869270cdc94c6254e41db4d431259693cb286b82" go run ./cmd/messenger-server serve
fi
