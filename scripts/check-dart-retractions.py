#!/usr/bin/env python3
"""Fail when pub's machine-readable dependency report contains a retraction."""

from __future__ import annotations

import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
packages = payload.get("packages") if isinstance(payload, dict) else None
if not isinstance(packages, list):
    raise SystemExit("unsupported dart pub outdated JSON: missing packages list")
if any(not isinstance(package, dict) or "isCurrentRetracted" not in package for package in packages):
    raise SystemExit("unsupported dart pub outdated JSON: missing isCurrentRetracted fields")
retracted = [
    package.get("package", package.get("name", "unknown"))
    for package in packages
    if package.get("isCurrentRetracted") is True
]
if retracted:
    raise SystemExit("retracted Dart dependency evidence: " + ", ".join(map(str, retracted)))
