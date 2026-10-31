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
DOCKER_DIGEST="$(sed -n 's/^FROM .*golang:\${GO_VERSION}@\(sha256:[0-9a-f]*\) AS build$/\1/p' "$ROOT/server/Dockerfile" | head -n 1)"

if [ "$GO_MOD_VERSION" != "$GO_VERSION" ]; then
  echo "Go version drift: server/go.mod declares $GO_MOD_VERSION, canonical pin is $GO_VERSION" >&2
  exit 1
fi
if [ "$DOCKER_DEFAULT" != "$GO_VERSION" ] || [ "$DOCKER_BASE" != '${GO_VERSION}' ]; then
  echo "Go version drift: server/Dockerfile does not consume the canonical $GO_VERSION pin" >&2
  exit 1
fi
if ! printf '%s\n' "$DOCKER_DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
  echo "Go image drift: server/Dockerfile must use an immutable sha256 digest" >&2
  exit 1
fi

for wrapper in \
  "$ROOT/scripts/test.sh" \
  "$ROOT/scripts/test.ps1" \
  "$ROOT/scripts/lint.sh" \
  "$ROOT/scripts/lint.ps1" \
  "$ROOT/scripts/dev.sh" \
  "$ROOT/scripts/dev.ps1"; do
  WRAPPER_DIGESTS="$(sed -n 's/.*golang:[^@]*@\(sha256:[0-9a-f]*\).*/\1/p' "$wrapper" | sort -u)"
  if [ "$WRAPPER_DIGESTS" != "$DOCKER_DIGEST" ]; then
    echo "Go image drift: $wrapper must use Dockerfile digest $DOCKER_DIGEST" >&2
    exit 1
  fi
done

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

# Docker ignores the tag when a digest is given, so a digest left behind by a
# version bump keeps building with the old Go. VERITRA_VERIFY_GO_IMAGE_DIGEST=1
# asks the registry (docker buildx, network) for the image config behind the
# pinned digest itself and requires every platform image's Env to carry
# GOLANG_VERSION=$GO_VERSION. It does not compare the pin with what the tag
# points to today: Docker rebuilds official tags in place, so a correct pin
# stops being the tag's current index after each upstream rebuild. Off by
# default, so local and offline runs make no network calls; any other value is
# an error. Anonymous Docker Hub pulls are rate limited, which can fail it.
case "${VERITRA_VERIFY_GO_IMAGE_DIGEST:-}" in
  ''|0) ;;
  1)
    if ! command -v docker >/dev/null 2>&1; then
      echo "Go image check: docker with buildx is required when VERITRA_VERIFY_GO_IMAGE_DIGEST=1" >&2
      exit 1
    fi
    # Captured first: sh has no pipefail, so a docker | python3 pipe would hide
    # a failed inspection.
    if ! GO_IMAGE_CONFIG="$(docker buildx imagetools inspect "golang@$DOCKER_DIGEST" --format '{{json .Image}}')"; then
      echo "Go image check: cannot inspect golang@$DOCKER_DIGEST in the registry" >&2
      exit 1
    fi
    if ! printf '%s' "$GO_IMAGE_CONFIG" | python3 -c '
import json
import sys

pinned, version = sys.argv[1], sys.argv[2]
ref = f"golang@{pinned}"
want = f"GOLANG_VERSION={version}"
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(f"Go image check: unreadable image config for {ref}")
if not isinstance(data, dict) or not data:
    sys.exit(f"Go image check: no image config for {ref}")
# `{{json .Image}}` prints one image config for a single-platform manifest
# and a map of platform (e.g. linux/amd64) to image config for an index.
if {"config", "rootfs", "architecture", "os"} & data.keys():
    images = {"image": data}
else:
    images = data
checked = 0
for name, image in images.items():
    if name == "unknown/unknown":
        continue  # attestation manifests, not runnable images
    config = image.get("config") if isinstance(image, dict) else None
    env = config.get("Env") if isinstance(config, dict) else None
    if not isinstance(env, list):
        sys.exit(f"Go image check: {ref} {name} has no Env")
    found = [item for item in env if isinstance(item, str) and item.startswith("GOLANG_VERSION=")]
    if found != [want]:
        have = ", ".join(found) if found else "no GOLANG_VERSION"
        sys.exit(f"Go image drift: server/Dockerfile digest {pinned} ({name}) has {have}, want {want}")
    checked += 1
if not checked:
    sys.exit(f"Go image check: no image config for {ref}")
' "$DOCKER_DIGEST" "$GO_VERSION"; then
      exit 1
    fi
    echo "Go image digest $DOCKER_DIGEST verified as Go $GO_VERSION"
    ;;
  *)
    echo "VERITRA_VERIFY_GO_IMAGE_DIGEST must be 1 (verify), 0 or unset" >&2
    exit 1
    ;;
esac

echo "Go toolchain aligned at $GO_VERSION"
