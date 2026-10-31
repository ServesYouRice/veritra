#!/usr/bin/env python3
"""Check that every resolved Dart dependency ships a license file.

The inventory is the package configuration pub resolved for the app
(mobile/.dart_tool/package_config.json): hosted, git, path and SDK packages
alike, each root resolved relative to that file. With --lock, the configured
packages must be exactly the packages in pubspec.lock, so a stale
configuration fails. This checks presence only, not license compatibility.

Packages that live inside the Flutter SDK (flutterRoot in the configuration)
and have no license file of their own are accepted only when pubspec.lock
says they come from the SDK and the SDK root has its own license file. Each
one is printed on every run: whether that is the right policy is open owner
question UQ-005.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname

LICENSE_PREFIXES = ("license", "copying")
LOCK_PACKAGE = re.compile(r"^  ([A-Za-z0-9_]+):\s*$")
LOCK_SOURCE = re.compile(r"^    source:\s*(\S+)\s*$")


class LicenseCheckError(Exception):
    """The inventory cannot be read or trusted."""


def file_uri_path(uri: object, base: str, label: str) -> Path:
    if not isinstance(uri, str) or not uri:
        raise LicenseCheckError(f"{label} has no URI")
    parsed = urlparse(urljoin(base, uri))
    if parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
        raise LicenseCheckError(f"{label} is not a local file: URI: {uri}")
    return Path(url2pathname(parsed.path))


def has_license(directory: Path) -> bool:
    try:
        entries = list(directory.iterdir())
    except OSError as exc:
        raise LicenseCheckError(f"cannot read package root {directory}: {exc}") from exc
    return any(entry.is_file() and entry.name.lower().startswith(LICENSE_PREFIXES) for entry in entries)


def read_lock_sources(lock: Path) -> dict[str, str]:
    """Package name -> source from pubspec.lock's packages section."""
    try:
        lines = lock.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise LicenseCheckError(f"cannot read {lock}: {exc}") from exc
    sources: dict[str, str] = {}
    in_packages = False
    current: str | None = None
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            in_packages = line.rstrip() == "packages:"
            current = None
            continue
        if not in_packages:
            continue
        package = LOCK_PACKAGE.match(line)
        if package:
            current = package.group(1)
            if current in sources:
                raise LicenseCheckError(f"{lock} lists {current} twice")
            sources[current] = ""
            continue
        source = LOCK_SOURCE.match(line)
        if source and current is not None:
            sources[current] = source.group(1).strip('"')
    if not sources:
        raise LicenseCheckError(f"{lock} lists no packages")
    unsourced = sorted(name for name, source in sources.items() if not source)
    if unsourced:
        raise LicenseCheckError(f"{lock} has packages without a source: {', '.join(unsourced)}")
    return sources


def load_packages(config: Path) -> tuple[dict[str, Path], Path | None]:
    """Non-root package name -> resolved root, and the Flutter SDK root."""
    if not config.is_file():
        raise LicenseCheckError(
            f"Dart package configuration is unavailable ({config}); run flutter pub get first"
        )
    try:
        data = json.loads(config.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise LicenseCheckError(f"cannot read {config}: {exc}") from exc
    if not isinstance(data, dict) or data.get("configVersion") != 2:
        raise LicenseCheckError(f"{config} is not a version 2 package configuration")
    entries = data.get("packages")
    if not isinstance(entries, list) or not entries:
        raise LicenseCheckError(f"{config} lists no packages")

    base = config.resolve().as_uri()
    app_root = config.resolve().parent.parent
    flutter_root = None
    if "flutterRoot" in data:
        flutter_root = file_uri_path(data["flutterRoot"], base, "flutterRoot").resolve()

    packages: dict[str, Path] = {}
    seen: set[str] = set()
    found_app = False
    for entry in entries:
        name = entry.get("name") if isinstance(entry, dict) else None
        if not isinstance(name, str) or not name:
            raise LicenseCheckError(f"{config} has a package entry without a name")
        if name in seen:
            raise LicenseCheckError(f"{config} lists {name} twice")
        seen.add(name)
        root = file_uri_path(entry.get("rootUri"), base, f"package {name}").resolve()
        if root == app_root:
            # The app itself; its license is the repository's.
            found_app = True
            continue
        packages[name] = root
    if not found_app:
        raise LicenseCheckError(f"{config} does not belong to the app at {app_root}")
    return packages, flutter_root


def check(config: Path, lock: Path | None) -> tuple[list[str], list[str], list[str]]:
    """Return (licensed, sdk_covered, missing) package names."""
    packages, flutter_root = load_packages(config)
    if not packages:
        raise LicenseCheckError(f"{config} lists no dependency packages")

    lock_sources = None
    if lock is not None:
        lock_sources = read_lock_sources(lock)
        configured, locked = set(packages), set(lock_sources)
        if configured != locked:
            details = []
            if locked - configured:
                details.append("not configured: " + ", ".join(sorted(locked - configured)))
            if configured - locked:
                details.append("not locked: " + ", ".join(sorted(configured - locked)))
            raise LicenseCheckError(
                f"{config} does not match {lock} ({'; '.join(details)}); run flutter pub get"
            )

    sdk_licensed = flutter_root is not None and flutter_root.is_dir() and has_license(flutter_root)
    licensed: list[str] = []
    sdk_covered: list[str] = []
    missing: list[str] = []
    for name in sorted(packages):
        root = packages[name]
        if not root.is_dir():
            raise LicenseCheckError(f"package {name} root is missing: {root}")
        if has_license(root):
            licensed.append(name)
        elif (
            sdk_licensed
            and flutter_root is not None
            and root.is_relative_to(flutter_root)
            and (lock_sources is None or lock_sources.get(name) == "sdk")
        ):
            sdk_covered.append(name)
        else:
            missing.append(name)
    return licensed, sdk_covered, missing


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", type=Path, required=True, help="path to .dart_tool/package_config.json")
    parser.add_argument("--lock", type=Path, help="path to pubspec.lock; the configuration must match it")
    args = parser.parse_args(argv)
    try:
        licensed, sdk_covered, missing = check(args.config, args.lock)
    except LicenseCheckError as exc:
        print(f"Dart license check failed: {exc}", file=sys.stderr)
        return 1
    for name in missing:
        print(f"Dart dependency lacks a packaged license: {name}", file=sys.stderr)
    if missing:
        return 1
    for name in sdk_covered:
        print(f"{name}: no license file in its package root; covered by the Flutter SDK license (UQ-005)")
    count = len(licensed) + len(sdk_covered)
    print(f"Dart dependency license files present: {count} packages ({len(sdk_covered)} via the Flutter SDK license)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
