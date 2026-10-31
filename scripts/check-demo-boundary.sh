#!/usr/bin/env sh
# Decision D11: demo builds run unreviewed crypto through
# mobile/lib/main_demo.dart only. Release builds use mobile/lib/main.dart,
# which must keep crypto unavailable. This check keeps the two apart.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$ROOT/mobile/lib"
MAIN="$LIB/main.dart"
DEMO="$LIB/main_demo.dart"
NATIVE="$LIB/crypto/native_crypto_service.dart"
TRANSPORT="$LIB/core/transport_policy.dart"
fail=0

# forbid LABEL PATTERN [ALLOWED_FILE...]: every file under mobile/lib whose
# text matches the extended regex PATTERN fails the check, unless its path is
# exactly one of ALLOWED_FILE. Symlinks are followed; a scan error fails.
forbid() {
  label=$1
  pattern=$2
  shift 2
  status=0
  matches=$(grep -RlE -e "$pattern" "$LIB") || status=$?
  if [ "$status" -gt 1 ]; then
    echo "demo boundary: cannot scan mobile/lib for $label" >&2
    fail=1
    return 0
  fi
  offenders=
  saved_ifs=$IFS
  IFS='
'
  set -f
  for file in $matches; do
    allowed_file=0
    for allowed in "$@"; do
      if [ "$file" = "$allowed" ]; then
        allowed_file=1
      fi
    done
    if [ "$allowed_file" -eq 0 ]; then
      offenders="$offenders  $file
"
    fi
  done
  set +f
  IFS=$saved_ifs
  if [ -n "$offenders" ]; then
    echo "demo boundary: $label outside its allowed files:" >&2
    printf '%s' "$offenders" >&2
    fail=1
  fi
  return 0
}

if [ ! -d "$LIB" ]; then
  echo "demo boundary: mobile/lib is missing" >&2
  exit 1
fi

if ! grep -q 'UnavailableCryptoService()' "$MAIN"; then
  echo "demo boundary: mobile/lib/main.dart must keep UnavailableCryptoService" >&2
  fail=1
fi
if grep -Eq 'native_crypto_service|NativeCryptoService|main_demo|TransportPolicy\.demo|demo: true' "$MAIN"; then
  echo "demo boundary: mobile/lib/main.dart must not reference demo wiring" >&2
  fail=1
fi
if ! grep -q "bool.fromEnvironment('VERITRA_DEMO')" "$DEMO"; then
  echo "demo boundary: main_demo.dart must stay guarded by VERITRA_DEMO" >&2
  fail=1
fi
# Only main_demo.dart may reach the native service or the demo transport. Any
# mention counts (constructor, tear-off, static member, type, alias), and any
# reference to the native service library (import, export, conditional
# import, re-export). Exemptions are exact paths and per pattern.
forbid "the native crypto service" \
  '(^|[^A-Za-z0-9_$])NativeCryptoService([^A-Za-z0-9_$]|$)' "$DEMO" "$NATIVE"
forbid "the native crypto service library" 'native_crypto_service\.dart' "$DEMO"
forbid "the demo transport" \
  'TransportPolicy[[:space:]]*\.[[:space:]]*demo([^A-Za-z0-9_$]|$)' "$DEMO" "$TRANSPORT"
# TransportPolicy(allowLoopbackHttp: true) is the demo transport by another name.
forbid "a loopback HTTP transport" 'allowLoopbackHttp[[:space:]]*:' "$TRANSPORT"

# The token scans above are textual. The release entry could still reach the
# demo wiring through a library that names none of those tokens (for example
# a bootstrap file that imports main_demo.dart). Follow the Dart import graph
# from main.dart: every import, export and part, every conditional-import
# alternative, relative and package: URIs (this app and local path packages),
# symlinks resolved. Neither main_demo.dart nor the native service library
# may be reachable. native_crypto_bindings.dart is reachable on purpose
# (attachment and backup crypto); the MLS service is what must stay out.
PY=
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PY=$candidate
    break
  fi
done
if [ -z "$PY" ]; then
  echo "demo boundary: python3 is required to follow the release entry's imports" >&2
  fail=1
elif ! "$PY" - "$ROOT/mobile" "$MAIN" "$DEMO" "$NATIVE" <<'PY'
import os
import re
import sys
from pathlib import Path

app, main, *forbidden = (Path(arg) for arg in sys.argv[1:])
forbidden = {path.resolve(): path for path in forbidden}


