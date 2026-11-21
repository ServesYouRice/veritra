#!/usr/bin/env python3
"""Check Gradle dependency locking and verification for the Android app.

Usage: check-gradle-locks.py ANDROID_DIR [--require-files]

Three things are checked (docs/release-engineering.md, "Gradle dependency
locking"):

1. The build wiring. build.gradle.kts must turn locking on for every project
   (`lockAllConfigurations()` inside `allprojects`), must keep each lockfile
   under gradle/locks/ in this repository, and must not weaken the mode
   (LockMode.LENIENT is refused). Removing the wiring fails this check.
2. Every gradle/locks/*.lockfile that exists is well formed: Gradle's header,
   `group:artifact:version=config,...` entries with a fixed version (no `+`,
   range, latest or SNAPSHOT), and a single `empty=` line at most.
3. gradle/verification-metadata.xml, when it exists, turns checksum
   verification on, lists a sha256 for every artifact of every component (a
   component with only md5/sha1 or none is refused), and does not trust
   artifacts by a catch-all regular expression.

Without --require-files a missing lock or verification file is reported as
"not generated yet" and is not an error: the lockfiles can only be written on
a host with the Android SDK (scripts/gradle-lock.sh). With --require-files
(the release candidate check) the missing files are an error.

Fails closed: an unreadable or malformed file is an error.
"""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

LOCK_DIR = Path("gradle/locks")
VERIFICATION = Path("gradle/verification-metadata.xml")
REQUIRED_LOCKFILES = ("app.lockfile",)
LOCK_HEADER = "# This is a Gradle generated file for dependency locking."
ENTRY = re.compile(r"^[A-Za-z0-9_.\-]+:[A-Za-z0-9_.\-]+:[^\s:=,+\[\]()*]+=[A-Za-z0-9_,\-]+$")
EMPTY = re.compile(r"^empty=[A-Za-z0-9_,\-]*$")
DYNAMIC = re.compile(r"(^|[:.\d])\+($|[@:=])|latest\.|snapshot|[\[\]()]", re.IGNORECASE)
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class LockError(Exception):
    """A lock input is unreadable or malformed."""


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


def allprojects_block(text: str) -> str | None:
    """The body of the first `allprojects { ... }` block (balanced braces)."""
    match = re.search(r"\ballprojects\s*\{", text)
    if not match:
        return None
    depth, start = 1, match.end()
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i]
    raise LockError("build.gradle.kts: unbalanced braces in allprojects")


def check_wiring(android: Path) -> list[str]:
    path = android / "build.gradle.kts"
    try:
        text = strip_comments(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError) as exc:
        raise LockError(f"cannot read {path}: {exc}") from exc
    errors = []
    block = allprojects_block(text)
    if block is None:
        return ["build.gradle.kts has no allprojects block, so no project is locked"]
    if not re.search(r"\bdependencyLocking\s*\{", block) or not re.search(r"\blockAllConfigurations\s*\(\s*\)", block):
        errors.append("build.gradle.kts: allprojects must call dependencyLocking { lockAllConfigurations() }")
    if not re.search(r"\blockFile\b[^\n]*gradle/locks/", block):
        errors.append("build.gradle.kts: lockfiles must be redirected to gradle/locks/ inside this repository")
    if re.search(r"LockMode\.LENIENT|lockMode[^\n]*LENIENT", text):
        errors.append("build.gradle.kts: LockMode.LENIENT weakens locking")
    return errors


def check_lockfile(path: Path) -> list[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise LockError(f"cannot read {path}: {exc}") from exc
    errors = []
    if not lines or lines[0] != LOCK_HEADER:
        errors.append(f"{path}: not a Gradle lockfile (missing the generated-file header)")
    seen: set[str] = set()
    empties = 0
    for number, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        if EMPTY.match(line):
            empties += 1
            continue
        if not ENTRY.match(line) or DYNAMIC.search(line.split("=", 1)[0]):
            errors.append(f"{path}:{number}: not a fixed-version lock entry: {line!r}")
            continue
        coordinate = line.split("=", 1)[0]
        if coordinate in seen:
            errors.append(f"{path}:{number}: duplicate entry {coordinate}")
        seen.add(coordinate)
    if empties > 1:
        errors.append(f"{path}: more than one empty= line")
    if not seen and empties == 0:
        errors.append(f"{path}: no entries")
    return errors


def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def check_verification(path: Path) -> list[str]:
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as exc:
        raise LockError(f"cannot parse {path}: {exc}") from exc
    errors = []
    if local(root.tag) != "verification-metadata":
        return [f"{path}: root element is not verification-metadata"]
    config = next((child for child in root if local(child.tag) == "configuration"), None)
    verify = next((child for child in config if local(child.tag) == "verify-metadata"), None) if config is not None else None
    if verify is None or (verify.text or "").strip() != "true":
        errors.append(f"{path}: <verify-metadata>true</verify-metadata> is required")
    if config is not None:
        for trusted in config.iter():
            if local(trusted.tag) in ("trusted-artifact", "trust") and trusted.get("regex") == "true":
                errors.append(f"{path}: trusting artifacts by regular expression is not allowed")
    components = next((child for child in root if local(child.tag) == "components"), None)
    if components is None or not list(components):
        errors.append(f"{path}: no components are verified")
        return errors
    for component in components:
        name = f"{component.get('group')}:{component.get('name')}:{component.get('version')}"
        artifacts = [child for child in component if local(child.tag) == "artifact"]
        if not artifacts:
            errors.append(f"{path}: component {name} lists no artifact")
        for artifact in artifacts:
            sums = [child for child in artifact if local(child.tag) == "sha256"]
            if not sums or not all(SHA256.match(child.get("value", "")) for child in sums):
                errors.append(f"{path}: artifact {artifact.get('name')} of {name} has no valid sha256")
    return errors


def check(android: Path, require_files: bool) -> tuple[list[str], list[str]]:
    """Return (errors, notes)."""
    if not android.is_dir():
        raise LockError(f"Android project not found: {android}")
    errors = check_wiring(android)
    notes: list[str] = []
    lock_dir = android / LOCK_DIR
    lockfiles = sorted(lock_dir.glob("*.lockfile")) if lock_dir.is_dir() else []
    for path in lockfiles:
        errors += check_lockfile(path)
    missing = [name for name in REQUIRED_LOCKFILES if not (lock_dir / name).is_file()]
    verification = android / VERIFICATION
    if verification.is_file():
        errors += check_verification(verification)
    else:
        missing.append(str(VERIFICATION))
    for name in missing:
        message = f"{name} not generated yet (run scripts/gradle-lock.sh write on a host with the Android SDK)"
        if require_files:
            errors.append(message)
        else:
            notes.append(message)
    return errors, notes


def main(argv: list[str]) -> int:
    args = [a for a in argv if a != "--require-files"]
    require = len(args) != len(argv)
    if len(args) != 1:
        print("usage: check-gradle-locks.py ANDROID_DIR [--require-files]", file=sys.stderr)
        return 2
    try:
        errors, notes = check(Path(args[0]), require)
    except LockError as exc:
        print(f"Gradle lock check failed: {exc}", file=sys.stderr)
        return 1
    for note in notes:
        print(f"note: {note}")
    if errors:
        print("Gradle lock check failed:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1
    print("Gradle lock wiring ok" + ("" if not notes else " (lock files not generated yet)"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
