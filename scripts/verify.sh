#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SUMMARY="${VERIFY_SUMMARY_FILE:-$ROOT/dist/verify-summary.json}"
mkdir -p "$(dirname -- "$SUMMARY")"

missing=""
for command in go cargo cargo-audit flutter dart; do
  if ! command -v "$command" >/dev/null 2>&1; then
    missing="$missing $command"
  fi
done
if [ -n "$missing" ]; then
  printf '{"schema_version":1,"status":"blocked","missing":[' > "$SUMMARY"
  first=1
  for command in $missing; do
    [ "$first" -eq 1 ] || printf ',' >> "$SUMMARY"
    printf '"%s"' "$command" >> "$SUMMARY"
    first=0
  done
  printf ']}\n' >> "$SUMMARY"
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
run_step go-lint sh -c "cd '$ROOT/server' && test -z \"\$(gofmt -l .)\" && go vet ./..."
run_step rust-release sh -c "cd '$ROOT/crypto/rust' && cargo test --release --locked && cargo fmt --check && cargo clippy --all-targets -- -D warnings"
run_step dart-coverage sh -c "cd '$ROOT/mobile' && flutter test --coverage && flutter analyze && dart format --set-exit-if-changed ."
# Floors stay at 0.0 until the QA10 advisor checkpoint sets values from
# testing/evidence/coverage-baseline.md; the gate still fails on missing or
# malformed coverage data.
run_step coverage-floor sh -c "python3 '$ROOT/scripts/check-coverage.py' --go-profile '$ROOT/server/coverage.out' --go-floor 0.0 --flutter-lcov '$ROOT/mobile/coverage/lcov.info' --flutter-floor 0.0"
run_step mobile-dependencies sh "$ROOT/scripts/check-mobile-dependencies.sh"
run_step licenses sh "$ROOT/scripts/license-check.sh"
run_step rust-audit sh "$ROOT/scripts/audit-rust.sh"
run_step release-policy-fixtures sh -c "python3 '$ROOT/scripts/check-release-evidence_test.py' && python3 '$ROOT/scripts/check-dart-retractions_test.py' && python3 '$ROOT/scripts/check-ci-evidence_test.py' && python3 '$ROOT/scripts/write-release-evidence_test.py' && python3 '$ROOT/scripts/check-coverage_test.py'"
run_step api-contracts sh "$ROOT/scripts/test-api-contracts.sh"

printf '{"schema_version":1,"status":"%s","steps":[%s]}\n' "$status" "$steps" > "$SUMMARY"
if [ "$status" != pass ]; then
  exit 1
fi
echo "full verification passed; evidence: $SUMMARY"
