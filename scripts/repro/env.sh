# Sourced by scripts/repro/build.sh. Pins everything that would make two builds
# of one commit differ: clock, locale, build paths, incremental state.
# Needs ROOT (the checkout being built) to be set by the caller.

fail() {
  echo "repro: $*" >&2
  exit 1
}

# One timestamp for the whole build: the commit's own time, never "now".
SOURCE_DATE_EPOCH=$(git -C "$ROOT" log -1 --format=%ct HEAD) ||
  fail "cannot read the commit time"
case $SOURCE_DATE_EPOCH in
  ''|*[!0-9]*) fail "malformed commit time: $SOURCE_DATE_EPOCH" ;;
esac
export SOURCE_DATE_EPOCH
export TZ=UTC LC_ALL=C LANG=C
export CARGO_INCREMENTAL=0

# Keep the checkout, cargo and rustc paths out of the binaries, so building in
# another directory gives the same bytes.
rust_sysroot=$(cd "$ROOT" && rustc --print sysroot) || fail "rustc not found"
RUSTFLAGS="--remap-path-prefix=$ROOT=/veritra --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-prefix=$rust_sysroot=/rustc"
if [ "$(uname -s)" = Linux ]; then RUSTFLAGS="$RUSTFLAGS -C link-arg=-Wl,--build-id=none"; fi
export RUSTFLAGS

# Toolchains the release is allowed to use. Edit these together with
# rust-toolchain.toml, pubspec.yaml and CI.
PIN_RUST=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$ROOT/rust-toolchain.toml")
PIN_FLUTTER=$(sed -n 's/^  flutter: *\(.*\)$/\1/p' "$ROOT/mobile/pubspec.yaml")
PIN_JAVA_MAJOR=17

check_rust() {
  got=$(cd "$ROOT" && rustc --version | cut -d' ' -f2)
  [ "$got" = "$PIN_RUST" ] || fail "rustc $got, pinned $PIN_RUST"
}

check_flutter() {
  got=$(flutter --version --machine 2>/dev/null | sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p')
  [ "$got" = "$PIN_FLUTTER" ] || fail "flutter ${got:-missing}, pinned $PIN_FLUTTER"
}

check_java() {
  got=$(java -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -n 1)
  [ "$got" = "$PIN_JAVA_MAJOR" ] || fail "JDK ${got:-missing}, pinned $PIN_JAVA_MAJOR"
}
