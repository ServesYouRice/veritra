#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
sh "$ROOT/scripts/check-go-toolchain.sh"
sh "$ROOT/scripts/check-rust-audit-expiry.sh"

# Positive approval evidence is the release gate. The legacy markers below are
# defense in depth only; a rename cannot satisfy the approval contract.
python3 "$ROOT/scripts/check-release-evidence.py" \
  --root "$ROOT" \
  --policy "${RELEASE_POLICY_FILE:-$ROOT/release/release-policy.json}" \
  --expected-commit "${RELEASE_COMMIT:-$(git rev-parse HEAD)}" \
  --preflight

if grep -q 'PM_CRYPTO_UNAVAILABLE' crypto/rust/src/lib.rs || \
   grep -q 'UnavailableCryptoService' mobile/lib/main.dart; then
  echo "release blocked: production MLS crypto is not wired" >&2
  exit 1
fi

if [ -n "${RELEASE_EVIDENCE_FILE:-}" ] || [ -f "$ROOT/dist/release-evidence.json" ]; then
  python3 "$ROOT/scripts/check-release-evidence.py" \
    --root "$ROOT" \
    --policy "${RELEASE_POLICY_FILE:-$ROOT/release/release-policy.json}" \
    --evidence "${RELEASE_EVIDENCE_FILE:-$ROOT/dist/release-evidence.json}" \
    --expected-commit "${RELEASE_COMMIT:-$(git rev-parse HEAD)}"
fi

echo "release readiness gates passed"
