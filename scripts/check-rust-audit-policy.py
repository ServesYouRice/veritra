#!/usr/bin/env python3
"""Validate Veritra's time-bounded Rust advisory exception policy."""

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

ADVISORY_ID = re.compile(r"^RUSTSEC-[0-9]{4}-[0-9]{4}$")
UTC_TIMESTAMP = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?Z$"
)
APPROVED_REVIEW_DEADLINE = "2026-12-31T00:00:00Z"
APPROVED_CARGO_AUDIT_VERSION = "0.22.2"
# Owner-approved on 2026-10-22 (G27 reopened): libcrux-kem 0.0.9 is locked
# only because hpke-rs 0.7's `std` feature names the optional
# hpke-rs-libcrux backend; it is never built (audit-rust.sh fails if it
# enters the build graph). The fix needs hpke-rs 0.8, which no released
# openmls_rust_crypto accepts yet. Remove both IDs when one does.
# Owner-approved on 2026-10-24: RUSTSEC-2026-0387 (crypto-bigint 0.5.5) is in
# the NIST-curve arithmetic that elliptic-curve 0.13 brings in; Veritra pins an
# X25519/Ed25519 suite, so it never runs on our keys. Remove it when the
# OpenMLS stack moves to elliptic-curve 0.14.
APPROVED_EXCEPTION_IDS: frozenset = frozenset(
    {"RUSTSEC-2026-0330", "RUSTSEC-2026-0331", "RUSTSEC-2026-0387"}
)
# An exception's scope is machine-checked against the audited Cargo.lock:
# the crate, the only locked versions it may have, the only crates allowed
# to depend on it, and whether it may be built or is only locked.
SCOPE_FIELDS = {"crate", "versions", "parents", "built"}
CRATE_NAME = re.compile(r"^[A-Za-z0-9_-]+$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
COMPARATOR = re.compile(r"^(>=|<=|=|>|<)?\s*([0-9]+\.[0-9]+\.[0-9]+)$")
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


def version_tuple(version: str) -> tuple:
    if not VERSION.fullmatch(version):
        raise PolicyError(f"unsupported version {version!r}: only plain MAJOR.MINOR.PATCH is accepted")
    return tuple(int(part) for part in version.split("."))


def parse_versions(advisory: str, versions: object) -> list:
    """Comparators such as '=0.5.5' or '>=0.5.5, <0.6.0'; a bare version means '='."""
    if not isinstance(versions, str) or not versions.strip():
        raise PolicyError(f"exception {advisory} scope versions must be a non-empty string")
    comparators = []
    for part in versions.split(","):
        match = COMPARATOR.fullmatch(part.strip())
        if not match:
            raise PolicyError(f"exception {advisory} scope versions {versions!r} is not a version range")
        comparators.append((match.group(1) or "=", version_tuple(match.group(2))))
    return comparators


def version_in_range(version: str, comparators: list) -> bool:
    try:
        have = version_tuple(version)
    except PolicyError:
        return False  # a pre-release or odd version is never inside a declared range
    checks = {
        "=": lambda a, b: a == b,
        ">=": lambda a, b: a >= b,
        ">": lambda a, b: a > b,
        "<=": lambda a, b: a <= b,
        "<": lambda a, b: a < b,
    }
    return all(checks[op](have, bound) for op, bound in comparators)


def validate_scope(advisory: str, scope: object) -> None:
    if not isinstance(scope, dict) or set(scope) != SCOPE_FIELDS:
        raise PolicyError(
            f"exception {advisory} scope must be an object with exactly {sorted(SCOPE_FIELDS)}"
        )
    if not isinstance(scope["crate"], str) or not CRATE_NAME.fullmatch(scope["crate"]):
        raise PolicyError(f"exception {advisory} scope crate is not a crate name")
    parse_versions(advisory, scope["versions"])
    parents = scope["parents"]
    if (
        not isinstance(parents, list)
        or not parents
        or len(set(map(str, parents))) != len(parents)
        or not all(isinstance(name, str) and CRATE_NAME.fullmatch(name) for name in parents)
    ):
        raise PolicyError(f"exception {advisory} scope parents must be a non-empty list of unique crate names")
    if not isinstance(scope["built"], bool):
        raise PolicyError(f"exception {advisory} scope built must be true or false")


def parse_lockfile(path: Path) -> list:
    try:
        import tomllib
    except ImportError as error:  # Python < 3.11: no TOML parser, so fail closed
        raise PolicyError("the scope check needs Python 3.11 or newer (tomllib)") from error
    try:
        with path.open("rb") as stream:
            lock = tomllib.load(stream)
    except (OSError, ValueError) as error:
        raise PolicyError(f"cannot read lockfile {path}: {error}") from error
    packages = lock.get("package")
    if not isinstance(packages, list) or not packages:
        raise PolicyError(f"lockfile {path} has no packages")
    for package in packages:
        if not isinstance(package, dict) or not isinstance(package.get("name"), str) \
                or not isinstance(package.get("version"), str):
            raise PolicyError(f"lockfile {path} has a malformed package entry")
    return packages


def resolve_dependency(packages: list, entry: object, owner: str) -> dict:
    """The one locked package a dependency entry names ('name', 'name version' or
    'name version (source)'); no match or several matches fail closed."""
    if not isinstance(entry, str) or not entry.strip():
        raise PolicyError(f"lockfile package {owner} has a malformed dependency entry")
    parts = entry.split(" ", 2)
    name = parts[0]
    version = parts[1] if len(parts) > 1 else None
    source = parts[2] if len(parts) > 2 else None
    if source is not None and not (source.startswith("(") and source.endswith(")")):
        raise PolicyError(f"lockfile package {owner} has a malformed dependency entry {entry!r}")
    matches = [
        package for package in packages
        if package["name"] == name
        and (version is None or package["version"] == version)
        and (source is None or package.get("source") == source[1:-1])
    ]
    if len(matches) != 1:
        raise PolicyError(
            f"lockfile package {owner} dependency {entry!r} matches {len(matches)} locked packages"
        )
    return matches[0]


def check_scopes(policy: dict, lockfile: Path) -> list:
    """Check every exception's scope against the whole lockfile cargo audit reads.

    Cargo.lock has an edge for every dependency of every kind, target and
    feature (dev, build, cfg-gated, optional but never activated), and
    ``cargo audit --ignore`` suppresses an advisory for all of them. So every
    locked version of the crate must be in the declared range, and every
    package that depends on it, whatever the kind, must be a declared parent.
    Returns the (crate, version, built) of each scoped package.
    """
    packages = parse_lockfile(lockfile)
    dependents: dict = {}
    for package in packages:
        for entry in package.get("dependencies", []):
            target = resolve_dependency(packages, entry, f"{package['name']} {package['version']}")
            dependents.setdefault((target["name"], target["version"], target.get("source")), []).append(
                package["name"]
            )
    scoped = []
    for exception in policy["exceptions"]:
        advisory, scope = exception["id"], exception["scope"]
        comparators = parse_versions(advisory, scope["versions"])
        locked = [package for package in packages if package["name"] == scope["crate"]]
        if not locked:
            raise PolicyError(
                f"exception {advisory} names {scope['crate']}, which is not in {lockfile}; remove the exception"
            )
        for package in locked:
            where = f"{scope['crate']} {package['version']}"
            if not version_in_range(package["version"], comparators):
                raise PolicyError(
                    f"{advisory}: locked {where} is outside the excepted versions {scope['versions']!r}"
                )
            parents = dependents.get((package["name"], package["version"], package.get("source")), [])
            outside = sorted(set(parents) - set(scope["parents"]))
            if outside:
                raise PolicyError(
                    f"{advisory}: {where} is reached through {', '.join(outside)}, "
                    f"outside the allowed parents {', '.join(scope['parents'])}"
                )
            scoped.append((scope["crate"], package["version"], scope["built"]))
    return scoped


def cargo_tree_runner(crate_dir: Path, spec: str) -> tuple:
    result = subprocess.run(
        ["cargo", "tree", "--locked", "--target", "all", "-e", "all", "-i", spec],
        cwd=crate_dir, capture_output=True, text=True, check=False,
    )
    return result.returncode, result.stdout, result.stderr


def check_unbuilt(scoped: list, crate_dir: Path, runner=cargo_tree_runner) -> None:
    """Cross-check each lockfile-only scope: the crate must not be in the build graph.

    A locked package outside the resolved graph prints nothing: cargo (1.9x)
    exits 0 with the warning "nothing to print", older versions exit non-zero
    with "did not match any packages". Printed tree lines mean it is built;
    any other outcome is an error.
    The lockfile check stays authoritative.
    """
    for crate, version, built in dict.fromkeys(scoped):
        if built:
            continue
        spec = f"{crate}@{version}"
        code, out, err = runner(crate_dir, spec)
        if code == 0 and out.strip():
            raise PolicyError(f"{spec} is excepted as lockfile-only but entered the build graph")
        absent = (code == 0 and "nothing to print" in err) or (
            code != 0 and "did not match any packages" in err
        )
        if not absent:
            raise PolicyError(f"cargo tree could not check {spec}: {err.strip() or 'exit ' + str(code)}")


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
    if not isinstance(exceptions, list):
        raise PolicyError("policy exceptions must be a list")
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
        if not isinstance(exception.get("rationale"), str) or not exception["rationale"].strip():
            raise PolicyError(f"exception {advisory} needs a non-empty rationale")
        validate_scope(advisory, exception.get("scope"))
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


def check_deadline(deadline: datetime, now: datetime) -> None:
    if now >= deadline:
        text = deadline.isoformat().replace("+00:00", "Z")
        raise PolicyError(f"Rust advisory exception policy expired at {text}")


def validate_deadline(policy: dict, now: datetime) -> None:
    # The deadline bounds exceptions. With none, there is nothing to expire.
    if policy["exceptions"]:
        check_deadline(policy["deadline"], now)


def cargo_audit_flags(policy: dict) -> str:
    return " ".join(
        f"--ignore {exception['id']}" for exception in policy["exceptions"]
    )


def cargo_audit_version(policy: dict) -> str:
    return policy["cargo_audit_version"]


def self_test(policy: dict) -> None:
    deadline = policy["deadline"]
    check_deadline(deadline, deadline - timedelta(microseconds=1))
    try:
        check_deadline(deadline, deadline)
    except PolicyError:
        pass
    else:
        raise PolicyError("self-test did not reject the exact expiry boundary")
    try:
        check_deadline(deadline, deadline + timedelta(microseconds=1))
    except PolicyError:
        pass
    else:
        raise PolicyError("self-test did not reject an expired policy")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("policy", type=Path)
    parser.add_argument("--now", help="override the UTC evaluation time")
    parser.add_argument(
        "--lockfile", type=Path,
        help="check every exception's scope against this Cargo.lock (the file cargo audit is given)",
    )
    parser.add_argument(
        "--cargo-tree-dir", type=Path,
        help="with --lockfile: also run cargo tree here for lockfile-only scopes",
    )
    parser.add_argument("--print-ignores", action="store_true")
    parser.add_argument("--print-cargo-audit-version", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    try:
        policy = load_policy(args.policy)
        if args.self_test:
            self_test(policy)
        validate_deadline(policy, evaluation_time(args.now))
        if args.cargo_tree_dir and not args.lockfile:
            raise PolicyError("--cargo-tree-dir needs --lockfile")
        if args.lockfile:
            scoped = check_scopes(policy, args.lockfile)
            if args.cargo_tree_dir:
                check_unbuilt(scoped, args.cargo_tree_dir)
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
