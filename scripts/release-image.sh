#!/usr/bin/env bash
# Local release command for the Veritra server image (no hosted CI).
#
#   scripts/release-image.sh [--image REPO] [--infra-dir DIR] [--no-push] [--skip-smoke]
#
# 1. Refuses a dirty tree and any commit not on freshly fetched origin/main.
# 2. Runs the server checks and dependency scans: gofmt, go vet, go test,
#    govulncheck and cargo audit (scripts/audit-rust.sh).
# 3. Builds the image from `git archive` of the checked commit (only committed
#    files, no local .env, keys or data), tagged with it; stops if HEAD moved.
# 4. Scans the image with Trivy (vulnerabilities and secrets); a HIGH or
#    CRITICAL finding stops the release.
# 5. Runs scripts/smoke-deploy.sh on that exact image (hardened Compose
#    stack: setup, uploads, backup, restore, push, TURN, log privacy).
#    --skip-smoke skips it; say so in the release record.
# 6. Pushes to the registry, verifies and prints the digest.
# 7. With --infra-dir, writes the digest into DIR/kustomization.yaml (the
#    `digest:` line under the image's `name:`) and commits that file in the
#    infra repository. Push that repository yourself; Flux applies it.
#
# Registry login is yours to do beforehand (`docker login ghcr.io` with a
# token that can write packages); this script never reads credentials.
# Needs bash, git, go, cargo with the pinned cargo-audit, docker with buildx,
# and trivy. On Windows run it from WSL (or Git Bash with Docker Desktop).
# This is not the mobile release gate (scripts/release-readiness.sh).
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE="${VERITRA_IMAGE_REPO:-ghcr.io/servesyourice/veritra}"
INFRA_DIR=""
PUSH=1
SMOKE=1
GOVULNCHECK="golang.org/x/vuln/cmd/govulncheck@v1.1.4"

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="${2:?--image needs a value}"; shift 2 ;;
    --infra-dir) INFRA_DIR="${2:?--infra-dir needs a value}"; shift 2 ;;
    --no-push) PUSH=0; shift ;;
    --skip-smoke) SMOKE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() { echo "release-image: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

case "${IMAGE##*/}" in
  *:*|*@*) fail "--image takes a repository without tag or digest: $IMAGE" ;;
esac
if [ -n "$INFRA_DIR" ] && [ "$PUSH" -eq 0 ]; then
  fail "--infra-dir needs a pushed digest; drop --no-push"
fi
command -v git >/dev/null 2>&1 || fail "git is not installed"
# History must read as committed: a replace ref or a grafts file (in .git or
# from GIT_GRAFT_FILE) could make an unpublished commit look like part of the
# default branch, or change what git archive packages. Same guard as
# scripts/check-release-evidence.py; the graft path cannot exist.
export GIT_NO_REPLACE_OBJECTS=1
export GIT_GRAFT_FILE=/dev/null/grafts
cd "$ROOT"
TREE_STATUS="$(git status --porcelain --untracked-files=normal)" || fail "cannot read the working tree status"
if [ -n "$TREE_STATUS" ]; then
  fail "the working tree is dirty; commit or remove changes first"
fi
for tool in go docker; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed"
done
command -v trivy >/dev/null 2>&1 || fail "trivy is not installed (https://trivy.dev); the image scan is required"
# Later steps use $COMMIT; HEAD is read again only to check it has not moved.
COMMIT="$(git rev-parse --verify 'HEAD^{commit}')"
TAG="$(git rev-parse --short=12 "$COMMIT")"
VERSION="$(git describe --tags --always "$COMMIT")"
GO_VERSION="$(tr -d '[:space:]' < .go-version)"

# Only reviewed, published commits are released: $COMMIT must be on the
# protected default branch as origin serves it now (the anchor
# scripts/release-readiness.sh uses for mobile approvals). A failed fetch stops
# the release rather than trusting a stale origin/main.
DEFAULT_BRANCH=main
step "published commit"
git fetch --no-tags --quiet origin "+refs/heads/$DEFAULT_BRANCH:refs/remotes/origin/$DEFAULT_BRANCH" ||
  fail "cannot fetch $DEFAULT_BRANCH from origin; the release commit must be checked against it"
git merge-base --is-ancestor "$COMMIT" "refs/remotes/origin/$DEFAULT_BRANCH" ||
  fail "commit $COMMIT is not on origin/$DEFAULT_BRANCH; push it through review first"

