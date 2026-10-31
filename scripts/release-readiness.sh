#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
sh "$ROOT/scripts/check-go-toolchain.sh"
sh "$ROOT/scripts/check-rust-audit-expiry.sh"

# Approvals cannot be committed in the candidate itself (a file cannot name
# the SHA of its own commit). They are read from a later commit on the
# protected default branch: release.yml resolves it once and passes it in.
# Only when RELEASE_APPROVALS_COMMIT is unset does it default to the fetched
# origin/main (for local runs). Set but empty, or with no origin/main, the
# checker gets an empty value and fails closed.
APPROVALS_COMMIT=${RELEASE_APPROVALS_COMMIT-$(git rev-parse --verify --quiet 'refs/remotes/origin/main^{commit}' || true)}

# Positive approval evidence is the release gate. The legacy markers below are
# defense in depth only; a rename cannot satisfy the approval contract.
python3 "$ROOT/scripts/check-release-evidence.py" \
  --root "$ROOT" \
  --policy "${RELEASE_POLICY_FILE:-$ROOT/release/release-policy.json}" \
  --expected-commit "${RELEASE_COMMIT:-$(git rev-parse HEAD)}" \
  --approvals-commit "$APPROVALS_COMMIT" \
  --preflight

sh "$ROOT/scripts/check-demo-boundary.sh"

if grep -q 'PM_CRYPTO_UNAVAILABLE' crypto/rust/src/lib.rs || \
   grep -q 'UnavailableCryptoService' mobile/lib/main.dart; then
  echo "release blocked: production MLS crypto is not wired" >&2
  exit 1
fi

# The full evidence check runs when RELEASE_EVIDENCE_FILE names the evidence
# (release.yml's final gate) or a local dist/release-evidence.json exists.
# Without either, only the preflight above ran (release.yml's first call,
# before anything is built), and the last line says so. Set but empty is a
# misconfigured final gate, so it fails instead of falling back.
if [ -n "${RELEASE_EVIDENCE_FILE+set}" ] && [ -z "$RELEASE_EVIDENCE_FILE" ]; then
  echo "release blocked: RELEASE_EVIDENCE_FILE is set but empty" >&2
  exit 1
fi
EVIDENCE_FILE=${RELEASE_EVIDENCE_FILE:-}
if [ -z "$EVIDENCE_FILE" ] && [ -f "$ROOT/dist/release-evidence.json" ]; then
  EVIDENCE_FILE=$ROOT/dist/release-evidence.json
fi
if [ -z "$EVIDENCE_FILE" ]; then
  echo "release readiness preflight gates passed; release evidence was not checked (RELEASE_EVIDENCE_FILE is unset and there is no dist/release-evidence.json)"
  exit 0
fi

python3 "$ROOT/scripts/check-release-evidence.py" \
  --root "$ROOT" \
  --policy "${RELEASE_POLICY_FILE:-$ROOT/release/release-policy.json}" \
  --evidence "$EVIDENCE_FILE" \
  --expected-commit "${RELEASE_COMMIT:-$(git rev-parse HEAD)}" \
  --approvals-commit "$APPROVALS_COMMIT"

echo "release readiness gates passed, including the release evidence in $EVIDENCE_FILE"
