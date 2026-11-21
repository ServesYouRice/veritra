#!/bin/sh
# Compares the SHA256SUMS of the same target built on two different hosts
# (for example the CI runner and the owner's machine). F-Droid's check needs
# this: one host building twice (verify.sh) is necessary, not sufficient.
#
#   scripts/repro/compare.sh SUMS_A SUMS_B
#
# Exit 0 only when both files list the same paths with the same digests.
# Prints every path that differs, is missing, or is extra. Reads files only.
set -eu

A=${1:-}
B=${2:-}
[ -n "$A" ] && [ -n "$B" ] && [ -f "$A" ] && [ -f "$B" ] || {
  echo "usage: $0 SUMS_A SUMS_B (two SHA256SUMS files)" >&2
  exit 2
}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/veritra-compare.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
# The Windows script writes CRLF line ends; the content is what is compared.
tr -d '\r' < "$A" > "$TMP/a.raw"
tr -d '\r' < "$B" > "$TMP/b.raw"
for f in "$TMP/a.raw" "$TMP/b.raw"; do
  [ -s "$f" ] || { echo "compare: an input file is empty" >&2; exit 2; }
  # "<64 hex>  <path>" on every line, nothing else.
  if grep -Evq '^[0-9a-f]{64}  [^ ].*$' "$f"; then
    echo "compare: an input file is not a SHA256SUMS file" >&2
    exit 2
  fi
done
LC_ALL=C sort "$TMP/a.raw" > "$TMP/a"
LC_ALL=C sort "$TMP/b.raw" > "$TMP/b"
if cmp -s "$TMP/a" "$TMP/b"; then
  echo "identical ($(wc -l < "$TMP/a" | tr -d ' ') files)"
  exit 0
fi
echo "DIFFERENT" >&2
# Paths only in A (<), only in B (>), or in both with different digests (!).
awk 'NR==FNR { a[substr($0, 67)] = substr($0, 1, 64); next }
     { b[substr($0, 67)] = substr($0, 1, 64) }
     END {
       for (p in a) { if (!(p in b)) print "only in A: " p; else if (a[p] != b[p]) print "differs:   " p }
       for (p in b) if (!(p in a)) print "only in B: " p
     }' "$TMP/a" "$TMP/b" | LC_ALL=C sort >&2
exit 1
