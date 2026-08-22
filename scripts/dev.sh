#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GO_VERSION="$(tr -d '[:space:]' < "$ROOT/.go-version")"

if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/server" && go run ./cmd/messenger-server serve)
else
  docker run --rm -it -p 127.0.0.1:8080:8080 -v "$ROOT:/workspace" -w /workspace/server -e PRIVATE_MESSENGER_ADDR=:8080 -e PRIVATE_MESSENGER_DATA_DIR=/workspace/data "golang:${GO_VERSION}@sha256:9006890ecba0a168034d99516084099ae3114d9f2b7d6572c77f2dde57ebc980" go run ./cmd/messenger-server serve
fi
