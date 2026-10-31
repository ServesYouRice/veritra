#!/usr/bin/env python3
"""Reject mutable Gradle inputs in the Android project.

Usage: check-gradle-inputs.py ANDROID_DIR

Scans every *.gradle and *.gradle.kts file (build and settings scripts of any
module, Groovy or Kotlin) and every version catalog (*.versions.toml, and any
*.toml under a gradle/ directory) below ANDROID_DIR. Comments are skipped and
only quoted string literals are inspected, so code such as arithmetic never
matches. A literal fails when it holds a dynamic or changing version: a `+`
selector (1.+, 1.2.+, 1.2.3+, a bare +), a version range ([1.0,2.0), (,2.0]
and similar), latest.release / latest.integration, :latest, :release, or a
SNAPSHOT in any letter case.

gradle/wrapper/gradle-wrapper.properties must name exactly one
distributionUrl on https://services.gradle.org/distributions/ for a pinned
gradle-X.Y[.Z]-(bin|all).zip. A distributionSha256Sum, when present, must be
64 lowercase hex characters. Its absence is reported as a warning for now:
requiring it needs the official checksum added to the properties file.

Fails closed: a missing app build script (app/build.gradle.kts or
app/build.gradle), a missing or empty wrapper properties file, an unreadable
file, a duplicate property, or an unterminated string or block comment is an
error.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

DYNAMIC_VERSIONS = (
    ("dynamic '+' version", re.compile(r"(^|[:.\d])\+($|[@:\s])")),
    ("version range", re.compile(r"(^|:)\s*[\[\]\(][^,\[\]\(\)]*,[^,\[\]\(\)]*[\]\[\)]\s*($|[@:])")),
    ("latest.* version", re.compile(r"(^|:)\s*latest\.", re.IGNORECASE)),
    ("latest or release selector", re.compile(r":(latest|release)", re.IGNORECASE)),
    ("SNAPSHOT version", re.compile(r"(^|[^a-z0-9])snapshot", re.IGNORECASE)),
)


WRAPPER_PROPERTIES = Path("gradle/wrapper/gradle-wrapper.properties")
WRAPPER_URL = re.compile(r"https://services\.gradle\.org/distributions/gradle-[0-9]+\.[0-9]+(\.[0-9]+)?-(bin|all)\.zip")
WRAPPER_SHA256 = re.compile(r"[0-9a-f]{64}")
PROPERTY_ESCAPES = {"t": "\t", "n": "\n", "r": "\r", "f": "\f"}


class GradleInputError(Exception):
    """A Gradle input cannot be read or tokenized."""


def string_literals(text: str, toml: bool) -> list[tuple[int, str]]:
    """Return (line, content) for each string literal outside comments.

    Kotlin/Groovy: // and /* */ comments; "...", '...' (also Kotlin char
    literals) and triple-quoted strings. TOML: # comments and the same quote
    forms. Raises GradleInputError on an unterminated string or comment.
    """
    literals: list[tuple[int, str]] = []
    i, line, length = 0, 1, len(text)
    while i < length:
        char = text[i]
        if char == "\n":
            line += 1
            i += 1
        elif (toml and char == "#") or (not toml and text.startswith("//", i)):
            end = text.find("\n", i)
            i = length if end == -1 else end
        elif not toml and text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end == -1:
                raise GradleInputError(f"line {line}: unterminated block comment")
            line += text.count("\n", i, end)
            i = end + 2
        elif text.startswith('"""', i) or text.startswith("'''", i):
            quote = text[i : i + 3]
            end = text.find(quote, i + 3)
            if end == -1:
                raise GradleInputError(f"line {line}: unterminated {quote} string")
            literals.append((line, text[i + 3 : end]))
            line += text.count("\n", i, end)
            i = end + 3
        elif char in "\"'":
            start_line = line
            content: list[str] = []
            j = i + 1
            while True:
                if j >= length or text[j] == "\n":
                    raise GradleInputError(f"line {start_line}: unterminated string")
                if text[j] == "\\" and j + 1 < length:
                    content.append(text[j + 1])
                    j += 2
                    continue
                if text[j] == char:
                    break
                content.append(text[j])
                j += 1
            literals.append((start_line, "".join(content)))
            i = j + 1
        else:
            i += 1
    return literals


def dynamic_reason(literal: str) -> str | None:
    value = literal.strip()
    for reason, pattern in DYNAMIC_VERSIONS:
        if pattern.search(value):
            return reason
    return None


