#!/usr/bin/env python3
"""Tests for the cargo-audit exception scope check in check-rust-audit-policy.py.

Canned Cargo.lock files and canned `cargo tree` results, so no case needs
cargo, the network or an advisory database. The last cases run the real
policy against the real crypto/rust/Cargo.lock.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
spec = importlib.util.spec_from_file_location("audit_policy", SCRIPTS / "check-rust-audit-policy.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"
NOW = "2026-11-07T00:00:00Z"


def lockfile(*packages: tuple) -> str:
    """(name, version, [dependency entries]) -> Cargo.lock text; a path package has no source."""
    out = ["version = 4", ""]
    for name, version, deps in packages:
        out += ["[[package]]", f'name = "{name}"', f'version = "{version}"']
        if not name.startswith("app"):
            out += [f'source = "{REGISTRY}"', 'checksum = "00"']
        if deps:
            out += ["dependencies = ["] + [f' "{dep}",' for dep in deps] + ["]"]
        out.append("")
    return "\n".join(out)


# The current graph's declared paths: hpke-rs 0.7 names the optional
# hpke-rs-libcrux backend, which pins libcrux-kem; elliptic-curve brings in
# crypto-bigint.
GOOD = (
    ("app", "0.1.0", ["hpke-rs", "elliptic-curve"]),
    ("hpke-rs", "0.7.0", ["hpke-rs-libcrux"]),
    ("hpke-rs-libcrux", "0.7.0", ["libcrux-kem"]),
    ("libcrux-kem", "0.0.9", []),
    ("elliptic-curve", "0.13.8", ["crypto-bigint"]),
    ("crypto-bigint", "0.5.5", []),
)


def scope(crate: str, versions: str, parents: list, built: bool) -> dict:
    return {"crate": crate, "versions": versions, "parents": parents, "built": built}


SCOPES = {
    "RUSTSEC-2026-0330": scope("libcrux-kem", "=0.0.9", ["hpke-rs-libcrux"], False),
    "RUSTSEC-2026-0331": scope("libcrux-kem", "=0.0.9", ["hpke-rs-libcrux"], False),
    "RUSTSEC-2026-0387": scope("crypto-bigint", "=0.5.5", ["elliptic-curve"], True),
}


def policy_with(scopes: dict | None = None) -> dict:
    return {
        "deadline": audit.parse_timestamp(audit.APPROVED_REVIEW_DEADLINE),
        "cargo_audit_version": audit.APPROVED_CARGO_AUDIT_VERSION,
        "exceptions": [{"id": key, "scope": value, "rationale": "x"} for key, value in (scopes or SCOPES).items()],
    }


def check(packages: tuple, scopes: dict | None = None) -> list:
    with tempfile.TemporaryDirectory(prefix="veritra-audit-scope-") as temp:
        path = Path(temp) / "Cargo.lock"
        path.write_text(lockfile(*packages), encoding="utf-8")
        return audit.check_scopes(policy_with(scopes), path)


def blocked(packages: tuple, message: str, scopes: dict | None = None) -> None:
    try:
        check(packages, scopes)
    except audit.PolicyError as error:
        assert message in str(error), f"expected {message!r}, got {error}"
        return
    raise AssertionError(f"expected the scope check to fail with {message!r}")


def with_extra(*extra: tuple, drop: tuple = ()) -> tuple:
    """GOOD plus extra packages; ``drop`` names packages to replace."""
    return tuple(package for package in GOOD if package[0] not in drop) + extra


def policy_file(policy: dict) -> Path:
    path = Path(tempfile.mkdtemp(prefix="veritra-audit-policy-")) / "audit-policy.json"
    path.write_text(json.dumps(policy), encoding="utf-8")
    return path


def real_policy() -> dict:
    return json.loads((ROOT / "crypto/rust/audit-policy.json").read_text(encoding="utf-8"))


def policy_rejects(policy: dict, message: str) -> None:
    path = policy_file(policy)
    try:
        audit.load_policy(path)
    except audit.PolicyError as error:
        assert message in str(error), f"expected {message!r}, got {error}"
        return
    raise AssertionError(f"expected load_policy to fail with {message!r}")


def main() -> int:
    # In scope: the current graph's declared paths.
    assert check(GOOD) == [
        ("libcrux-kem", "0.0.9", False), ("libcrux-kem", "0.0.9", False), ("crypto-bigint", "0.5.5", True)
    ]

    # Out of scope: a second, unlisted dependent. A Cargo.lock edge carries no
    # kind, target or feature, so the same lockfile shape covers a normal,
    # dev-only, build-only, target-specific (cfg) and optional-but-never-
    # activated dependent; each is a package that lists the crate.
    for label, parent in (
        ("normal", "some-lib"), ("dev-only", "some-dev-tool"), ("build-only", "some-build-helper"),
        ("target-specific", "some-windows-glue"), ("lockfile-only optional", "some-optional-backend"),
    ):
        blocked(
            with_extra((parent, "1.0.0", ["crypto-bigint"])),
            f"crypto-bigint 0.5.5 is reached through {parent}",
        )
        blocked(
            with_extra((parent, "1.0.0", ["libcrux-kem"])),
            f"libcrux-kem 0.0.9 is reached through {parent}",
        )
    # The workspace root itself is a dependent too.
    blocked(
        tuple(("app", "0.1.0", ["hpke-rs", "elliptic-curve", "crypto-bigint"]) if p[0] == "app" else p for p in GOOD),
        "crypto-bigint 0.5.5 is reached through app",
    )

    # A second locked version of the excepted crate, with or without its own
    # parent, is outside the excepted versions.
    blocked(
        with_extra(("crypto-bigint", "0.6.1", []), ("other", "1.0.0", ["crypto-bigint 0.6.1"]), ("elliptic-curve", "0.13.8", ["crypto-bigint 0.5.5"]), drop=("elliptic-curve",)),
        "locked crypto-bigint 0.6.1 is outside the excepted versions '=0.5.5'",
    )
    blocked(
        with_extra(("libcrux-kem", "0.1.0", []), ("hpke-rs-libcrux", "0.7.0", ["libcrux-kem 0.0.9"]), drop=("hpke-rs-libcrux",)),
        "locked libcrux-kem 0.1.0 is outside the excepted versions '=0.0.9'",
    )
    # An advisory-crate version that is a pre-release is never in range.
    blocked(with_extra(("crypto-bigint", "0.5.6-rc.1", []), ("elliptic-curve", "0.13.8", ["crypto-bigint 0.5.5"]),
                       drop=("elliptic-curve",)), "outside the excepted versions")

    # Two locked versions: dependency entries must say which one they mean.
    two = with_extra(("crypto-bigint", "0.4.9", []), ("old-curve", "0.9.0", ["crypto-bigint"]))
    blocked(two, "dependency 'crypto-bigint' matches 2 locked packages")
    # 'name version' and 'name version (source)' resolve to exactly one package.
    both = (
        ("app", "0.1.0", ["hpke-rs", "elliptic-curve"]),
        ("hpke-rs", "0.7.0", ["hpke-rs-libcrux"]),
        ("hpke-rs-libcrux", "0.7.0", ["libcrux-kem"]),
        ("libcrux-kem", "0.0.9", []),
        ("elliptic-curve", "0.13.8", ["crypto-bigint 0.5.5 (" + REGISTRY + ")"]),
        ("crypto-bigint", "0.5.5", []),
        ("old-curve", "0.9.0", ["crypto-bigint 0.4.9"]),
        ("crypto-bigint", "0.4.9", []),
    )
    wide = dict(SCOPES, **{"RUSTSEC-2026-0387": scope("crypto-bigint", ">=0.4.0, <0.6.0", ["elliptic-curve", "old-curve"], True)})
    assert ("crypto-bigint", "0.4.9", True) in check(both, wide)
    # ... and the source-qualified entry resolves to the right version: the
    # 0.4.9 package is reached only through old-curve, which a narrower
    # parent list does not allow.
    narrow = dict(SCOPES, **{"RUSTSEC-2026-0387": scope("crypto-bigint", ">=0.4.0, <0.6.0", ["elliptic-curve"], True)})
    blocked(both, "crypto-bigint 0.4.9 is reached through old-curve", narrow)
    # An entry that names nothing, or a malformed source, fails closed.
    blocked(with_extra(("elliptic-curve", "0.13.8", ["crypto-bigint 9.9.9"]), drop=("elliptic-curve",)),
            "matches 0 locked packages")
    blocked(with_extra(("elliptic-curve", "0.13.8", ["crypto-bigint 0.5.5 " + REGISTRY]), drop=("elliptic-curve",)),
            "malformed dependency entry")
    blocked(with_extra(("elliptic-curve", "0.13.8", ["crypto-bigint 0.5.5 (registry+https://other.example/index)"]),
                       drop=("elliptic-curve",)), "matches 0 locked packages")

    # A stale exception (the crate left the lockfile) is not silently kept.
    blocked(with_extra(("app", "0.1.0", ["hpke-rs"]), drop=("app", "elliptic-curve", "crypto-bigint")),
            "crypto-bigint, which is not in")

    # Missing or malformed scope.
    for bad in (
        "libcrux-kem 0.0.9 via hpke-rs-libcrux 0.7.0 (lockfile only)",  # the old free-text form
        None,
        {},
        {"crate": "libcrux-kem", "versions": "=0.0.9", "parents": ["hpke-rs-libcrux"]},  # no built
        dict(SCOPES["RUSTSEC-2026-0330"], extra=1),
        dict(SCOPES["RUSTSEC-2026-0330"], crate=""),
        dict(SCOPES["RUSTSEC-2026-0330"], crate="bad name"),
        dict(SCOPES["RUSTSEC-2026-0330"], versions=""),
        dict(SCOPES["RUSTSEC-2026-0330"], versions="*"),
        dict(SCOPES["RUSTSEC-2026-0330"], versions="^0.0.9"),
        dict(SCOPES["RUSTSEC-2026-0330"], versions=">=0.0"),
        dict(SCOPES["RUSTSEC-2026-0330"], versions=9),
        dict(SCOPES["RUSTSEC-2026-0330"], parents=[]),
        dict(SCOPES["RUSTSEC-2026-0330"], parents="hpke-rs-libcrux"),
        dict(SCOPES["RUSTSEC-2026-0330"], parents=["a", "a"]),
        dict(SCOPES["RUSTSEC-2026-0330"], parents=[7]),
        dict(SCOPES["RUSTSEC-2026-0330"], built="no"),
    ):
        policy = real_policy()
        policy["exceptions"][0]["scope"] = bad
        policy_rejects(policy, "scope")
    policy = real_policy()
    policy["exceptions"][0].pop("scope")
    policy_rejects(policy, "unexpected or missing fields")

    # Unreadable or malformed lockfiles fail closed.
    with tempfile.TemporaryDirectory(prefix="veritra-audit-scope-") as temp:
        for text in ("not toml [", "version = 4\n", '[[package]]\nname = "x"\n'):
            path = Path(temp) / "Cargo.lock"
            path.write_text(text, encoding="utf-8")
            try:
                audit.check_scopes(policy_with(), path)
            except audit.PolicyError:
                pass
            else:
                raise AssertionError(f"expected a malformed lockfile to fail: {text!r}")
        try:
            audit.check_scopes(policy_with(), Path(temp) / "missing.lock")
        except audit.PolicyError as error:
            assert "cannot read lockfile" in str(error)
        else:
            raise AssertionError("expected a missing lockfile to fail")

    # Version ranges.
    ranges = audit.parse_versions("x", ">=0.5.5, <0.6.0")
    assert audit.version_in_range("0.5.5", ranges) and audit.version_in_range("0.5.99", ranges)
    assert not audit.version_in_range("0.5.4", ranges) and not audit.version_in_range("0.6.0", ranges)
    assert audit.version_in_range("0.0.9", audit.parse_versions("x", "0.0.9"))
    assert not audit.version_in_range("0.0.10", audit.parse_versions("x", "=0.0.9"))

    # A lockfile-only scope is cross-checked with cargo tree (canned results).
    scoped = [("libcrux-kem", "0.0.9", False), ("crypto-bigint", "0.5.5", True)]
    seen: list = []

    def runner(result: tuple):
        def run(crate_dir: Path, spec: str) -> tuple:
            seen.append(spec)
            return result
        return run

    # cargo 1.9x: exit 0 and "nothing to print" for a locked-but-absent package.
    audit.check_unbuilt(scoped, ROOT, runner((0, "", "warning: nothing to print.\n")))
    audit.check_unbuilt(scoped, ROOT, runner((101, "", "error: package ID specification `libcrux-kem@0.0.9` did not match any packages")))
    assert seen == ["libcrux-kem@0.0.9"] * 2, seen  # only the lockfile-only scope; built=true is skipped
    for result, message in (
        ((0, "libcrux-kem v0.0.9\n└── hpke-rs-libcrux v0.7.0\n", ""), "entered the build graph"),
        ((101, "", "error: failed to read Cargo.toml"), "could not check libcrux-kem@0.0.9"),
        ((0, "", ""), "could not check libcrux-kem@0.0.9"),
    ):
        try:
            audit.check_unbuilt(scoped, ROOT, runner(result))
        except audit.PolicyError as error:
            assert message in str(error), f"expected {message!r}, got {error}"
        else:
            raise AssertionError(f"expected cargo tree result {result!r} to fail")

    # The real policy and the real lockfile: the scope check passes, and
    # shrinking an allowed parent makes it fail, from the command line too.
    lock = ROOT / "crypto/rust/Cargo.lock"
    real = audit.load_policy(ROOT / "crypto/rust/audit-policy.json")
    audit.check_scopes(real, lock)

    def cli(policy_path: Path, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPTS / "check-rust-audit-policy.py"), str(policy_path), "--now", NOW, *extra],
            capture_output=True, text=True, check=False,
        )

    good = cli(ROOT / "crypto/rust/audit-policy.json", "--lockfile", str(lock))
    assert good.returncode == 0, good.stderr
    shrunk = real_policy()
    shrunk["exceptions"][2]["scope"]["parents"] = ["not-elliptic-curve"]
    result = cli(policy_file(shrunk), "--lockfile", str(lock))
    assert result.returncode == 1 and "RUSTSEC-2026-0387: crypto-bigint 0.5.5 is reached through elliptic-curve" in result.stderr, result.stderr
    result = cli(ROOT / "crypto/rust/audit-policy.json", "--cargo-tree-dir", str(ROOT / "crypto/rust"))
    assert result.returncode == 1 and "--cargo-tree-dir needs --lockfile" in result.stderr, result.stderr

    # The audit script gives the scope check and cargo audit the same
    # lockfile, and checks scope before it audits.
    script = (SCRIPTS / "audit-rust.sh").read_text(encoding="utf-8")
    assert 'LOCKFILE="$CRATE/Cargo.lock"' in script
    scope_call = script.index('--lockfile "$LOCKFILE"')
    audit_call = script.index('cargo audit --file "$LOCKFILE"')
    assert scope_call < audit_call, "scope must be checked before cargo audit"
    commands = [line for line in script.splitlines() if line.startswith("cargo audit ")]
    assert commands == ['cargo audit --file "$LOCKFILE" "$@"'], commands

    print("rust audit exception scope tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