def package_roots(app):
    """Map package names to lib/ folders: this app and its path packages."""
    roots = {"private_messenger": app / "lib"}
    pubspec = app / "pubspec.yaml"
    if pubspec.is_file():
        name = re.search(
            r"^name:\s*['\"]?([A-Za-z0-9_]+)", pubspec.read_text(encoding="utf-8"), re.M
        )
        if name:
            roots = {name.group(1): app / "lib"}
    # A path package is a two-space-indented key whose block holds a "path:"
    # line: "  pkg:\n    path: ../pkg" in pubspec.yaml (any dependency
    # section), "  pkg:\n    description:\n      path: ..." in pubspec.lock,
    # which also lists transitive path packages.
    for source in (pubspec, app / "pubspec.lock"):
        if not source.is_file():
            continue
        package = None
        for line in source.read_text(encoding="utf-8").splitlines():
            key = re.match(r"^  ([A-Za-z0-9_]+):", line)
            if key:
                package = key.group(1)
                continue
            if not line.startswith("   "):
                package = None
                continue
            path = re.match(r"^\s+path:\s*['\"]?([^'\"#]+?)['\"]?\s*(?:#.*)?$", line)
            if package and path:
                roots.setdefault(package, app / path.group(1) / "lib")
    return roots


COMMENTS_AND_STRINGS = re.compile(
    r"//[^\n]*|/\*.*?\*/|'''.*?'''|\"\"\".*?\"\"\"|'(?:\\.|[^'\\\n])*'|\"(?:\\.|[^\"\\\n])*\"",
    re.S,
)
DIRECTIVE = re.compile(r"(?:^|[;}\s])(?:import|export|part)\b(?!\s+of\b)([^;]*);")
STRING = re.compile(r"'([^']*)'|\"([^\"]*)\"")


def strip_comments(text):
    # Comments go; string literals stay (the URIs live in them).
    return COMMENTS_AND_STRINGS.sub(
        lambda m: m.group(0) if m.group(0)[0] in "'\"" else " ", text
    )


def uris(text):
    for directive in DIRECTIVE.finditer(strip_comments(text)):
        for literal in STRING.finditer(directive.group(1)):
            yield literal.group(1) if literal.group(1) is not None else literal.group(2)


def logical(path):
    # Dart resolves a relative URI against the importing file's own path,
    # not its symlink target, so walk logical paths and resolve only to
    # compare with the forbidden files.
    return Path(os.path.normpath(os.path.abspath(path)))


MAX_FILES = 20000
roots = package_roots(app)
start = logical(main)
parent = {start: None}
queue = [start]
broken = False
while queue:
    current = queue.pop()
    real = current.resolve()
    if real in forbidden:
        chain = []
        node = current
        while node is not None:
            chain.append(str(node))
            node = parent[node]
        print(
            "demo boundary: mobile/lib/main.dart reaches "
            + str(forbidden[real])
            + " through:\n  "
            + "\n  ".join(reversed(chain)),
            file=sys.stderr,
        )
        broken = True
        continue
    try:
        text = current.read_text(encoding="utf-8")
    except OSError:
        # A missing target is the analyzer's problem, not a reachable file.
        continue
    if len(parent) > MAX_FILES:
        # Symlinked folders can make logical paths grow without end.
        print("demo boundary: the release entry's import graph is too large", file=sys.stderr)
        sys.exit(1)
    for uri in uris(text):
        if uri.startswith("dart:"):
            continue
        if uri.startswith("package:"):
            name, _, rest = uri[len("package:"):].partition("/")
            if name not in roots:
                continue
            targets = [roots[name] / rest]
        else:
            # Follow the URI from the file's own folder and, when that is a
            # symlink, from its target's folder too: either may be the one a
            # toolchain uses.
            targets = [current.parent / uri, real.parent / uri]
        for target in targets:
            target = logical(target)
            if target not in parent:
                parent[target] = current
                queue.append(target)
sys.exit(1 if broken else 0)
PY
then
  fail=1
fi

for workflow in "$ROOT"/.github/workflows/release*.yml; do
  [ -f "$workflow" ] || continue
  if grep -Eq 'main_demo|VERITRA_DEMO' "$workflow"; then
    echo "demo boundary: $workflow must not build the demo entry point" >&2
    fail=1
  fi
done

[ "$fail" -eq 0 ] || exit 1
echo "demo boundary intact: release entry keeps crypto unavailable"
