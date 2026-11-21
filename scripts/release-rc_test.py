#!/usr/bin/env python3
"""Tests for scripts/release-rc.py: the dry run reports and never opens a gate."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RC = ROOT / "scripts" / "release-rc.py"

SH_STUBS = ("check-go-toolchain.sh", "check-rust-audit-expiry.sh", "check-demo-boundary.sh", "license-check.sh", "check-mobile-dependencies.sh")
PY_STUBS = ("check-gradle-inputs.py", "check-gradle-locks.py") + tuple(
    f"{name}_test.py"
    for name in (
        "check-release-evidence",
        "write-release-evidence",
        "check-ci-evidence",
        "check-go-toolchain",
        "check-rust-audit-policy",
        "check-demo-boundary",
        "check-gradle-inputs",
        "check-gradle-locks",
    )
)
PINNED = {
    "android": {"release_certificate_sha256": "a" * 64},
    "ios": {"team_id": "ABCDE12345", "bundle_id": "org.veritra.privateMessenger"},
}
G24_PASS = {"platforms": {p: {"rows": [{"id": "r1", "result": "pass"}]} for p in ("android", "ios")}}
PROPER_ENV = {"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", "/"), "GIT_CONFIG_GLOBAL": os.devnull}


def run(args, cwd=None, env=None):
    return subprocess.run([sys.executable, str(RC), *args], cwd=cwd, env=env or PROPER_ENV, text=True, capture_output=True, check=False)


class FakeRepo:
    """A repository whose scripts are stubs, so only release-rc.py's logic runs."""

    def __init__(self, gate_exit: int = 1) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in SH_STUBS:
            (scripts / name).write_text("exit 0\n")
        for name in PY_STUBS:
            (scripts / name).write_text("raise SystemExit(0)\n")
        (scripts / "build-windows-installer.ps1").write_text("exit 0\n")
        self.set_gate(gate_exit)
        (self.root / "release").mkdir()
        self.write_policy({"android": {"release_certificate_sha256": None}, "ios": {"team_id": None, "bundle_id": None}})
        (self.root / "crypto" / "rust").mkdir(parents=True)
        (self.root / "crypto/rust/audit-policy.json").write_text(json.dumps({"review_deadline": "2999-01-01T00:00:00Z"}))
        (self.root / "crypto/rust/src").mkdir()
        (self.root / "crypto/rust/src/lib.rs").write_text("// PM_CRYPTO_UNAVAILABLE\n")
        (self.root / "mobile/lib").mkdir(parents=True)
        (self.root / "mobile/lib/main.dart").write_text("// UnavailableCryptoService\n")
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "candidate")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), *args], env=PROPER_ENV, text=True, capture_output=True, check=True).stdout.strip()

    def set_gate(self, exit_code: int) -> None:
        (self.root / "scripts/release-readiness.sh").write_text(f'echo "gate says no"\nexit {exit_code}\n' if exit_code else 'echo "gate says yes"\nexit 0\n')

    def write_policy(self, policy: dict) -> None:
        (self.root / "release/release-policy.json").write_text(json.dumps(policy))

    def complete_everything(self) -> dict[str, str]:
        """Every owner item DONE; returns the env that names the approvals commit."""
        self.write_policy(PINNED)
        (self.root / "crypto/rust/src/lib.rs").write_text("// open\n")
        (self.root / "mobile/lib/main.dart").write_text("// open\n")
        (self.root / "dist").mkdir()
        (self.root / "dist/release-evidence.json").write_text("{}")
        (self.root / "testing/evidence").mkdir(parents=True)
        (self.root / "testing/evidence/G24-matrix.json").write_text(json.dumps(G24_PASS))
        (self.root / "mobile/lib/desktop").mkdir(parents=True)
        (self.root / "mobile/lib/desktop/update_trust.dart").write_text(f"const String updateFeedPublicKeyHex = '{'b' * 64}';\n")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "owner items")
        candidate = self.git("rev-parse", "HEAD")
        approvals = self.root / "release/approvals" / candidate
        approvals.mkdir(parents=True)
        for name in ("independent-review", "production-crypto"):
            (approvals / f"{name}.json").write_text("{}")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "approvals")
        return {"RELEASE_COMMIT": candidate, "RELEASE_APPROVALS_COMMIT": self.git("rev-parse", "HEAD")}

    def close(self) -> None:
        self.temp.cleanup()


