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
# The Linux plugins and runner are C/C++ (CMake): same idea for them.
if [ "$(uname -s)" = Linux ]; then
  export CFLAGS="-ffile-prefix-map=$ROOT=/veritra"
  export CXXFLAGS="-ffile-prefix-map=$ROOT=/veritra"
  export LDFLAGS="-Wl,--build-id=none"
fi

# Toolchains the release is allowed to use. Edit these together with
# rust-toolchain.toml, pubspec.yaml and CI.
PIN_RUST=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$ROOT/rust-toolchain.toml")
PIN_FLUTTER=$(sed -n 's/^  flutter: *\(.*\)$/\1/p' "$ROOT/mobile/pubspec.yaml")
PIN_JAVA_MAJOR=17
# flutter.ndkVersion of Flutter 3.44.0 (FlutterExtension.kt). The Rust library
# and Gradle must use this one NDK; the Rust script otherwise takes the newest
# installed.
PIN_NDK=28.2.13676358

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

# The NDK the Rust Android libraries are built with must be named explicitly
# and be the one Flutter's Gradle plugin uses (PIN_NDK).
check_android_ndk() {
  ndk=${ANDROID_NDK_HOME:-}
  [ -n "$ndk" ] || fail "set ANDROID_NDK_HOME to the NDK $PIN_NDK (the newest installed one is not good enough)"
  got=$(sed -n 's/^Pkg\.Revision *= *//p' "$ndk/source.properties" 2>/dev/null | head -n 1)
  [ "$got" = "$PIN_NDK" ] || fail "NDK ${got:-missing} at $ndk, pinned $PIN_NDK"
}

# sha256sum, or shasum on a Mac (which has no sha256sum).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

# What built this output, beside the digests (not inside SHA256SUMS: another
# host legitimately differs here, and comparing hosts compares only the files).
# Records versions only, never paths, user names or environment values.
write_toolchain_record() {
  {
    echo "commit: $(git -C "$ROOT" rev-parse HEAD)"
    echo "source_date_epoch: $SOURCE_DATE_EPOCH"
    echo "os: $(uname -s) $(uname -m)"
    echo "rustc: $(rustc --version 2>/dev/null || echo missing)"
    echo "flutter: $(flutter --version --machine 2>/dev/null | sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' | head -n 1)"
    echo "java: $(java -version 2>&1 | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n 1)"
    if [ -n "${ANDROID_NDK_HOME:-}" ]; then
      echo "android_ndk: $(sed -n 's/^Pkg\.Revision *= *//p' "$ANDROID_NDK_HOME/source.properties" 2>/dev/null | head -n 1)"
    fi
    if [ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]; then
      echo "android_build_tools: $(ls "${ANDROID_HOME:-$ANDROID_SDK_ROOT}/build-tools" 2>/dev/null | sort -V | tr '\n' ' ')"
    fi
  } > "$1"
}
