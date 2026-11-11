#!/usr/bin/env bash
# Rebuilds a released Veritra server image from its tag and compares it with
# the published one (L2-4). Local only; needs bash, git and docker with buildx.
#
#   scripts/verify-server-build.sh <tag> [--image REPO] [--platforms LIST]
#
# For each platform (default linux/amd64,linux/arm64) it builds the Dockerfile
# `build` stage from `git archive <tag>` with the pinned Go image, VERSION from
# `git describe` and COMMIT from the tag, then compares the SHA-256 of the
# server binary with the one inside REPO:<tag>. It does not compare the
# multi-arch index digest: the provenance and SBOM attestations hold per-run
# data, so that digest differs on every build.
#
# Prints "binary matches release <tag>" or "binary does NOT match" per
# platform, and exits 1 on any mismatch. A match shows the published image
# holds the code in this tag; it does not show what an operator runs.
set -euo pipefail

IMAGE="${VERITRA_IMAGE_REPO:-ghcr.io/servesyourice/veritra}"
PLATFORMS="linux/amd64,linux/arm64"
TAG=""

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }
fail() { echo "verify-server-build: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="${2:?--image needs a value}"; shift 2 ;;
    --platforms) PLATFORMS="${2:?--platforms needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    *) [ -z "$TAG" ] || fail "one tag only"; TAG="$1"; shift ;;
  esac
done
[ -n "$TAG" ] || { usage >&2; exit 2; }

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
command -v git >/dev/null 2>&1 || fail "git is not installed"
command -v docker >/dev/null 2>&1 || fail "docker is not installed"
COMMIT="$(git -C "$ROOT" rev-parse --verify "refs/tags/$TAG^{commit}" 2>/dev/null)" ||
  fail "no tag $TAG in this repository (fetch tags first)"
VERSION="$(git -C "$ROOT" describe --tags --always "$COMMIT")"
GO_VERSION="$(git -C "$ROOT" show "$COMMIT:.go-version" | tr -d '[:space:]')"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/veritra-server-verify.XXXXXX")"
CID=""
trap 'if [ -n "$CID" ]; then docker rm -f "$CID" >/dev/null 2>&1 || true; fi; rm -rf "$WORK"' EXIT

git -C "$ROOT" archive --format=tar "$COMMIT" > "$WORK/src.tar"
sha() { sha256sum "$1" | cut -d' ' -f1; }

status=0
IFS=',' read -r -a LIST <<< "$PLATFORMS"
for platform in "${LIST[@]}"; do
  out="$WORK/${platform//\//_}"
  mkdir -p "$out"
  docker buildx build --platform "$platform" --target build \
    --build-arg "GO_VERSION=$GO_VERSION" --build-arg "VERSION=$VERSION" \
    --build-arg "COMMIT=$COMMIT" \
    --output "type=local,dest=$out/built" -f server/Dockerfile - < "$WORK/src.tar" 2>&1 ||
    fail "build for $platform failed"
  # The Dockerfile build context is the repo root; the tar carries it.
  docker pull --platform "$platform" "$IMAGE:$TAG" >/dev/null || fail "cannot pull $IMAGE:$TAG for $platform"
  CID="$(docker create --platform "$platform" "$IMAGE:$TAG")"
  docker cp "$CID:/usr/local/bin/messenger-server" "$out/released" >/dev/null
  docker rm -f "$CID" >/dev/null; CID=""
  built="$(sha "$out/built/out/messenger-server")"
  released="$(sha "$out/released")"
  if [ "$built" = "$released" ]; then
    echo "$platform: binary matches release $TAG ($built)"
  else
    echo "$platform: binary does NOT match release $TAG (built $built, released $released)"
    status=1
  fi
done
exit "$status"
