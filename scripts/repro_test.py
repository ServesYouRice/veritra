#!/usr/bin/env python3
"""Tests for scripts/repro/ (env.sh pins, build.sh guards, compare.sh).

The build tools are fakes on PATH, so nothing here builds anything. They prove
the guards refuse: a wrong toolchain, a missing or wrong NDK, a dirty checkout,
and two hosts whose digests differ.
"""

from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPRO = ROOT / "scripts" / "repro"
H1, H2 = "1" * 64, "2" * 64


def sh(args, cwd=None, env=None):
    return subprocess.run(["sh", *args], cwd=cwd, env=env, text=True, capture_output=True, check=False)


class WorkflowTest(unittest.TestCase):
    """repro.yml must stay a manual, secret-free, pinned build check (D118)."""

    text = (ROOT / ".github" / "workflows" / "repro.yml").read_text(encoding="utf-8")

    def test_manual_trigger_only_and_read_only_token(self) -> None:
        self.assertRegex(self.text, r"(?m)^on:\n  workflow_dispatch:\n\npermissions:\n  contents: read\n")
        for trigger in ("push:", "pull_request", "schedule:", "release:"):
            self.assertNotIn(f"\n  {trigger}", self.text)

    def test_no_secrets_and_no_publishing(self) -> None:
        self.assertNotIn("secrets.", self.text)
        for word in ("gh release", "docker push", "attest-build-provenance", "signtool", "-SignToolCommand"):
            self.assertNotIn(word, self.text)

    def test_checkout_never_leaves_the_token_for_the_build(self) -> None:
        checkouts = re.findall(r"uses: actions/checkout@\S+[^\n]*\n((?:        .*\n)*)", self.text)
        self.assertTrue(checkouts)
        for options in checkouts:
            self.assertIn("persist-credentials: false", options)

    def test_every_action_is_pinned_to_a_sha_already_used_by_ci(self) -> None:
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        used = re.findall(r"uses: (\S+@[0-9a-f]{40})\b", self.text)
        self.assertEqual(len(used), len(re.findall(r"uses:", self.text)), "an action is not pinned to a full SHA")
        for action in used:
            self.assertIn(action, ci, f"{action} is not one CI already pins")


