#!/usr/bin/env python3
"""Tests for scripts/ios-crypto-build-record.sh, the iOS side of D134.

Each case copies the real script and scripts/check-release-evidence.py into a
scratch root and runs the script with the variables Xcode sets for a build
phase. No Xcode runs: whether Xcode runs the phase, and where the record lands
in a real exported .ipa, is only shown on a Mac (CI job mobile-ios, G24).
"""

from __future__ import annotations

import posix_shell

import ast
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "ios-crypto-build-record.sh"
CHECKER = ROOT / "scripts" / "check-release-evidence.py"
PBXPROJ = ROOT / "mobile" / "ios" / "Runner.xcodeproj" / "project.pbxproj"
RECORD = "mobile/ios/Frameworks/veritra-crypto-metadata/build-info.txt"
CLEAN = "source_revision=" + "0" * 40 + "\ncargo_lock_sha256=" + "0" * 64 + "\nsource_tree_dirty=false\nrustc 1\n"
BAD_RECORDS = {
    "dirty": "source_revision=" + "0" * 40 + "\nsource_tree_dirty=true\n",
    "no flag": "source_revision=" + "0" * 40 + "\n",
    "empty": "",
    "odd": "source_tree_dirty=maybe\n",
    "twice": "source_tree_dirty=false\nsource_tree_dirty=true\n",
    "padded": "source_tree_dirty=false \n",
}


class IosCryptoBuildRecordTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / "repo"
        (self.root / "scripts").mkdir(parents=True)
        shutil.copy2(SCRIPT, self.root / "scripts" / SCRIPT.name)
        shutil.copy2(CHECKER, self.root / "scripts" / CHECKER.name)
        self.record = self.root / RECORD
        self.build_dir = Path(temp.name) / "Build" / "Products" / "Release-iphoneos"
        self.copy = self.build_dir / "Runner.app" / "veritra-crypto" / "build-info.txt"

    def write_record(self, text: str) -> None:
        self.record.parent.mkdir(parents=True, exist_ok=True)
        self.record.write_text(text, encoding="utf-8")

    def run_phase(self, configuration: str | None, **overrides: str | None) -> subprocess.CompletedProcess[str]:
        env = {
            key: value
            for key, value in os.environ.items()
            if key not in ("CONFIGURATION", "TARGET_BUILD_DIR", "UNLOCALIZED_RESOURCES_FOLDER_PATH")
        }
        values: dict[str, str | None] = {
            "CONFIGURATION": configuration,
            "TARGET_BUILD_DIR": str(self.build_dir),
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Runner.app",
        }
        values.update(overrides)
        env.update({key: value for key, value in values.items() if value is not None})
        # Xcode runs the phase from the project directory, not the repository root.
        cwd = self.root / "mobile" / "ios"
        cwd.mkdir(parents=True, exist_ok=True)
        return subprocess.run(
            [posix_shell.find("sh"), str(self.root / "scripts" / SCRIPT.name)],
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def test_release_with_clean_record_copies_it(self) -> None:
        self.write_record(CLEAN)
        result = self.run_phase("Release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.copy.read_bytes(), self.record.read_bytes())

    def test_release_like_configurations_refuse_bad_records(self) -> None:
        # Only Debug and Profile are exempt: an unknown or unset configuration
        # is treated as a release.
        for configuration in ("Release", "Release-Store", "", None):
            for name, text in BAD_RECORDS.items():
                with self.subTest(configuration=configuration, record=name):
                    self.write_record(CLEAN)
                    self.assertEqual(self.run_phase("Debug").returncode, 0)
                    self.assertTrue(self.copy.exists())
                    self.write_record(text)
                    result = self.run_phase(configuration)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("not built from committed sources", result.stderr)
                    # Neither the bad record nor an older good one stays in the bundle.
                    self.assertFalse(self.copy.exists())

    def test_release_refuses_a_missing_record(self) -> None:
        self.write_record(CLEAN)
        self.assertEqual(self.run_phase("Release").returncode, 0)
        self.record.unlink()
        result = self.run_phase("Release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Crypto build record not found", result.stderr)
        self.assertFalse(self.copy.exists())

    def test_release_refuses_without_python3(self) -> None:
        self.write_record(CLEAN)
        bin_dir = self.root / "bin-without-python"
        bin_dir.mkdir()
        for tool in ("cp", "mkdir", "rm", "dirname"):
            found = shutil.which(tool)
            if found is None:
                self.skipTest(f"{tool} not found")
            os.symlink(found, bin_dir / tool)
        result = self.run_phase("Release", PATH=str(bin_dir))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("python3 is needed", result.stderr)
        self.assertFalse(self.copy.exists())

    def test_debug_and_profile_copy_any_record_and_never_refuse(self) -> None:
        for configuration in ("Debug", "Profile"):
            for name, text in BAD_RECORDS.items():
                with self.subTest(configuration=configuration, record=name):
                    self.write_record(text)
                    result = self.run_phase(configuration)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.copy.read_text(encoding="utf-8"), text)
            with self.subTest(configuration=configuration, record="missing"):
                self.record.unlink()
                result = self.run_phase(configuration)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(self.copy.exists())

    def test_missing_build_variables_fail(self) -> None:
        self.write_record(CLEAN)
        for variable in ("TARGET_BUILD_DIR", "UNLOCALIZED_RESOURCES_FOLDER_PATH"):
            with self.subTest(variable=variable):
                result = self.run_phase("Debug", **{variable: None})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{variable} is not set", result.stderr)


class CryptoBuildInfoFlagTest(unittest.TestCase):
    """check-release-evidence.py --crypto-build-info, which the phase calls."""

    def run_flag(self, path: Path) -> subprocess.CompletedProcess[str]:
        # Outside any git repository: the flag must not need a candidate commit.
        return subprocess.run(
            [sys.executable, str(CHECKER), "--crypto-build-info", str(path)],
            cwd=path.parent,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def test_flag(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "build-info.txt"
            path.write_text(CLEAN, encoding="utf-8")
            result = self.run_flag(path)
            self.assertEqual(result.returncode, 0, result.stderr)
            for name, text in BAD_RECORDS.items():
                with self.subTest(record=name):
                    path.write_text(text, encoding="utf-8")
                    result = self.run_flag(path)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("the crypto library", result.stderr)
            path.write_text("source_tree_dirty=true\n", encoding="utf-8")
            self.assertIn("uncommitted crypto sources", self.run_flag(path).stderr)
            path.unlink()
            result = self.run_flag(path)
            self.assertEqual(result.returncode, 1)
            self.assertIn("not found or unreadable", result.stderr)

    def test_checker_parses_as_python_3_9(self) -> None:
        # The phase runs it with the Mac's /usr/bin/python3 (3.9 with Xcode's
        # command line tools). A newer syntax would refuse every iOS release.
        ast.parse(CHECKER.read_text(encoding="utf-8"), feature_version=(3, 9))


class XcodeWiringTest(unittest.TestCase):
    """Text-level proof that the Runner target runs the phase. Xcode itself only runs on a Mac."""

    def test_runner_target_runs_the_phase(self) -> None:
        project = PBXPROJ.read_text(encoding="utf-8")
        phases = re.findall(
            r"(\w{24}) /\* Crypto Build Record \*/ = \{\n(.*?)\n\t\t\};", project, re.S
        )
        self.assertEqual(len(phases), 1, "exactly one Crypto Build Record phase")
        phase_id, body = phases[0]
        self.assertIn("isa = PBXShellScriptBuildPhase;", body)
        self.assertIn("alwaysOutOfDate = 1;", body)
        self.assertIn("runOnlyForDeploymentPostprocessing = 0;", body)
        self.assertIn(
            'shellScript = "/bin/sh \\"$SRCROOT/../../scripts/ios-crypto-build-record.sh\\"";', body
        )
        self.assertEqual(project.count(phase_id), 2, "defined once and listed once")

        targets = re.findall(r"/\* (\w+) \*/ = \{\n\t\t\tisa = PBXNativeTarget;.*?buildPhases = \((.*?)\);", project, re.S)
        listed = {name: phase_id in phases_list for name, phases_list in targets}
        self.assertEqual(listed, {"RunnerTests": False, "Runner": True})
        # SRCROOT is mobile/ios, so the path above reaches this script.
        self.assertTrue((PBXPROJ.parent.parent / ".." / ".." / "scripts" / SCRIPT.name).resolve().samefile(SCRIPT))
        # The script reads files outside the sandbox Xcode would otherwise impose.
        self.assertNotIn("ENABLE_USER_SCRIPT_SANDBOXING = YES", project)


if __name__ == "__main__":
    unittest.main()
