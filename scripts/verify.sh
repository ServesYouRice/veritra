#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SUMMARY="${VERIFY_SUMMARY_FILE:-$ROOT/dist/verify-summary.json}"
mkdir -p "$(dirname -- "$SUMMARY")"
# A summary from an earlier run must not outlive this one: if this run is
# killed or stops early, no summary (and so no stale "pass") is left.
rm -f "$SUMMARY"
SUMMARY_TMP="$SUMMARY.tmp.$$"
trap 'rm -f "$SUMMARY_TMP"' EXIT

# What was verified: the commit, and whether the tree had local changes.
commit_json=null
dirty_json=null
if head=$(git -C "$ROOT" rev-parse --verify --quiet HEAD 2>/dev/null) && [ -n "$head" ]; then
  commit_json="\"$head\""
  if changes=$(git -C "$ROOT" status --porcelain 2>/dev/null); then
    if [ -n "$changes" ]; then dirty_json=true; else dirty_json=false; fi
  fi
fi

# Writes the summary in one step: $1 is its status-specific JSON members.
write_summary() {
  printf '{"schema_version":1,%s,"commit":%s,"dirty":%s,"generated_at":"%s"}\n' \
    "$1" "$commit_json" "$dirty_json" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SUMMARY_TMP"
  mv -f "$SUMMARY_TMP" "$SUMMARY"
}

missing=""
for command in go cargo cargo-audit flutter dart; do
  if ! command -v "$command" >/dev/null 2>&1; then
    missing="$missing $command"
  fi
done
if [ -n "$missing" ]; then
  names=""
  for command in $missing; do
    if [ -n "$names" ]; then names="$names,"; fi
    names="$names\"$command\""
  done
  write_summary "\"status\":\"blocked\",\"missing\":[$names]"
  echo "full verification blocked; missing required tools:$missing" >&2
  exit 2
fi

status="pass"
steps=""
run_step() {
  name="$1"
  shift
  if "$@"; then
    result="pass"
  else
    result="fail"
    status="fail"
  fi
  if [ -n "$steps" ]; then steps="$steps,"; fi
  steps="$steps{\"name\":\"$name\",\"result\":\"$result\"}"
}

run_step go-race sh -c "cd '$ROOT/server' && go test -race -coverprofile=coverage.out ./..."
# gofmt's own exit status counts: a parse error prints nothing on stdout.
run_step go-lint sh -c "cd '$ROOT/server' && unformatted=\$(gofmt -l .) && test -z \"\$unformatted\" && go vet ./..."
run_step rust-release sh -c "cd '$ROOT/crypto/rust' && cargo test --release --locked && cargo fmt --check && cargo clippy --all-targets -- -D warnings"
run_step dart-coverage sh -c "cd '$ROOT/mobile' && flutter test --coverage && flutter analyze && dart format --set-exit-if-changed ."
run_step coverage-floor sh -c "python3 '$ROOT/scripts/check-coverage.py' \
  --go-profile '$ROOT/server/coverage.out' --go-floor 50.0 \
  --go-required-source internal/push/native.go \
  --go-required-source internal/cryptoapi/cryptoapi.go \
  --flutter-lcov '$ROOT/mobile/coverage/lcov.info' --flutter-floor 43.0 \
  --flutter-required-source lib/core/app_state.dart \
  --flutter-required-source lib/storage/local_store.dart \
  --flutter-required-source lib/push/push_service.dart \
  --flutter-required-source lib/crypto/attachment_crypto.dart \
  --flutter-required-source lib/calls/call_service.dart"
run_step mobile-dependencies sh "$ROOT/scripts/check-mobile-dependencies.sh"
run_step licenses sh "$ROOT/scripts/license-check.sh"
run_step rust-audit sh "$ROOT/scripts/audit-rust.sh"
run_step release-policy-fixtures sh -c "python3 '$ROOT/scripts/check-release-evidence_test.py' && python3 '$ROOT/scripts/check-dart-retractions_test.py' && python3 '$ROOT/scripts/check-ci-evidence_test.py' && python3 '$ROOT/scripts/write-release-evidence_test.py' && python3 '$ROOT/scripts/check-coverage_test.py'"
run_step api-contracts sh "$ROOT/scripts/test-api-contracts.sh"

write_summary "\"status\":\"$status\",\"steps\":[$steps]"
if [ "$status" != pass ]; then
  exit 1
fi
echo "full verification passed; evidence: $SUMMARY"