if [ -n "$INFRA_DIR" ]; then
  KUSTOMIZATION="$INFRA_DIR/kustomization.yaml"
  [ -f "$KUSTOMIZATION" ] || fail "$KUSTOMIZATION not found"
  git -C "$INFRA_DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "$INFRA_DIR is not in a git repository"
  if [ -n "$(git -C "$INFRA_DIR" status --porcelain -- kustomization.yaml)" ]; then
    fail "$KUSTOMIZATION has uncommitted changes"
  fi
  grep -q "name: $IMAGE\$" "$KUSTOMIZATION" || fail "$KUSTOMIZATION has no images entry named $IMAGE"
fi

step "checks"
# The release builds FROM golang@digest, so confirm with the registry that the
# pinned digest really is golang:$GO_VERSION (needs docker buildx and network).
VERITRA_VERIFY_GO_IMAGE_DIGEST=1 sh scripts/check-go-toolchain.sh
(
  cd server
  unformatted="$(gofmt -l .)"
  [ -z "$unformatted" ] || { echo "gofmt needed:"; echo "$unformatted"; exit 1; }
  go vet ./...
  go test ./...
)

step "dependency scans"
(cd server && go run "$GOVULNCHECK" ./...)
sh scripts/audit-rust.sh

step "build $IMAGE:$TAG"
# The checks ran on the working tree, so it must still be exactly $COMMIT.
HEAD_NOW="$(git rev-parse --verify 'HEAD^{commit}')" || fail "cannot read HEAD after the checks"
[ "$HEAD_NOW" = "$COMMIT" ] || fail "HEAD moved during the checks ($COMMIT -> $HEAD_NOW); start the release again"
TREE_STATUS="$(git status --porcelain --untracked-files=normal)" || fail "cannot read the working tree status"
[ -z "$TREE_STATUS" ] || fail "the working tree changed during the checks; start the release again"
git archive --format=tar "$COMMIT" | docker build \
  --platform linux/amd64 \
  -f server/Dockerfile \
  --build-arg "GO_VERSION=$GO_VERSION" \
  --build-arg "VERSION=$VERSION" \
  --build-arg "COMMIT=$COMMIT" \
  --label "org.opencontainers.image.source=https://github.com/ServesYouRice/veritra" \
  --label "org.opencontainers.image.version=$VERSION" \
  --label "org.opencontainers.image.licenses=AGPL-3.0-or-later" \
  -t "$IMAGE:$TAG" \
  -

step "image scan (trivy)"
trivy image --image-src docker --scanners vuln,secret --severity HIGH,CRITICAL \
  --exit-code 1 --no-progress "$IMAGE:$TAG"

if [ "$SMOKE" -eq 1 ]; then
  step "hardened deployment smoke"
  scripts/smoke-deploy.sh --image "$IMAGE:$TAG"
else
  echo "warning: --skip-smoke: this image was not smoke-tested" >&2
fi

if [ "$PUSH" -eq 0 ]; then
  step "done (not pushed)"
  echo "local image: $IMAGE:$TAG"
  exit 0
fi

step "push"
docker push "$IMAGE:$TAG"
DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE:$TAG" \
  | sed -n "s#^$IMAGE@\(sha256:[0-9a-f]\{64\}\)\$#\1#p" | head -n 1)"
[ -n "$DIGEST" ] || fail "could not read the pushed digest for $IMAGE:$TAG"
docker buildx imagetools inspect "$IMAGE@$DIGEST" >/dev/null || fail "registry does not serve $IMAGE@$DIGEST"

step "released"
echo "commit: $COMMIT"
echo "image:  $IMAGE@$DIGEST"

if [ -n "$INFRA_DIR" ]; then
  step "infra: $KUSTOMIZATION"
  tmp="$(mktemp "$INFRA_DIR/.kustomization.XXXXXX")"
  # Replace the digest of the images entry whose name is exactly $IMAGE.
  awk -v name="$IMAGE" -v digest="$DIGEST" '
    ($1 == "-" && $2 == "name:" && $3 == name) || ($1 == "name:" && $2 == name) { want = 1; print; next }
    want && $1 == "digest:" { sub(/sha256:[0-9a-f]+/, digest); done = 1; want = 0 }
    want && $1 == "-" { want = 0 }
    { print }
    END { if (!done) exit 3 }
  ' "$KUSTOMIZATION" > "$tmp" || { rm -f "$tmp"; fail "no digest line under $IMAGE in $KUSTOMIZATION"; }
  cat "$tmp" > "$KUSTOMIZATION"
  rm -f "$tmp"
  git -C "$INFRA_DIR" add -- kustomization.yaml
  git -C "$INFRA_DIR" commit -m "veritra: deploy $TAG" -m "Image $IMAGE@$DIGEST from commit $COMMIT." -- kustomization.yaml
  echo "committed in $(git -C "$INFRA_DIR" rev-parse --show-toplevel); push it to deploy."
fi
