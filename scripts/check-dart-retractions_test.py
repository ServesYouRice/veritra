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
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", encoding="utf-8") as handle:
        json.dump(payload, handle)
        handle.flush()
        return subprocess.run([sys.executable, str(CHECKER), handle.name], check=False).returncode


assert run({"packages": [{"package": "safe", "isCurrentRetracted": False}]}) == 0
assert run({"packages": [{"package": "bad", "isCurrentRetracted": True}]}) != 0
assert run({"packages": [{"package": "unknown"}]}) != 0
assert run({"unexpected": []}) != 0
print("Dart retraction adversarial tests passed")
