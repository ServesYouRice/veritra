#!/usr/bin/env python3
"""Validate Veritra's time-bounded Rust advisory exception policy."""

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

ADVISORY_ID = re.compile(r"^RUSTSEC-[0-9]{4}-[0-9]{4}$")
UTC_TIMESTAMP = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?Z$"
)
APPROVED_REVIEW_DEADLINE = "2026-08-29T00:00:00Z"
APPROVED_CARGO_AUDIT_VERSION = "0.22.2"
APPROVED_EXCEPTION_IDS = frozenset(
    {
        "RUSTSEC-2026-0209",
        "RUSTSEC-2026-0211",
        "RUSTSEC-2026-0124",
        "RUSTSEC-2026-0212",
        "RUSTSEC-2026-0207",
        "RUSTSEC-2026-0208",
    }
)
POLICY_FIELDS = {
    "version",
    "timezone",
    "cargo_audit_version",
    "review_deadline",
    "exceptions",
}
EXCEPTION_FIELDS = {"id", "scope", "rationale"}


class PolicyError(Exception):
    """The policy or its evaluation input is invalid."""


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_timestamp(value: object) -> datetime:
    if not isinstance(value, str) or not UTC_TIMESTAMP.fullmatch(value):
        raise PolicyError("timestamps must be RFC3339 values with a UTC Z suffix")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise PolicyError(f"invalid timestamp: {value!r}") from error
    if parsed.tzinfo is None or parsed.utcoffset() != timedelta(0):
        raise PolicyError("timestamps must use UTC")
    return parsed.astimezone(timezone.utc)


def load_policy(path: Path) -> dict:
    try:
        with path.open(encoding="utf-8") as stream:
            policy = json.load(stream, object_pairs_hook=reject_duplicate_keys)
    except (OSError, ValueError) as error:
        raise PolicyError(f"cannot read policy {path}: {error}") from error
    if not isinstance(policy, dict) or policy.get("version") != 1:
        raise PolicyError("policy version 1 is required")
    if set(policy) != POLICY_FIELDS:
        raise PolicyError("policy contains unexpected or missing fields")
    if policy.get("timezone") != "UTC":
        raise PolicyError("policy timezone must be UTC")
    if policy.get("cargo_audit_version") != APPROVED_CARGO_AUDIT_VERSION:
        raise PolicyError("policy cargo-audit version is not pinned to the approved tool")
    if policy.get("review_deadline") != APPROVED_REVIEW_DEADLINE:
        raise PolicyError("policy deadline does not match the approved UTC boundary")
    deadline = parse_timestamp(policy.get("review_deadline"))
    exceptions = policy.get("exceptions")
    if not isinstance(exceptions, list) or not exceptions:
        raise PolicyError("policy must contain at least one exception")
    seen = set()
    for exception in exceptions:
        if not isinstance(exception, dict):
            raise PolicyError("each exception must be an object")
        if set(exception) != EXCEPTION_FIELDS:
            raise PolicyError("exception contains unexpected or missing fields")
        advisory = exception.get("id")
        if not isinstance(advisory, str) or not ADVISORY_ID.fullmatch(advisory):
            raise PolicyError(f"invalid advisory id: {advisory!r}")
        if advisory in seen:
            raise PolicyError(f"duplicate advisory id: {advisory}")
        seen.add(advisory)
        for field in ("scope", "rationale"):
            if not isinstance(exception.get(field), str) or not exception[field].strip():
                raise PolicyError(f"exception {advisory} needs a non-empty {field}")
    if seen != APPROVED_EXCEPTION_IDS:
        raise PolicyError("policy advisory IDs do not match the approved exception set")
    return {
        "deadline": deadline,
        "exceptions": exceptions,
        "cargo_audit_version": policy["cargo_audit_version"],
    }


def evaluation_time(raw: Optional[str]) -> datetime:
    value = raw
    if value is None:
        return datetime.now(timezone.utc)
    return parse_timestamp(value)


def validate_deadline(policy: dict, now: datetime) -> None:
    if now >= policy["deadline"]:
        deadline = policy["deadline"].isoformat().replace("+00:00", "Z")
        raise PolicyError(f"Rust advisory exception policy expired at {deadline}")


def cargo_audit_flags(policy: dict) -> str:
    return " ".join(
        f"--ignore {exception['id']}" for exception in policy["exceptions"]
    )


def cargo_audit_version(policy: dict) -> str:
    return policy["cargo_audit_version"]


def self_test(policy: dict) -> None:
    deadline = policy["deadline"]
    validate_deadline(policy, deadline - timedelta(microseconds=1))
    try:
        validate_deadline(policy, deadline)
    except PolicyError:
        pass
    else:
        raise PolicyError("self-test did not reject the exact expiry boundary")
    try:
        validate_deadline(policy, deadline + timedelta(microseconds=1))
    except PolicyError:
        pass
    else:
        raise PolicyError("self-test did not reject an expired policy")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("policy", type=Path)
    parser.add_argument("--now", help="override the UTC evaluation time")
    parser.add_argument("--print-ignores", action="store_true")
    parser.add_argument("--print-cargo-audit-version", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    try:
        policy = load_policy(args.policy)
        if args.self_test:
            self_test(policy)
        validate_deadline(policy, evaluation_time(args.now))
        if args.print_ignores:
            print(cargo_audit_flags(policy))
        elif args.print_cargo_audit_version:
            print(cargo_audit_version(policy))
        else:
            print("Rust advisory exception policy is valid")
        return 0
    except PolicyError as error:
        print(f"Rust advisory exception policy failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
