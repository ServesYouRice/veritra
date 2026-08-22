#!/bin/sh
set -eu

if grep -q 'PM_CRYPTO_UNAVAILABLE' crypto/rust/src/lib.rs || \
   grep -q 'UnavailableCryptoService' mobile/lib/main.dart; then
  echo "release blocked: production MLS crypto is not wired" >&2
  exit 1
fi

echo "release readiness gates passed"
