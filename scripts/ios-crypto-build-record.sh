#!/bin/sh
# "Crypto Build Record" build phase of the iOS Runner target (D134).
#
# Copies the crypto build record that scripts/build-mobile-crypto.sh ios writes
# next to VeritraCrypto.xcframework into the app bundle, as
# veritra-crypto/build-info.txt, so the code signature seals it and
# scripts/check-release-evidence.py can check it in the signed .ipa.
#
# Every configuration except Debug and Profile (so Release, an unknown or an
# unset one) refuses to build unless the record exists and says, exactly once,
# source_tree_dirty=false. The check is check-release-evidence.py's own
# (--crypto-build-info), so it cannot drift from the signed-artifact gate.
# Debug and Profile copy the record when there is one and never refuse.
#
# Xcode sets CONFIGURATION, TARGET_BUILD_DIR and
# UNLOCALIZED_RESOURCES_FOLDER_PATH (Runner.app on iOS).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RECORD="$ROOT/mobile/ios/Frameworks/veritra-crypto-metadata/build-info.txt"

fail() {
  echo "error: $*" >&2
  exit 1
}

case "${CONFIGURATION:-}" in
  Debug | Profile) release=false ;;
  *) release=true ;;
esac

[ -n "${TARGET_BUILD_DIR:-}" ] || fail "TARGET_BUILD_DIR is not set; run this as an Xcode build phase"
[ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ] ||
  fail "UNLOCALIZED_RESOURCES_FOLDER_PATH is not set; run this as an Xcode build phase"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/veritra-crypto"
copy="$destination/build-info.txt"

# Never leave a record from an earlier build in the bundle.
rm -f "$copy"

if [ ! -f "$RECORD" ]; then
  if [ "$release" = true ]; then
    fail "Crypto build record not found: $RECORD. Run scripts/build-mobile-crypto.sh ios first."
  fi
  exit 0
fi

mkdir -p "$destination"
cp "$RECORD" "$copy"

if [ "$release" = true ]; then
  # Check the copy: those are the bytes the app ships.
  if ! command -v python3 >/dev/null 2>&1; then
    rm -f "$copy"
    fail "python3 is needed to check the crypto build record"
  fi
  if ! python3 "$ROOT/scripts/check-release-evidence.py" --crypto-build-info "$copy"; then
    rm -f "$copy"
    fail "Refusing to build ${CONFIGURATION:-an unnamed configuration}: the crypto library was not built from committed sources (need exactly one source_tree_dirty=false in $RECORD). Commit the changes and rebuild with scripts/build-mobile-crypto.sh ios."
  fi
fi
