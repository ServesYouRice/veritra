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
# asks the registry (docker buildx, network) whether the pinned digest is
# golang:$GO_VERSION's index or one of its platform images. Off by default, so
# local and offline runs make no network calls; any other value is an error.
case "${VERITRA_VERIFY_GO_IMAGE_DIGEST:-}" in
  ''|0) ;;
  1)
    if ! command -v docker >/dev/null 2>&1; then
      echo "Go image check: docker with buildx is required when VERITRA_VERIFY_GO_IMAGE_DIGEST=1" >&2
      exit 1
    fi
    # Captured first: sh has no pipefail, so a docker | python3 pipe would hide
    # a failed inspection.
    if ! GO_IMAGE_MANIFEST="$(docker buildx imagetools inspect "golang:$GO_VERSION" --format '{{json .Manifest}}')"; then
      echo "Go image check: cannot inspect golang:$GO_VERSION in the registry" >&2
      exit 1
    fi
    if ! printf '%s' "$GO_IMAGE_MANIFEST" | python3 -c '
import json
import re
import sys

pinned, tag = sys.argv[1], sys.argv[2]
digest = re.compile(r"sha256:[0-9a-f]{64}")
try:
    manifest = json.load(sys.stdin)
except ValueError:
    sys.exit(f"Go image check: unreadable manifest for {tag}")
if not isinstance(manifest, dict) or not digest.fullmatch(str(manifest.get("digest", ""))):
    sys.exit(f"Go image check: manifest for {tag} has no valid digest")
entries = manifest.get("manifests", [])
if not isinstance(entries, list):
    sys.exit(f"Go image check: malformed manifest list for {tag}")
index = manifest["digest"]
accepted = {index}
for entry in entries:
    if not isinstance(entry, dict) or not digest.fullmatch(str(entry.get("digest", ""))):
        sys.exit(f"Go image check: malformed manifest entry for {tag}")
    annotations = entry.get("annotations") or {}
    if isinstance(annotations, dict) and annotations.get("vnd.docker.reference.type") == "attestation-manifest":
        continue
    accepted.add(entry["digest"])
if pinned not in accepted:
    sys.exit(f"Go image drift: server/Dockerfile digest {pinned} is not {tag} (registry index {index})")
' "$DOCKER_DIGEST" "golang:$GO_VERSION"; then
      exit 1
    fi
    echo "Go image digest $DOCKER_DIGEST verified as golang:$GO_VERSION"
    ;;
  *)
    echo "VERITRA_VERIFY_GO_IMAGE_DIGEST must be 1 (verify), 0 or unset" >&2
    exit 1
    ;;
esac

echo "Go toolchain aligned at $GO_VERSION"
