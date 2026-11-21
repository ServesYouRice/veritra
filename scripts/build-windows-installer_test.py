#!/usr/bin/env python3
"""Tests for scripts/build-windows-installer.ps1."""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "build-windows-installer.ps1"


class WindowsInstallerScriptTest(unittest.TestCase):
    def setUp(self) -> None:
        if shutil.which("powershell") is None:
            self.skipTest("powershell not available")
    def run_ps(self, *args: str) -> subprocess.CompletedProcess[str]:
        cmd = [
            "powershell",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(SCRIPT),
            *args,
        ]
        return subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def test_dry_run_default(self) -> None:
        pubspec = (ROOT / "mobile" / "pubspec.yaml").read_text(encoding="utf-8")
        match = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)", pubspec, re.M)
        ver = match.group(1) if match else "0.1.0"
        result = self.run_ps("-DryRun")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("building unsigned installer (signing placeholder)", result.stdout)
        self.assertIn("[DryRun] Inno Setup compiler:", result.stdout)
        self.assertIn(f"/DAppVersion={ver}", result.stdout)
        self.assertIn(f"Veritra-Setup-{ver}-x64.exe", result.stdout)

    def test_dry_run_with_signing_placeholder_command(self) -> None:
        sign_cmd = "signtool.exe sign /fd sha256 $f"
        result = self.run_ps("-DryRun", "-SignToolCommand", sign_cmd)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Configured SignTool with custom signing command", result.stdout)
        self.assertIn("/DSignToolName=veritra", result.stdout)
        self.assertIn(f"/Sveritra={sign_cmd}", result.stdout)

    def test_dry_run_custom_version_and_outdir(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "custom_dist"
            result = self.run_ps(
                "-DryRun",
                "-AppVersion",
                "1.2.3",
                "-OutDir",
                str(out_dir),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("/DAppVersion=1.2.3", result.stdout)
            self.assertIn(f"/DOutDir={out_dir}", result.stdout)
            self.assertIn("Veritra-Setup-1.2.3-x64.exe", result.stdout)

    def test_fails_when_app_dir_lacks_binary_without_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            empty_app_dir = Path(tmp) / "empty_app"
            empty_app_dir.mkdir()
            result = self.run_ps(
                "-AppDir",
                str(empty_app_dir),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Windows application executable not found", result.stderr)

    def test_mock_iscc_execution(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "app"
            app_dir.mkdir()
            (app_dir / "private_messenger.exe").write_bytes(b"dummy exe")

            out_dir = tmp_path / "dist"
            version = "0.9.9"

            # Create a mock iscc.bat that writes the expected output file
            mock_iscc = tmp_path / "mock_iscc.bat"
            target_installer = out_dir / f"Veritra-Setup-{version}-x64.exe"
            mock_iscc.write_text(
                f'@echo off\n'
                f'if not exist "{out_dir}" mkdir "{out_dir}"\n'
                f'echo mock installer content > "{target_installer}"\n'
                f'exit /b 0\n'
            )

            info = tmp_path / "build-info.txt"
            info.write_text("source_revision=" + "0" * 40 + "\nsource_tree_dirty=false\n")
            args = [
                "-AppDir",
                str(app_dir),
                "-AppVersion",
                version,
                "-OutDir",
                str(out_dir),
                "-IsccPath",
                str(mock_iscc),
                "-CryptoBuildInfo",
                str(info),
            ]

            # D134: a dirty, malformed or missing crypto build record refuses packaging.
            for text in ("source_tree_dirty=true\n", "no flag\n", "source_tree_dirty=false\nsource_tree_dirty=true\n"):
                info.write_text(text)
                refused = self.run_ps(*args)
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn("not built from committed sources", refused.stderr)
                self.assertFalse(target_installer.exists())
            info.unlink()
            missing = self.run_ps(*args)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("Crypto build record not found", missing.stderr)
            info.write_text("source_revision=" + "0" * 40 + "\nsource_tree_dirty=false\n")

            result = self.run_ps(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(target_installer.exists())

            sums_file = out_dir / "SHA256SUMS"
            self.assertTrue(sums_file.exists())
            content = sums_file.read_text(encoding="ascii").strip()
            expected_hash = hashlib.sha256(target_installer.read_bytes()).hexdigest().lower()
            self.assertEqual(content, f"{expected_hash}  Veritra-Setup-{version}-x64.exe")
            self.assertIn(f"SHA256: {expected_hash}", result.stdout)


class WindowsReleaseFilesTest(unittest.TestCase):
    """The installer definition, its build script and the app agree (no PowerShell needed)."""

    iss = (ROOT / "release" / "windows" / "veritra.iss").read_text(encoding="utf-8")
    ps1 = SCRIPT.read_text(encoding="utf-8")

    def test_installer_name_matches_the_build_script(self) -> None:
        self.assertIn("OutputBaseFilename=Veritra-Setup-{#AppVersion}-x64", self.iss)
        self.assertIn("Veritra-Setup-$AppVersion-x64.exe", self.ps1)

    def test_packaged_executable_is_the_one_cmake_builds(self) -> None:
        cmake = (ROOT / "mobile" / "windows" / "CMakeLists.txt").read_text(encoding="utf-8")
        binary = re.search(r'set\(BINARY_NAME "([^"]+)"\)', cmake)
        self.assertIsNotNone(binary)
        self.assertIn(f"{binary.group(1)}.exe", self.iss)
        self.assertIn(f"{binary.group(1)}.exe", self.ps1)

    def test_app_id_never_changes(self) -> None:
        # A changed AppId would install next to the old version instead of updating it.
        self.assertIn("AppId={{6D1B6D0E-5C57-4F5B-9B0B-7E0F7A3A9C11}", self.iss)

    def test_referenced_files_exist(self) -> None:
        icon = re.search(r"SetupIconFile=\{#SourcePath\}\\(.+)", self.iss)
        self.assertIsNotNone(icon)
        relative = icon.group(1).strip().replace("\\", "/")
        self.assertTrue((ROOT / "release" / "windows" / relative).resolve().is_file(), relative)
        self.assertTrue((ROOT / "LICENSE").is_file())

    def test_signing_is_conditional_and_holds_no_secret(self) -> None:
        sign_lines = [line for line in self.iss.splitlines() if line.startswith("SignTool")]
        self.assertTrue(sign_lines)
        lines = self.iss.splitlines()
        for index, line in enumerate(lines):
            if line.startswith("SignTool"):
                self.assertTrue(any(l.startswith("#ifdef SignToolName") for l in lines[:index]))
        for needle in (".pfx", ".p12", "password=", "/p "):
            code = "\n".join(l for l in lines if not l.startswith(";"))
            self.assertNotIn(needle, code)

    def test_silent_update_flags_the_app_uses_are_honoured(self) -> None:
        launcher = (ROOT / "mobile" / "lib" / "desktop" / "update_installer.dart").read_text(encoding="utf-8")
        for flag in ("/SILENT", "/NORESTART", "/CLOSEAPPLICATIONS"):
            self.assertIn(f"'{flag}'", launcher)
        self.assertIn("CloseApplications=yes", self.iss)
        self.assertIn("skipifsilent", self.iss)


if __name__ == "__main__":
    unittest.main()
