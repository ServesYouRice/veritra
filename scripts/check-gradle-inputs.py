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

Fails closed: a missing app build script (app/build.gradle.kts or
app/build.gradle), an unreadable file, or an unterminated string or block
comment is an error.
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


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: check-gradle-inputs.py ANDROID_DIR", file=sys.stderr)
        return 2
    android = Path(argv[0])
    try:
        findings = check_dynamic_versions(android)
    except GradleInputError as exc:
        print(f"Gradle input check failed: {exc}", file=sys.stderr)
        return 1
    if findings:
        print("dynamic or changing Gradle versions found:", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
