#!/usr/bin/env python3
"""Offline unit tests for coverage parser and regression floor enforcement."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("check-coverage.py")
spec = importlib.util.spec_from_file_location("check_coverage", MODULE_PATH)
assert spec and spec.loader
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def test_parse_lcov() -> None:
    valid_lcov = """
SF:lib/core/api_client.dart
DA:1,5
DA:2,0
LF:10
LH:8
end_of_record
SF:lib/core/models.dart
DA:10,2
LF:20
LH:16
end_of_record
"""
    hit, found, pct = checker.parse_lcov(valid_lcov)
    assert found == 30
    assert hit == 24
    assert abs(pct - 80.0) < 1e-6

    # Malformed LCOV cases
    for bad in ["", "no records here", "SF:test.dart\nLF:abc\nend_of_record", "SF:test.dart\nLF:0\nLH:0\nend_of_record"]:
        try:
            checker.parse_lcov(bad)
            raise AssertionError(f"expected LCOV {bad!r} to fail validation")
        except ValueError:
            pass


def test_parse_go_coverprofile() -> None:
    valid_go = """mode: atomic
private-messenger/server/internal/auth/auth.go:10.2,15.10 3 1
private-messenger/server/internal/auth/auth.go:16.2,20.10 2 0
private-messenger/server/internal/domain/types.go:5.2,8.10 5 10
"""
    hit, found, pct = checker.parse_go_coverprofile(valid_go)
    assert found == 10  # 3 + 2 + 5
    assert hit == 8    # 3 + 0 + 5
    assert abs(pct - 80.0) < 1e-6

    # Malformed Go coverprofile cases
    for bad in ["", "not mode header", "mode: set\nmalformed line", "mode: set\npath.go:1.1,2.2 abc 1", "mode: set\npath.go:1.1,2.2 -1 1"]:
        try:
            checker.parse_go_coverprofile(bad)
            raise AssertionError(f"expected Go coverprofile {bad!r} to fail validation")
        except ValueError:
            pass


def test_check_floor() -> None:
    assert checker.check_floor("Test", 85.0, 80.0) is True
    assert checker.check_floor("Test", 80.0, 80.0) is True
    assert checker.check_floor("Test", 79.9, 80.0) is False


def test_cli_execution() -> None:
    valid_lcov = "SF:test.dart\nLF:10\nLH:9\nend_of_record\n"
    valid_go = "mode: set\np.go:1.1,2.2 10 1\n"

    with tempfile.TemporaryDirectory() as temp_dir:
        lcov_file = Path(temp_dir) / "lcov.info"
        lcov_file.write_text(valid_lcov, encoding="utf-8")

        go_file = Path(temp_dir) / "coverage.out"
        go_file.write_text(valid_go, encoding="utf-8")

        # Passing floors
        res_pass = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--flutter-lcov",
                str(lcov_file),
                "--flutter-floor",
                "85.0",
                "--go-profile",
                str(go_file),
                "--go-floor",
                "95.0",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        assert res_pass.returncode == 0, f"expected CLI pass, got: {res_pass.stderr}"

        # Failing floor on Flutter (90% actual < 95% floor)
        res_fail_flutter = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--flutter-lcov",
                str(lcov_file),
                "--flutter-floor",
                "95.0",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        assert res_fail_flutter.returncode != 0

        # Missing file fails
        res_missing = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--go-profile",
                str(Path(temp_dir) / "missing.out"),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        assert res_missing.returncode != 0


if __name__ == "__main__":
    test_parse_lcov()
    test_parse_go_coverprofile()
    test_check_floor()
    test_cli_execution()
    print("Coverage parser and floor enforcement tests passed")
