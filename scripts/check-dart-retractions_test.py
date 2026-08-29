#!/usr/bin/env python3
"""Tests the Pub JSON shape and fail-closed retraction behavior."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


CHECKER = Path(__file__).with_name("check-dart-retractions.py")


def run(payload: object) -> int:
    handle = tempfile.NamedTemporaryFile(mode="w", suffix=".json", encoding="utf-8", delete=False)
    try:
        json.dump(payload, handle)
        handle.close()
        return subprocess.run([sys.executable, str(CHECKER), handle.name], check=False).returncode
    finally:
        Path(handle.name).unlink(missing_ok=True)


assert run({"packages": [{"package": "safe", "isCurrentRetracted": False}]}) == 0
assert run({"packages": [{"package": "bad", "isCurrentRetracted": True}]}) != 0
assert run({"packages": [{"package": "unknown"}]}) != 0
assert run({"unexpected": []}) != 0
print("Dart retraction adversarial tests passed")
