#!/usr/bin/env python3
"""Release candidate procedure: one command, a dry run that needs no secrets.

Usage: release-rc.py [--dry-run] [--quick] [--root DIR]

Runs, in order:

1. Every check that needs no account, key or device (toolchain, advisory
   deadline, demo boundary, pinned Gradle inputs and lock wiring, notices,
   dependency policy, the release-gate fixture tests that prove the gates
   still refuse, ...). Each one prints PASS, FAIL or SKIP with the reason.
2. The list of what only the owner can supply (signing pins and accounts, the
   update key, approvals, the G24 matrix, Gradle lock files, push credentials,
   a TURN server, branch protection), each marked MISSING, DONE or OWNER (not
   checkable from the repository).
3. scripts/release-readiness.sh, unchanged. Its output is printed as it is.
   This script never decides that a release is ready: only that script's exit
   status does, and nothing printed here can turn its refusal into a pass.

Exit status:
  default     0 only when every check passed, nothing is missing and
              release-readiness.sh passed; 1 when a check failed; 3 when the
              checks passed but the release is blocked.
  --dry-run   0 when every check passed, even though the release is blocked
              (the last line still says RELEASE BLOCKED); 1 when a check failed.
  --quick     skips the slow and the network checks; only with --dry-run.

Run it from the repository: python3 scripts/release-rc.py --dry-run
"""

from __future__ import annotations

import datetime
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"
MISSING, DONE, OWNER = "MISSING", "DONE", "OWNER"

# The fixture tests of the release gates and of what feeds them: they exist to
# prove the gates refuse, so the dry run runs them and does not trust a green
# gate without them.
GATE_TESTS = (
    "check-release-evidence_test.py",
    "write-release-evidence_test.py",
    "check-ci-evidence_test.py",
    "check-go-toolchain_test.py",
    "check-rust-audit-policy_test.py",
    "check-demo-boundary_test.py",
    "check-gradle-inputs_test.py",
    "check-gradle-locks_test.py",
)


@dataclass
class Check:
    name: str
    command: list[str]
    script: Path | None = None  # must exist, else FAIL
    slow: bool = False  # skipped by --quick
    needs: str | None = None  # a program that must exist, else SKIP
    needs_reason: str = ""


@dataclass
class Result:
    name: str
    status: str
    detail: str = ""


def sh_check(name: str, script: Path, *args: str, **kwargs) -> Check:
    return Check(name, ["sh", str(script), *args], script=script, **kwargs)


def py_check(name: str, script: Path, *args: str, **kwargs) -> Check:
    return Check(name, [sys.executable, str(script), *args], script=script, **kwargs)


def checks(root: Path) -> list[Check]:
    s = root / "scripts"
    android = root / "mobile" / "android"
    gate_tests = [s / name for name in GATE_TESTS]
    items = [
        sh_check("Go toolchain aligned", s / "check-go-toolchain.sh"),
        sh_check("Rust advisory exceptions not expired (G27)", s / "check-rust-audit-expiry.sh"),
        sh_check("Demo code kept out of the release entry point", s / "check-demo-boundary.sh"),
        py_check("Gradle wrapper and versions pinned", s / "check-gradle-inputs.py", str(android)),
        py_check("Gradle dependency locking wired in", s / "check-gradle-locks.py", str(android)),
        sh_check("Third-party notices complete", s / "license-check.sh"),
        Check(
            "Windows installer script dry run",
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(s / "build-windows-installer.ps1"), "-DryRun"],
            script=s / "build-windows-installer.ps1",
            needs="powershell",
            needs_reason="PowerShell is not installed here; CI builds the installer (repro.yml)",
        ),
        sh_check(
            "Mobile dependency policy (pub lock, retractions)",
            s / "check-mobile-dependencies.sh",
            slow=True,
            needs="dart",
            needs_reason="dart is not installed",
        ),
    ]
    for test in gate_tests:
        items.append(py_check(f"Gate fixture tests: {test.name}", test, slow=True))
    return items


def run_check(check: Check, quick: bool, env: dict[str, str]) -> Result:
    if quick and check.slow:
        return Result(check.name, SKIP, "--quick")
    if check.script is not None and not check.script.is_file():
        return Result(check.name, FAIL, f"missing {check.script.name}")
    if check.needs and shutil.which(check.needs) is None:
        return Result(check.name, SKIP, check.needs_reason or f"{check.needs} not found")
    proc = subprocess.run(check.command, env=env, text=True, capture_output=True, check=False)
    if proc.returncode == 0:
        return Result(check.name, PASS)
    tail = (proc.stderr or proc.stdout).strip().splitlines()[-3:]
    return Result(check.name, FAIL, " | ".join(line.strip() for line in tail))


