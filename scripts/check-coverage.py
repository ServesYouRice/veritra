#!/usr/bin/env python3
"""Parse and verify Go and Flutter coverage artifacts against regression floors."""

from __future__ import annotations

import argparse
import math
import re
import sys
from pathlib import Path


def normalize_source(source: str) -> str:
    return source.strip().replace("\\", "/").removeprefix("./")


def source_matches(actual: str, required: str) -> bool:
    actual = normalize_source(actual)
    required = normalize_source(required)
    return bool(required) and (actual == required or actual.endswith(f"/{required}"))


def missing_required_sources(sources: set[str], required: list[str]) -> list[str]:
    return [item for item in required if not any(source_matches(source, item) for source in sources)]


def parse_lcov_report(content: str) -> tuple[int, int, float, set[str]]:
    """Parse LCOV totals and source records."""
    lines_found = 0
    lines_hit = 0
    records = 0
    sources: set[str] = set()
    current_source: str | None = None
    current_lf = 0
    current_lh = 0
    has_lf = False
    has_lh = False

    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("SF:"):
            if current_source is not None:
                raise ValueError("LCOV source record is missing end_of_record")
            current_source = normalize_source(line[3:])
            if not current_source:
                raise ValueError("empty LCOV source path")
        elif line.startswith("LF:"):
            if current_source is None or has_lf:
                raise ValueError(f"misplaced or duplicate LCOV LF line: {line}")
            try:
                current_lf = int(line[3:])
                has_lf = True
            except ValueError:
                raise ValueError(f"malformed LCOV LF line: {line}")
        elif line.startswith("LH:"):
            if current_source is None or has_lh:
                raise ValueError(f"misplaced or duplicate LCOV LH line: {line}")
            try:
                current_lh = int(line[3:])
                has_lh = True
            except ValueError:
                raise ValueError(f"malformed LCOV LH line: {line}")
        elif line == "end_of_record":
            if current_source is None or not has_lf or not has_lh:
                raise ValueError("incomplete LCOV source record")
            if current_lf < 0 or current_lh < 0 or current_lh > current_lf:
                raise ValueError(
                    f"invalid LCOV totals for {current_source}: LF={current_lf}, LH={current_lh}"
                )
            lines_found += current_lf
            lines_hit += current_lh
            sources.add(current_source)
            records += 1
            current_source = None
            current_lf = 0
            current_lh = 0
            has_lf = False
            has_lh = False

    if current_source is not None or has_lf or has_lh:
        raise ValueError("LCOV source record is missing end_of_record")
    if records == 0 and not lines_found:
        raise ValueError("no valid LCOV records found in file")
    if lines_found <= 0:
        raise ValueError(f"invalid total lines found in LCOV: {lines_found}")

    pct = (lines_hit / lines_found) * 100.0
    return lines_hit, lines_found, pct, sources


def parse_lcov(content: str) -> tuple[int, int, float]:
    """Parse an LCOV format string and return (lines_hit, lines_found, percentage)."""
    lines_hit, lines_found, pct, _ = parse_lcov_report(content)
    return lines_hit, lines_found, pct


def parse_go_report(content: str) -> tuple[int, int, float, set[str]]:
    """Parse Go coverprofile totals and source records."""
    lines = content.strip().splitlines()
    if not lines:
        raise ValueError("empty Go coverprofile")
    if lines[0] not in {"mode: set", "mode: count", "mode: atomic"}:
        raise ValueError(f"invalid mode header in Go coverprofile: {lines[0]}")

    total_stmts = 0
    stmts_hit = 0
    valid_blocks = 0
    sources: set[str] = set()

    for line in lines[1:]:
        line = line.strip()
        if not line:
            continue
        parts = line.rsplit(maxsplit=2)
        if len(parts) != 3:
            raise ValueError(f"malformed Go cover line: {line}")
        location = parts[0]
        if ":" not in location:
            raise ValueError(f"missing source location in Go cover line: {line}")
        source, positions = location.rsplit(":", 1)
        if not source or not re.fullmatch(r"\d+\.\d+,\d+\.\d+", positions):
            raise ValueError(f"invalid source location in Go cover line: {line}")
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
        sources.add(normalize_source(source))
        valid_blocks += 1

    if valid_blocks == 0 or total_stmts <= 0:
        raise ValueError("no valid coverage blocks found in Go coverprofile")

    pct = (stmts_hit / total_stmts) * 100.0
    return stmts_hit, total_stmts, pct, sources


def parse_go_coverprofile(content: str) -> tuple[int, int, float]:
    """Parse a Go coverprofile and return (stmts_hit, total_stmts, percentage)."""
    stmts_hit, total_stmts, pct, _ = parse_go_report(content)
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


def percentage(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid percentage: {value}") from exc
    if not math.isfinite(parsed) or parsed < 0.0 or parsed > 100.0:
        raise argparse.ArgumentTypeError(f"percentage must be finite and between 0 and 100: {value}")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify coverage against regression floors.")
    parser.add_argument("--go-profile", type=Path, help="Path to Go coverage.out file")
    parser.add_argument("--go-floor", type=percentage, help="Minimum required Go coverage percentage")
    parser.add_argument("--go-required-source", action="append", default=[], help="Required Go source path")
    parser.add_argument("--flutter-lcov", type=Path, help="Path to Flutter lcov.info file")
    parser.add_argument("--flutter-floor", type=percentage, help="Minimum required Flutter coverage percentage")
    parser.add_argument(
        "--flutter-required-source", action="append", default=[], help="Required Flutter source path"
    )

    args = parser.parse_args()
    configuration_errors: list[str] = []
    if not args.go_profile and not args.flutter_lcov:
        configuration_errors.append("at least one coverage artifact is required")
    if args.go_profile and args.go_floor is None:
        configuration_errors.append("--go-profile requires an explicit --go-floor")
    if not args.go_profile and (args.go_floor is not None or args.go_required_source):
        configuration_errors.append("Go floor/source requirements need --go-profile")
    if args.flutter_lcov and args.flutter_floor is None:
        configuration_errors.append("--flutter-lcov requires an explicit --flutter-floor")
    if not args.flutter_lcov and (args.flutter_floor is not None or args.flutter_required_source):
        configuration_errors.append("Flutter floor/source requirements need --flutter-lcov")
    if configuration_errors:
        for error in configuration_errors:
            print(f"FAIL: coverage configuration error: {error}", file=sys.stderr)
        return 1

    success = True

    if args.go_profile:
        try:
            content = args.go_profile.read_text(encoding="utf-8")
            _, _, pct, sources = parse_go_report(content)
            if not check_floor("Go", pct, args.go_floor):
                success = False
            missing = missing_required_sources(sources, args.go_required_source)
            if missing:
                print(f"FAIL: Go coverage is missing required sources: {', '.join(missing)}", file=sys.stderr)
                success = False
        except (OSError, ValueError) as exc:
            print(f"FAIL: Go coverage check error: {exc}", file=sys.stderr)
            success = False

    if args.flutter_lcov:
        try:
            content = args.flutter_lcov.read_text(encoding="utf-8")
            _, _, pct, sources = parse_lcov_report(content)
            if not check_floor("Flutter", pct, args.flutter_floor):
                success = False
            missing = missing_required_sources(sources, args.flutter_required_source)
            if missing:
                print(f"FAIL: Flutter coverage is missing required sources: {', '.join(missing)}", file=sys.stderr)
                success = False
        except (OSError, ValueError) as exc:
            print(f"FAIL: Flutter coverage check error: {exc}", file=sys.stderr)
            success = False

    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
