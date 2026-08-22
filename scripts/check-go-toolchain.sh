#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION_FILE="$ROOT/.go-version"

if [ ! -f "$VERSION_FILE" ]; then
  echo "missing canonical Go version file: $VERSION_FILE" >&2
  exit 1
fi

GO_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
case "$GO_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *)
    echo "invalid Go version in $VERSION_FILE: $GO_VERSION" >&2
    exit 1
    ;;
esac

GO_MOD_VERSION="$(sed -n 's/^go[[:space:]][[:space:]]*//p' "$ROOT/server/go.mod" | head -n 1)"
DOCKER_DEFAULT="$(sed -n 's/^ARG GO_VERSION=//p' "$ROOT/server/Dockerfile" | head -n 1)"
DOCKER_BASE="$(sed -n 's/^FROM .*golang:\${GO_VERSION}@.*/\${GO_VERSION}/p' "$ROOT/server/Dockerfile" | head -n 1)"

if [ "$GO_MOD_VERSION" != "$GO_VERSION" ]; then
  echo "Go version drift: server/go.mod declares $GO_MOD_VERSION, canonical pin is $GO_VERSION" >&2
  exit 1
fi
if [ "$DOCKER_DEFAULT" != "$GO_VERSION" ] || [ "$DOCKER_BASE" != '${GO_VERSION}' ]; then
  echo "Go version drift: server/Dockerfile does not consume the canonical $GO_VERSION pin" >&2
  exit 1
fi

for workflow in "$ROOT/.github/workflows/ci.yml" "$ROOT/.github/workflows/release.yml"; do
  if ! grep -Fq 'go-version-file: .go-version' "$workflow"; then
    echo "Go version drift: $workflow must use .go-version" >&2
    exit 1
  fi
  if grep -Eq '^[[:space:]]+go-version:' "$workflow"; then
    echo "Go version drift: $workflow contains a literal go-version override" >&2
    exit 1
  fi
done

echo "Go toolchain aligned at $GO_VERSION"