class CompareTest(unittest.TestCase):
    def compare(self, a: str, b: str):
        with tempfile.TemporaryDirectory() as temp:
            fa, fb = Path(temp) / "a", Path(temp) / "b"
            fa.write_text(a)
            fb.write_text(b)
            return sh([str(REPRO / "compare.sh"), str(fa), str(fb)])

    def test_identical_in_any_order(self) -> None:
        r = self.compare(f"{H1}  x\n{H2}  y z\n", f"{H2}  y z\n{H1}  x\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("identical (2 files)", r.stdout)

    def test_windows_line_ends_compare_equal(self) -> None:
        r = self.compare(f"{H1}  x\r\n{H2}  y\r\n", f"{H1}  x\n{H2}  y\n")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_a_changed_digest_fails_and_names_the_file(self) -> None:
        r = self.compare(f"{H1}  lib/libapp.so\n{H2}  ok\n", f"{H2}  lib/libapp.so\n{H2}  ok\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("differs:   lib/libapp.so", r.stderr)
        self.assertNotIn("ok", r.stderr.replace("DIFFERENT", ""))

    def test_missing_and_extra_files_fail(self) -> None:
        r = self.compare(f"{H1}  a\n{H1}  only a\n", f"{H1}  a\n{H2}  only-b\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("only in A: only a", r.stderr)
        self.assertIn("only in B: only-b", r.stderr)

    def test_not_a_sums_file_is_a_usage_error_not_a_match(self) -> None:
        for bad in ("", "garbage\n", f"{H1} one-space\n", f"{'A' * 64}  x\n"):
            r = self.compare(bad, bad)
            self.assertEqual(r.returncode, 2, (bad, r.stdout, r.stderr))
        self.assertEqual(sh([str(REPRO / "compare.sh")]).returncode, 2)


def fake_tool(directory: Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class EnvAndBuildTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.repo = base / "repo"
        (self.repo / "scripts" / "repro").mkdir(parents=True)
        for name in ("env.sh", "build.sh"):
            shutil.copy2(REPRO / name, self.repo / "scripts" / "repro" / name)
        (self.repo / "rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.91.0"\n')
        (self.repo / "mobile").mkdir()
        (self.repo / "mobile" / "pubspec.yaml").write_text("environment:\n  sdk: any\n  flutter: 3.44.0\n")
        git = ["git", "-C", str(self.repo)]
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
        subprocess.run([*git[:1], "init", "-q", str(self.repo)], check=True, env=env)
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "commit", "-q", "-m", "x"], check=True, env=env)
        self.bin = base / "bin"
        self.bin.mkdir()
        self.set_tools(rust="1.91.0", java="17.0.9", flutter="3.44.0")
        self.ndk = base / "ndk"
        self.ndk.mkdir()
        (self.ndk / "source.properties").write_text("Pkg.Desc = Android NDK\nPkg.Revision = 28.2.13676358\n")
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(base),
            "GIT_CONFIG_GLOBAL": os.devnull,
        }

    def set_tools(self, rust: str, java: str, flutter: str) -> None:
        fake_tool(self.bin, "rustc", f'case "$1" in --print) echo /fake/sysroot ;; *) echo "rustc {rust} (fake)" ;; esac')
        fake_tool(self.bin, "java", f'echo "openjdk version \\"{java}\\" 2024-01-01" >&2')
        fake_tool(self.bin, "flutter", f'echo \'{{"frameworkVersion": "{flutter}"}}\'')

    def run_env(self, command: str, **env_extra):
        return sh(["-c", f'ROOT="{self.repo}"; . "{self.repo}/scripts/repro/env.sh"; {command}'],
                  cwd=self.repo, env={**self.env, **env_extra})

    def test_pins_pass_when_the_toolchain_matches(self) -> None:
        r = self.run_env("check_rust; check_java; check_flutter", ANDROID_NDK_HOME=str(self.ndk))
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_wrong_toolchains_stop_the_build(self) -> None:
        self.set_tools(rust="1.92.0", java="17.0.9", flutter="3.44.0")
        self.assertIn("rustc 1.92.0, pinned 1.91.0", self.run_env("check_rust").stderr)
        self.set_tools(rust="1.91.0", java="21.0.1", flutter="3.44.0")
        self.assertIn("JDK 21, pinned 17", self.run_env("check_java").stderr)
        self.set_tools(rust="1.91.0", java="17.0.9", flutter="3.41.0")
        self.assertIn("flutter 3.41.0, pinned 3.44.0", self.run_env("check_flutter").stderr)

    def test_ndk_must_be_named_and_pinned(self) -> None:
        r = self.run_env("check_android_ndk")
        self.assertEqual(r.returncode, 1)
        self.assertIn("set ANDROID_NDK_HOME", r.stderr)
        (self.ndk / "source.properties").write_text("Pkg.Revision = 29.0.1\n")
        r = self.run_env("check_android_ndk", ANDROID_NDK_HOME=str(self.ndk))
        self.assertEqual(r.returncode, 1)
        self.assertIn("NDK 29.0.1", r.stderr)
        r = self.run_env("check_android_ndk", ANDROID_NDK_HOME=str(self.base_missing()))
        self.assertEqual(r.returncode, 1)

    def base_missing(self) -> Path:
        return Path(self.temp.name) / "no-such-ndk"

    def test_toolchain_record_has_versions_and_no_paths(self) -> None:
        out = Path(self.temp.name) / "TOOLCHAIN.txt"
        r = self.run_env(f'write_toolchain_record "{out}"', ANDROID_NDK_HOME=str(self.ndk))
        self.assertEqual(r.returncode, 0, r.stderr)
        text = out.read_text()
        for needle in ("rustc: rustc 1.91.0", "flutter: 3.44.0", "java: 17.0.9", "android_ndk: 28.2.13676358"):
            self.assertIn(needle, text)
        self.assertNotIn(self.temp.name, text)

    def test_build_refuses_a_dirty_checkout_and_a_used_output_folder(self) -> None:
        out = Path(self.temp.name) / "out"
        (self.repo / "stray.txt").write_text("uncommitted")
        r = sh([str(self.repo / "scripts/repro/build.sh"), "crypto-linux", str(out)], cwd=self.repo, env=self.env)
        self.assertEqual(r.returncode, 1)
        self.assertIn("uncommitted changes", r.stderr)
        (self.repo / "stray.txt").unlink()
        out.mkdir(exist_ok=True)
        (out / "old").write_text("x")
        r = sh([str(self.repo / "scripts/repro/build.sh"), "crypto-linux", str(out)], cwd=self.repo, env=self.env)
        self.assertEqual(r.returncode, 1)
        self.assertIn("is not empty", r.stderr)

    def test_android_build_needs_the_pinned_ndk_before_building(self) -> None:
        out = Path(self.temp.name) / "out2"
        r = sh([str(self.repo / "scripts/repro/build.sh"), "android", str(out)], cwd=self.repo, env=self.env)
        self.assertEqual(r.returncode, 1)
        self.assertIn("set ANDROID_NDK_HOME", r.stderr)


if __name__ == "__main__":
    unittest.main()