def git(root: Path, *args: str) -> tuple[int, str]:
    proc = subprocess.run(["git", "-C", str(root), *args], text=True, capture_output=True, check=False)
    return proc.returncode, proc.stdout.strip()


def policy_path(root: Path) -> Path:
    return Path(os.environ.get("RELEASE_POLICY_FILE") or root / "release" / "release-policy.json")


def read_policy(root: Path) -> dict | None:
    try:
        data = json.loads(policy_path(root).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def pin(policy: dict | None, section: str, key: str) -> object:
    value = (policy or {}).get(section)
    return value.get(key) if isinstance(value, dict) else None


def candidate(root: Path) -> str:
    return os.environ.get("RELEASE_COMMIT") or git(root, "rev-parse", "HEAD")[1]


def approvals_commit(root: Path) -> str:
    if "RELEASE_APPROVALS_COMMIT" in os.environ:
        return os.environ["RELEASE_APPROVALS_COMMIT"]
    code, out = git(root, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/main^{commit}")
    return out if code == 0 else ""


def approval_present(root: Path, name: str) -> bool:
    commit, head = approvals_commit(root), candidate(root)
    if not commit or not head:
        return False
    return git(root, "cat-file", "-e", f"{commit}:release/approvals/{head}/{name}.json")[0] == 0


def lock_files_ok(root: Path) -> tuple[bool, str]:
    proc = subprocess.run(
        [sys.executable, str(root / "scripts" / "check-gradle-locks.py"), str(root / "mobile" / "android"), "--require-files"],
        text=True,
        capture_output=True,
        check=False,
    )
    return proc.returncode == 0, "run scripts/gradle-lock.sh write on a host with the Android SDK"


def update_key_pinned(root: Path) -> bool:
    path = root / "mobile" / "lib" / "desktop" / "update_trust.dart"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return False
    match = re.search(r"const String updateFeedPublicKeyHex\s*=\s*'([0-9a-f]*)'", text)
    return bool(match and re.fullmatch(r"[0-9a-f]{64}", match.group(1)))


def crypto_gate_open(root: Path) -> bool:
    """The same two markers release-readiness.sh greps for, read-only."""
    markers = (("crypto/rust/src/lib.rs", "PM_CRYPTO_UNAVAILABLE"), ("mobile/lib/main.dart", "UnavailableCryptoService"))
    for relative, marker in markers:
        try:
            if marker in (root / relative).read_text(encoding="utf-8"):
                return False
        except OSError:
            return False
    return True


def g24_state(root: Path) -> tuple[str, str]:
    path = root / "testing" / "evidence" / "G24-matrix.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        rows = [row for platform in ("android", "ios") for row in data["platforms"][platform]["rows"]]
    except (OSError, ValueError, KeyError, TypeError):
        return MISSING, "no testing/evidence/G24-matrix.json; scripts/g24-matrix.py init, then docs/g24-device-matrix.md"
    pending = [row for row in rows if not isinstance(row, dict) or row.get("result") != "pass"]
    if pending:
        return MISSING, f"{len(pending)} of {len(rows)} rows are not a recorded pass (scripts/g24-matrix.py status)"
    return DONE, "every row recorded as pass"


def owner_items(root: Path) -> list[tuple[str, str, str]]:
    """(label, status, how to fix). Detects only what the repository shows."""
    policy = read_policy(root)
    items: list[tuple[str, str, str]] = []

    def pin_item(label: str, value: object, where: str) -> None:
        items.append((label, DONE if value else MISSING, where))

    pin_item(
        "Android release certificate pin (release-policy.json android.release_certificate_sha256)",
        pin(policy, "android", "release_certificate_sha256"),
        "docs/security-review.md, Pinning the Android release certificate",
    )
    pin_item("iOS team ID pin (ios.team_id)", pin(policy, "ios", "team_id"), "docs/security-review.md, Pinning the iOS team and bundle IDs")
    pin_item("iOS bundle ID pin (ios.bundle_id)", pin(policy, "ios", "bundle_id"), "docs/security-review.md, Pinning the iOS team and bundle IDs")
    ok, how = lock_files_ok(root)
    items.append(("Gradle lock files and checksums committed", DONE if ok else MISSING, how))
    status, how = g24_state(root)
    items.append(("G24 two-device matrix recorded", status, how))
    items.append((
        "G25 independent review approval for this commit",
        DONE if approval_present(root, "independent-review") else MISSING,
        "a reviewer, then docs/security-review.md, Recording an approval",
    ))
    items.append((
        "Production-crypto approval for this commit",
        DONE if approval_present(root, "production-crypto") else MISSING,
        "docs/security-review.md, Recording an approval",
    ))
    items.append((
        "Production crypto wired (PM_CRYPTO_UNAVAILABLE and UnavailableCryptoService gone)",
        DONE if crypto_gate_open(root) else MISSING,
        "only after G25 and G24 (AGENTS.md, Governing principle); release-readiness.sh never reaches this check while an earlier gate refuses",
    ))
    items.append((
        "Signed release records and release evidence",
        DONE if (root / "dist" / "release-evidence.json").is_file() else MISSING,
        "signed builds of the frozen commit, then scripts/write-release-evidence.py",
    ))
    items.append((
        "Update feed public key compiled into the Windows app",
        DONE if update_key_pinned(root) else MISSING,
        "docs/release-engineering.md, Update channel: make the key, set updateFeedPublicKeyHex",
    ))
    for label, how in (
        ("Apple Developer account and distribution profile (iOS signing)", "owner"),
        ("Android upload/release keystore (and Play account for the play flavor)", "owner"),
        ("Windows code-signing certificate", "docs/release-engineering.md, Windows installer"),
        ("FCM and APNs push credentials", "docs/operations.md"),
        ("A TURN server for the call rows of G24", "docs/operations.md"),
        ("Branch protection and code-owner review on main and v* tags", "STATE.md, Open work"),
    ):
        items.append((label, OWNER, f"not checkable from the repository ({how})"))
    return items


def g27_days(root: Path) -> str:
    try:
        deadline = json.loads((root / "crypto" / "rust" / "audit-policy.json").read_text(encoding="utf-8"))["review_deadline"]
        when = datetime.datetime.fromisoformat(deadline.replace("Z", "+00:00"))
    except (OSError, ValueError, KeyError):
        return "G27 deadline: unreadable"
    left = (when - datetime.datetime.now(datetime.timezone.utc)).days
    return f"G27 advisory exceptions expire {when.date()} ({left} days left)" if left >= 0 else f"G27 advisory exceptions EXPIRED {when.date()}"


def main(argv: list[str]) -> int:
    args = list(argv)
    dry = "--dry-run" in args
    quick = "--quick" in args
    root = Path(__file__).resolve().parent.parent
    if "--root" in args:
        index = args.index("--root")
        try:
            root = Path(args[index + 1]).resolve()
        except IndexError:
            print("usage: release-rc.py [--dry-run] [--quick] [--root DIR]", file=sys.stderr)
            return 2
        del args[index : index + 2]
    unknown = [a for a in args if a not in ("--dry-run", "--quick")]
    if unknown:
        print(f"unknown argument: {unknown[0]}\nusage: release-rc.py [--dry-run] [--quick] [--root DIR]", file=sys.stderr)
        return 2
    if quick and not dry:
        print("--quick skips checks, so it is only allowed with --dry-run", file=sys.stderr)
        return 2

    env = dict(os.environ)
    print(f"Release candidate dry run for {candidate(root) or 'an unknown commit'}\n" if dry else f"Release candidate check for {candidate(root) or 'an unknown commit'}\n")

    print("1. Checks that need no secrets")
    results = [run_check(check, quick, env) for check in checks(root)]
    for result in results:
        suffix = f"  ({result.detail})" if result.detail else ""
        print(f"  {result.status:<5} {result.name}{suffix}")
    failed = [r for r in results if r.status == FAIL]
    skipped = [r for r in results if r.status == SKIP]

    print("\n2. What only the owner can supply")
    items = owner_items(root)
    for label, status, how in items:
        print(f"  {status:<7} {label}" + ("" if status == DONE else f"\n          -> {how}"))
    missing = [i for i in items if i[1] == MISSING]
    print(f"\n  {g27_days(root)}")

    print("\n3. scripts/release-readiness.sh (the gate; unchanged)")
    gate = subprocess.run(["sh", str(root / "scripts" / "release-readiness.sh")], cwd=root, env=env, text=True, capture_output=True, check=False)
    for line in (gate.stdout + gate.stderr).strip().splitlines():
        print(f"  | {line}")
    print(f"  exit status {gate.returncode}")

    print()
    if failed:
        print(f"DRY RUN FAILED: {len(failed)} check(s) failed: " + "; ".join(r.name for r in failed))
        return 1
    if gate.returncode == 0 and not missing and not quick:
        # Skips without --quick are platform limits (no PowerShell here); the
        # check runs in CI. OWNER items are reminders this script cannot read.
        print("RELEASE GATES PASSED: release-readiness.sh exited 0 and no owner item is missing")
        print("(confirm the OWNER items above yourself; skipped here: " + (", ".join(r.name for r in skipped) or "nothing") + ")")
        return 0
    reasons = []
    if gate.returncode != 0:
        reasons.append("release-readiness.sh refuses")
    if missing:
        reasons.append(f"{len(missing)} owner item(s) missing")
    if quick:
        reasons.append("--quick skipped checks")
    print("RELEASE BLOCKED: " + "; ".join(reasons))
    if dry:
        print("(dry run: all checks that need no secrets passed, so the exit status is 0; this is not a release)")
        return 0
    return 3


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
