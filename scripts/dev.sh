#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/server" && go run ./cmd/messenger-server serve)
else
  docker run --rm -it -p 127.0.0.1:8080:8080 -v "$ROOT:/workspace" -w /workspace/server -e PRIVATE_MESSENGER_ADDR=:8080 -e PRIVATE_MESSENGER_DATA_DIR=/workspace/data golang:1.25@sha256:c138bff780910acf4254ab3a6f7ff0f64bbd841f27bd82bfa986fe122c109538 go run ./cmd/messenger-server serve
fi
