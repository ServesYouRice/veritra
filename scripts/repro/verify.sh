#!/bin/sh
# Builds one target twice and compares the file digests.
#
#   scripts/repro/verify.sh crypto-linux|linux|android|macos [REPORT.md]
#
# Each build starts from a fresh, clean copy of HEAD in its own directory (two
# different paths), so uncommitted files and build paths cannot leak in. Exit 0
# only when every file is byte-identical. Commit before running.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TARGET=${1:-}
REPORT=${2:-}
[ -n "$TARGET" ] || { echo "usage: $0 crypto-linux|linux|android|macos [REPORT.md]" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/veritra-repro.XXXXXX")
trap 'git -C "$ROOT" worktree remove --force "$WORK/a/src" 2>/dev/null || true
      git -C "$ROOT" worktree remove --force "$WORK/b/src" 2>/dev/null || true
      git -C "$ROOT" worktree prune; rm -rf "$WORK"' EXIT

for run in a b; do
  mkdir -p "$WORK/$run"
  # Different directory names on purpose: a path baked into a binary shows up.
  git -C "$ROOT" worktree add --detach -q "$WORK/$run/src" HEAD
  sh "$WORK/$run/src/scripts/repro/build.sh" "$TARGET" "$WORK/$run/out" > "$WORK/$run/log.txt" 2>&1 ||
    { cat "$WORK/$run/log.txt" >&2; echo "build $run failed" >&2; exit 1; }
done

status=identical
cmp -s "$WORK/a/out/SHA256SUMS" "$WORK/b/out/SHA256SUMS" || status=DIFFERENT
files=$(wc -l < "$WORK/a/out/SHA256SUMS")
{
  echo "target: $TARGET"
  echo "commit: $(git -C "$ROOT" rev-parse HEAD)"
  echo "result: $status ($files files)"
  echo
  echo "build A  (checkout at $WORK/a/src)"
  echo '```'; cat "$WORK/a/out/SHA256SUMS"; echo '```'
  if [ "$status" != identical ]; then
    echo "differences (A vs B):"; echo '```'
    diff "$WORK/a/out/SHA256SUMS" "$WORK/b/out/SHA256SUMS" || true; echo '```'
  fi
} > "${REPORT:-$WORK/report.md}"
[ -z "$REPORT" ] && cat "$WORK/report.md"
[ "$status" = identical ]