def gradle_files(android: Path) -> list[Path]:
    files = set()
    for path in android.rglob("*"):
        name = path.name
        if not path.is_file():
            continue
        if name.endswith((".gradle", ".gradle.kts", ".versions.toml")):
            files.add(path)
        elif name.endswith(".toml") and path.parent.name == "gradle":
            files.add(path)
    return sorted(files)


def check_dynamic_versions(android: Path) -> list[str]:
    """Return 'file:line: reason: "literal"' for each dynamic version."""
    if not android.is_dir():
        raise GradleInputError(f"Android project not found: {android}")
    app = android / "app"
    if not (app / "build.gradle.kts").is_file() and not (app / "build.gradle").is_file():
        raise GradleInputError(f"no app build script (app/build.gradle.kts or app/build.gradle) in {android}")
    findings = []
    for path in gradle_files(android):
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise GradleInputError(f"cannot read {path}: {exc}") from exc
        try:
            literals = string_literals(text, toml=path.suffix == ".toml")
        except GradleInputError as exc:
            raise GradleInputError(f"{path}: {exc}") from exc
        for line, literal in literals:
            reason = dynamic_reason(literal)
            if reason:
                findings.append(f'{path}:{line}: {reason}: "{literal}"')
    return findings


def unescape_property(value: str) -> str:
    out: list[str] = []
    i = 0
    while i < len(value):
        char = value[i]
        if char != "\\" or i + 1 >= len(value):
            out.append(char)
            i += 1
            continue
        escaped = value[i + 1]
        if escaped == "u":
            digits = value[i + 2 : i + 6]
            if not re.fullmatch(r"[0-9a-fA-F]{4}", digits):
                raise GradleInputError(f"malformed \\u escape in property value: {value}")
            out.append(chr(int(digits, 16)))
            i += 6
            continue
        out.append(PROPERTY_ESCAPES.get(escaped, escaped))
        i += 2
    return "".join(out)


def read_properties(path: Path) -> dict[str, str]:
    """Parse a java.util.Properties file; a repeated key is an error."""
    try:
        raw_lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise GradleInputError(f"cannot read {path}: {exc}") from exc
    logical: list[str] = []
    pending: str | None = None
    for raw in raw_lines:
        line = raw.lstrip(" \t\f")
        if pending is None and (not line or line[0] in "#!"):
            continue
        line = line if pending is None else pending + line
        trailing = len(line) - len(line.rstrip("\\"))
        if trailing % 2 == 1:
            pending = line[:-1]
            continue
        pending = None
        logical.append(line)
    if pending is not None:
        logical.append(pending)

    properties: dict[str, str] = {}
    for line in logical:
        match = re.match(r"((?:[^\\=:\s]|\\.)*)[ \t\f]*[=:]?[ \t\f]*(.*)$", line, re.DOTALL)
        assert match is not None
        key, value = unescape_property(match.group(1)), unescape_property(match.group(2))
        if key in properties:
            raise GradleInputError(f"{path} sets {key} more than once")
        properties[key] = value
    return properties


def check_wrapper(android: Path) -> list[str]:
    """Return warnings; raise GradleInputError when the wrapper is not pinned."""
    path = android / WRAPPER_PROPERTIES
    if not path.is_file() or path.stat().st_size == 0:
        raise GradleInputError(f"Gradle wrapper properties missing or empty: {path}")
    properties = read_properties(path)
    url = properties.get("distributionUrl")
    if url is None:
        raise GradleInputError(f"{path} has no distributionUrl")
    if not WRAPPER_URL.fullmatch(url):
        raise GradleInputError(
            f"{path}: distributionUrl must be a pinned https://services.gradle.org/distributions/"
            f"gradle-<version>-(bin|all).zip, not {url}"
        )
    checksum = properties.get("distributionSha256Sum")
    if checksum is None:
        return [
            f"{path} has no distributionSha256Sum: the Gradle distribution is not integrity-pinned "
            f"(add the official checksum from {url}.sha256)"
        ]
    if not WRAPPER_SHA256.fullmatch(checksum):
        raise GradleInputError(f"{path}: distributionSha256Sum must be 64 lowercase hex characters")
    return []


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: check-gradle-inputs.py ANDROID_DIR", file=sys.stderr)
        return 2
    android = Path(argv[0])
    try:
        warnings = check_wrapper(android)
        findings = check_dynamic_versions(android)
    except GradleInputError as exc:
        print(f"Gradle input check failed: {exc}", file=sys.stderr)
        return 1
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    if findings:
        print("dynamic or changing Gradle versions found:", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
