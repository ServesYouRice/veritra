#!/bin/bash
# Runs every check for this repo. On success it records the exact code that
# passed, which unlocks `git push` and pull requests (see require-checks.sh).
# Shared template from ServesYouRice/handbook (templates/claude-cloud).
# Only the run_checks function is repo-specific.
set -uo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

run_checks() {
  # REPO-SPECIFIC: every check from scripts/ and the CI definition that can run
  # in a Linux container. Left out, because they cannot run here:
  # - iOS simulator and macOS demo builds (need macOS and Xcode).
  # - Windows demo build and scripts/test-demo-e2e.ps1 (need Windows).
  # - compose-smoke (docker compose build/up; no Docker daemon in the container).
  # - Android crypto libraries and APK builds (need the Android SDK and NDK from
  #   dl.google.com, which this environment's network does not allow).
  export PATH="/opt/flutter-3.44.0/bin:$HOME/.cargo/bin:$PATH"
  # Chained with && because errexit does not apply inside `if ! run_checks`.
  sh scripts/test.sh &&
    sh scripts/lint.sh &&
    # Race tests, coverage floors, dependency policy, licenses, Rust audit,
    # release-policy fixtures and live API contracts.
    sh scripts/verify.sh &&
    sh scripts/test-demo-e2e.sh &&
    (cd mobile && sh ../scripts/check-dart-licenses.sh) &&
    # govulncheck reads the Go vulnerability database from its storage
    # bucket; vuln.go.dev itself is not reachable from this container.
    # `go run pkg@version` ignores go.mod, so pin the toolchain explicitly.
    (cd server && GOTOOLCHAIN="go$(tr -d '[:space:]' < ../.go-version)" \
      go run golang.org/x/vuln/cmd/govulncheck@v1.1.4 \
      -db https://storage.googleapis.com/go-vulndb ./...) &&
    sh scripts/check-rust-audit-expiry.sh --self-test &&
    # Linux desktop demo build (desktop-linux job).
    sh scripts/build-desktop-crypto.sh linux &&
    (cd mobile && flutter build linux --release -t lib/main_demo.dart --dart-define=VERITRA_DEMO=true) &&
    test -s mobile/build/linux/x64/release/bundle/lib/libprivate_messenger_crypto.so
}

# Hash of the working tree as it would be committed (tracked + new, not ignored).
tree_now() {
  local idx; idx=$(mktemp)
  cp "$(git rev-parse --git-dir)/index" "$idx" 2>/dev/null || rm -f "$idx"
  GIT_INDEX_FILE="$idx" git add -A >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git write-tree
  rm -f "$idx"
}

before=$(tree_now)
if ! run_checks; then
  echo "CHECKS FAILED" >&2
  exit 1
fi
after=$(tree_now)
if [ "$before" != "$after" ]; then
  echo "Checks passed but changed files (formatter or generated output)." >&2
  echo "Review the changes and run this script again." >&2
  exit 1
fi
echo "$after" > "$(git rev-parse --git-dir)/claude-checks-passed"
echo "ALL CHECKS PASSED (recorded for tree $after)"
