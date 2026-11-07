#!/bin/bash
# Installs what .claude/hooks/check.sh needs, so every Claude web session can
# run the full checks. Runs only in Claude web (cloud) sessions.
set -euo pipefail
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}"

# REPO-SPECIFIC: install dependencies and start services the checks need.
# Veritra needs no database (SQLite only). The checks need: the pinned Go
# (auto-downloaded through proxy.golang.org from server/go.mod), the pinned Rust
# (rust-toolchain.toml), cargo-audit, Flutter 3.44.0 and the Linux desktop
# build packages.

FLUTTER_VERSION=3.44.0
CARGO_AUDIT_VERSION=$(sh scripts/check-rust-audit-expiry.sh --print-cargo-audit-version)
FLUTTER_HOME=/opt/flutter-$FLUTTER_VERSION

# Linux desktop build dependencies (same list as the desktop-linux build;
# GStreamer is for the voice-note player).
pkgs="clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev liblzma-dev libnotify-dev libayatana-appindicator3-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev xz-utils unzip"
missing=""
for p in $pkgs; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing="$missing $p"
done
if [ -n "$missing" ]; then
  # Private TMPDIR and lock wait: other processes may run apt at the same time.
  apt_tmp=$(mktemp -d /var/tmp/apt-veritra.XXXXXX)
  apt_get() { TMPDIR="$apt_tmp" DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 "$@"; }
  apt_get update -qq
  for attempt in 1 2 3; do
    apt_get install -y -qq $missing >/dev/null && break
    [ "$attempt" = 3 ] && exit 1
    sleep 5
  done
  rm -rf "$apt_tmp"
fi

# Flutter SDK, pinned to the version the builds use.
if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  tmp=$(mktemp -d)
  curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    | tar -xJ -C "$tmp"
  rm -rf "$FLUTTER_HOME"
  mv "$tmp/flutter" "$FLUTTER_HOME"
  rm -rf "$tmp"
fi
git config --global --add safe.directory "$FLUTTER_HOME" 2>/dev/null || true
export PATH="$FLUTTER_HOME/bin:$HOME/.cargo/bin:$PATH"
flutter config --no-analytics >/dev/null 2>&1 || true
dart --disable-analytics >/dev/null 2>&1 || true
flutter precache --linux --no-android --no-ios >/dev/null

# Go toolchain and modules (go.mod pins the version; GOTOOLCHAIN=auto fetches it).
(cd server && go mod download)

# Rust toolchain (rust-toolchain.toml) and crates.
(cd crypto/rust && cargo fetch --locked >/dev/null)
if [ "$(cargo audit --version 2>/dev/null | awk '{print $2}')" != "$CARGO_AUDIT_VERSION" ]; then
  cargo install cargo-audit --version "$CARGO_AUDIT_VERSION" --locked
fi

# Dart packages. A resolution failure is a code problem, not a setup problem:
# report it and let check.sh fail on it.
(cd mobile && flutter pub get --enforce-lockfile >/dev/null) ||
  echo "session-start: flutter pub get failed in mobile/; check.sh will fail until it is fixed" >&2

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$FLUTTER_HOME/bin:\$HOME/.cargo/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
