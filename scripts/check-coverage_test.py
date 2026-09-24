#!/usr/bin/env python3
"""Offline tests for coverage parsing, floors, and required-source enforcement."""

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
    valid_lcov = """SF:lib/core/api_client.dart
LF:10
LH:8
end_of_record
SF:lib/core/models.dart
LF:20
LH:16
end_of_record
"""
    hit, found, pct, sources = checker.parse_lcov_report(valid_lcov)
    assert (hit, found) == (24, 30)
    assert abs(pct - 80.0) < 1e-6
    assert sources == {"lib/core/api_client.dart", "lib/core/models.dart"}

    malformed = [
        "",
        "no records here",
        "LF:1\nLH:1\nend_of_record\n",
        "SF:test.dart\nLF:abc\nLH:0\nend_of_record\n",
        "SF:test.dart\nLF:-1\nLH:0\nend_of_record\n",
        "SF:test.dart\nLF:1\nLH:-1\nend_of_record\n",
        "SF:test.dart\nLF:1\nLH:2\nend_of_record\n",
        "SF:test.dart\nLF:1\nLH:1\n",
        "SF:test.dart\nLF:1\nend_of_record\n",
        "SF:test.dart\nSF:other.dart\nLF:1\nLH:1\nend_of_record\n",
        "SF:test.dart\nLF:0\nLH:0\nend_of_record\n",
    ]
    for bad in malformed:
        try:
            checker.parse_lcov_report(bad)
            raise AssertionError(f"expected LCOV {bad!r} to fail validation")
        except ValueError:
            pass


def test_parse_go_coverprofile() -> None:
    valid_go = """mode: atomic
private-messenger/server/internal/auth/auth.go:10.2,15.10 3 1
private-messenger/server/internal/auth/auth.go:16.2,20.10 2 0
private-messenger/server/internal/domain/types.go:5.2,8.10 5 10
"""
    hit, found, pct, sources = checker.parse_go_report(valid_go)
    assert (hit, found) == (8, 10)
    assert abs(pct - 80.0) < 1e-6
    assert "private-messenger/server/internal/auth/auth.go" in sources

    malformed = [
        "",
        "mode: banana\np.go:1.1,2.2 1 1",
        "mode: set\nmalformed line",
        "mode: set\np.go 1 1",
        "mode: set\np.go:not-a-range 1 1",
        "mode: set\np.go:1.1,2.2 abc 1",
        "mode: set\np.go:1.1,2.2 -1 1",
        "mode: set\np.go:1.1,2.2 1 -1",
    ]
    for bad in malformed:
        try:
            checker.parse_go_report(bad)
            raise AssertionError(f"expected Go coverprofile {bad!r} to fail validation")
        except ValueError:
            pass


def test_floor_and_source_matching() -> None:
    assert checker.check_floor("Test", 85.0, 80.0) is True
    assert checker.check_floor("Test", 80.0, 80.0) is True
    assert checker.check_floor("Test", 79.99, 80.0) is False

    sources = {"private-messenger/server/internal/push/native.go"}
    assert checker.missing_required_sources(sources, ["internal/push/native.go"]) == []
    assert checker.missing_required_sources(sources, ["native.go"]) == []
    assert checker.missing_required_sources(sources, ["internal/notpush/native.go"]) == [
        "internal/notpush/native.go"
    ]
    collision = {"lib/notcore/app_state.dart"}
    assert checker.missing_required_sources(collision, ["lib/core/app_state.dart"]) == [
        "lib/core/app_state.dart"
    ]


def run_cli(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(MODULE_PATH), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def test_cli_execution() -> None:
    valid_lcov = """SF:lib/core/app_state.dart
LF:5
LH:5
end_of_record
SF:lib/push/push_service.dart
LF:5
LH:4
end_of_record
SF:lib/storage/local_store.dart
LF:5
LH:4
end_of_record
SF:lib/crypto/attachment_crypto.dart
LF:5
LH:5
end_of_record
"""
    valid_go = """mode: set
private-messenger/server/internal/push/native.go:1.1,2.2 5 1
private-messenger/server/internal/cryptoapi/cryptoapi.go:1.1,2.2 5 1
"""

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        lcov_file = temp / "lcov.info"
        go_file = temp / "coverage.out"
        lcov_file.write_text(valid_lcov, encoding="utf-8")
        go_file.write_text(valid_go, encoding="utf-8")

        passed = run_cli(
            "--go-profile", str(go_file), "--go-floor", "100.0",
            "--go-required-source", "internal/push/native.go",
            "--go-required-source", "internal/cryptoapi/cryptoapi.go",
            "--flutter-lcov", str(lcov_file), "--flutter-floor", "90.0",
            "--flutter-required-source", "lib/core/app_state.dart",
            "--flutter-required-source", "lib/push/push_service.dart",
            "--flutter-required-source", "lib/storage/local_store.dart",
            "--flutter-required-source", "lib/crypto/attachment_crypto.dart",
        )
        assert passed.returncode == 0, passed.stderr

        regression = run_cli(
            "--flutter-lcov", str(lcov_file), "--flutter-floor", "90.01"
        )
        assert regression.returncode != 0

        invalid_configurations = [
            (),
            ("--go-profile", str(go_file)),
            ("--go-floor", "50.0"),
            ("--go-required-source", "internal/push/native.go"),
            ("--flutter-lcov", str(lcov_file)),
            ("--flutter-floor", "40.0"),
            ("--flutter-required-source", "lib/core/app_state.dart"),
        ]
        for arguments in invalid_configurations:
            assert run_cli(*arguments).returncode != 0, arguments

        for invalid_floor in ("nan", "inf", "-0.01", "100.01"):
            assert run_cli("--go-profile", str(go_file), "--go-floor", invalid_floor).returncode != 0

        assert run_cli(
            "--go-profile", str(temp / "missing.out"), "--go-floor", "50.0"
        ).returncode != 0

        for missing_source in ("internal/push/native.go", "internal/cryptoapi/cryptoapi.go"):
            removed = next(line for line in valid_go.splitlines(keepends=True) if missing_source in line)
            go_file.write_text(valid_go.replace(removed, ""), encoding="utf-8")
            result = run_cli(
                "--go-profile", str(go_file), "--go-floor", "0.0",
                "--go-required-source", missing_source,
            )
            assert result.returncode != 0, missing_source
        go_file.write_text(valid_go, encoding="utf-8")

        for missing_source in (
            "lib/core/app_state.dart",
            "lib/push/push_service.dart",
            "lib/storage/local_store.dart",
            "lib/crypto/attachment_crypto.dart",
        ):
            records = valid_lcov.split("end_of_record\n")
            remaining = "end_of_record\n".join(record for record in records if missing_source not in record)
            lcov_file.write_text(remaining, encoding="utf-8")
            result = run_cli(
                "--flutter-lcov", str(lcov_file), "--flutter-floor", "0.0",
                "--flutter-required-source", missing_source,
            )
            assert result.returncode != 0, missing_source


if __name__ == "__main__":
    test_parse_lcov()
    test_parse_go_coverprofile()
    test_floor_and_source_matching()
    test_cli_execution()
    print("Coverage parser, floor, and required-source tests passed")
