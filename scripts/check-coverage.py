#!/usr/bin/env python3
"""Parse and verify Go and Flutter coverage artifacts against regression floors."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def parse_lcov(content: str) -> tuple[int, int, float]:
    """Parse an LCOV format string and return (lines_hit, lines_found, percentage)."""
    lines_found = 0
    lines_hit = 0
    records = 0
    current_lf = 0
    current_lh = 0
    has_lf = False
    has_lh = False

    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("LF:"):
            try:
                current_lf = int(line[3:])
                has_lf = True
            except ValueError:
                raise ValueError(f"malformed LCOV LF line: {line}")
        elif line.startswith("LH:"):
            try:
                current_lh = int(line[3:])
                has_lh = True
            except ValueError:
                raise ValueError(f"malformed LCOV LH line: {line}")
        elif line == "end_of_record":
            if has_lf and has_lh:
                lines_found += current_lf
                lines_hit += current_lh
                records += 1
            current_lf = 0
            current_lh = 0
            has_lf = False
            has_lh = False

    if records == 0 and not lines_found:
        raise ValueError("no valid LCOV records found in file")
    if lines_found <= 0:
        raise ValueError(f"invalid total lines found in LCOV: {lines_found}")

    pct = (lines_hit / lines_found) * 100.0
    return lines_hit, lines_found, pct


def parse_go_coverprofile(content: str) -> tuple[int, int, float]:
    """Parse a Go coverprofile format string (coverage.out) and return (stmts_hit, total_stmts, percentage)."""
    lines = content.strip().splitlines()
    if not lines:
        raise ValueError("empty Go coverprofile")
    if not lines[0].startswith("mode:"):
        raise ValueError("missing mode header in Go coverprofile")

    total_stmts = 0
    stmts_hit = 0
    valid_blocks = 0

    for line in lines[1:]:
        line = line.strip()
        if not line:
            continue
        parts = line.rsplit(maxsplit=2)
        if len(parts) != 3:
            raise ValueError(f"malformed Go cover line: {line}")
        try:
            num_stmts = int(parts[1])
            count = int(parts[2])
        except ValueError:
            raise ValueError(f"non-integer statement/count in line: {line}")

        if num_stmts < 0 or count < 0:
            raise ValueError(f"negative statement count in line: {line}")

        total_stmts += num_stmts
        if count > 0:
            stmts_hit += num_stmts
        valid_blocks += 1

    if valid_blocks == 0 or total_stmts <= 0:
        raise ValueError("no valid coverage blocks found in Go coverprofile")

    pct = (stmts_hit / total_stmts) * 100.0
    return stmts_hit, total_stmts, pct


def check_floor(name: str, actual_pct: float, floor_pct: float) -> bool:
    if actual_pct < floor_pct:
        print(
            f"FAIL: {name} coverage {actual_pct:.2f}% is below required floor {floor_pct:.2f}%",
            file=sys.stderr,
        )
        return False
    print(f"PASS: {name} coverage {actual_pct:.2f}% >= floor {floor_pct:.2f}%")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify coverage against regression floors.")
    parser.add_argument("--go-profile", type=Path, help="Path to Go coverage.out file")
    parser.add_argument("--go-floor", type=float, default=0.0, help="Minimum required Go coverage percentage")
    parser.add_argument("--flutter-lcov", type=Path, help="Path to Flutter lcov.info file")
    parser.add_argument("--flutter-floor", type=float, default=0.0, help="Minimum required Flutter coverage percentage")

    args = parser.parse_args()
    success = True

    if args.go_profile:
        try:
            content = args.go_profile.read_text(encoding="utf-8")
            _, _, pct = parse_go_coverprofile(content)
            if not check_floor("Go", pct, args.go_floor):
                success = False
        except (OSError, ValueError) as exc:
            print(f"FAIL: Go coverage check error: {exc}", file=sys.stderr)
            success = False

    if args.flutter_lcov:
        try:
            content = args.flutter_lcov.read_text(encoding="utf-8")
            _, _, pct = parse_lcov(content)
            if not check_floor("Flutter", pct, args.flutter_floor):
                success = False
        except (OSError, ValueError) as exc:
            print(f"FAIL: Flutter coverage check error: {exc}", file=sys.stderr)
            success = False

    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