class ReleaseRcTest(unittest.TestCase):
    def repo(self, gate_exit: int = 1) -> FakeRepo:
        repo = FakeRepo(gate_exit)
        self.addCleanup(repo.close)
        return repo

    def rc(self, repo: FakeRepo, *args: str, **env):
        return run(["--root", str(repo.root), *args], env={**PROPER_ENV, **env})

    def test_blocked_release_exits_3_and_never_says_passed(self) -> None:
        r = self.rc(self.repo(), )
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("RELEASE BLOCKED", r.stdout)
        self.assertNotIn("PASSED", r.stdout)
        self.assertIn("gate says no", r.stdout)

    def test_dry_run_exits_0_but_still_says_blocked(self) -> None:
        r = self.rc(self.repo(), "--dry-run")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("RELEASE BLOCKED", r.stdout)
        self.assertIn("this is not a release", r.stdout)
        self.assertNotIn("PASSED", r.stdout)

    def test_missing_items_are_named(self) -> None:
        out = self.rc(self.repo(), "--dry-run").stdout
        for needle in (
            "MISSING Android release certificate pin",
            "MISSING iOS team ID pin",
            "MISSING iOS bundle ID pin",
            "MISSING G24",
            "MISSING G25",
            "MISSING Production crypto wired",
            "MISSING Update feed public key",
            "OWNER   Windows code-signing certificate",
            "OWNER   FCM and APNs push credentials",
            "OWNER   A TURN server",
            "G27 advisory exceptions expire 2999-01-01",
        ):
            self.assertIn(needle, out)

    def test_a_failed_check_fails_even_a_dry_run(self) -> None:
        for name in ("check-demo-boundary.sh", "check-gradle-inputs.py"):
            repo = self.repo()
            stub = repo.root / "scripts" / name
            stub.write_text("echo boom >&2\nexit 1\n" if name.endswith(".sh") else "import sys\nprint('boom', file=sys.stderr)\nsys.exit(1)\n")
            for args in ((), ("--dry-run",)):
                r = self.rc(repo, *args)
                self.assertEqual(r.returncode, 1, (name, args, r.stdout))
                self.assertIn("DRY RUN FAILED", r.stdout)
                self.assertIn("FAIL  ", r.stdout)

    def test_a_missing_check_script_fails_closed(self) -> None:
        repo = self.repo()
        (repo.root / "scripts/check-go-toolchain.sh").unlink()
        r = self.rc(repo, "--dry-run")
        self.assertEqual(r.returncode, 1)
        self.assertIn("missing check-go-toolchain.sh", r.stdout)

    def test_a_refusing_gate_is_never_turned_into_success(self) -> None:
        repo = self.repo(gate_exit=1)
        env = repo.complete_everything()
        for args in ((), ("--dry-run",)):
            r = self.rc(repo, *args, **env)
            self.assertNotIn("MISSING", r.stdout.replace("MISSING items", ""), r.stdout)
            self.assertNotIn("PASSED", r.stdout)
            self.assertIn("RELEASE BLOCKED: release-readiness.sh refuses", r.stdout)
            self.assertEqual(r.returncode, 3 if not args else 0)

    def test_passes_only_when_the_gate_passes_and_nothing_is_missing(self) -> None:
        repo = self.repo(gate_exit=0)
        env = repo.complete_everything()
        r = self.rc(repo, **env)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("RELEASE GATES PASSED", r.stdout)
        # one missing owner item is enough to block, even with a passing gate
        (repo.root / "testing/evidence/G24-matrix.json").write_text(json.dumps({"platforms": {"android": {"rows": [{"id": "r", "result": "pending"}]}, "ios": {"rows": []}}}))
        r = self.rc(repo, **env)
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("MISSING G24", r.stdout)

    def test_quick_needs_dry_run_and_unknown_flags_are_refused(self) -> None:
        repo = self.repo()
        self.assertEqual(self.rc(repo, "--quick").returncode, 2)
        self.assertEqual(self.rc(repo, "--bogus").returncode, 2)
        self.assertNotIn("PASSED", self.rc(self.repo(gate_exit=0), "--dry-run", "--quick").stdout)

    def test_real_repository_dry_run_is_blocked_by_the_real_gate(self) -> None:
        r = run(["--dry-run", "--quick"], cwd=ROOT)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("RELEASE BLOCKED", r.stdout)
        self.assertRegex(r.stdout, r"exit status [1-9]")
        for pin in ("Android release certificate pin", "iOS team ID pin", "iOS bundle ID pin", "Gradle lock files"):
            self.assertIn(f"MISSING {pin}", r.stdout)

    def test_real_gate_still_refuses_with_every_pin_set(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            policy = json.loads((ROOT / "release/release-policy.json").read_text())
            policy["android"] = PINNED["android"]
            policy["ios"] = PINNED["ios"]
            path = Path(temp) / "policy.json"
            path.write_text(json.dumps(policy))
            env = {**PROPER_ENV, "RELEASE_POLICY_FILE": str(path)}
            gate = subprocess.run(["sh", str(ROOT / "scripts/release-readiness.sh")], cwd=ROOT, env=env, text=True, capture_output=True, check=False)
            self.assertNotEqual(gate.returncode, 0, gate.stdout + gate.stderr)
            self.assertRegex(gate.stdout + gate.stderr, r"blocked|refus")
            r = run(["--dry-run", "--quick"], cwd=ROOT, env=env)
            self.assertIn("DONE    Android release certificate pin", r.stdout)
            self.assertIn("RELEASE BLOCKED", r.stdout)
            self.assertNotIn("PASSED", r.stdout)
            self.assertRegex(r.stdout, r"exit status [1-9]")


if __name__ == "__main__":
    unittest.main()
