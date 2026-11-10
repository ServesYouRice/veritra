#!/usr/bin/env python3
"""Tests for scripts/build-windows-installer.ps1."""

from __future__ import annotations

import hashlib
import os
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
        result = self.run_ps("-DryRun")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("building unsigned installer (signing placeholder)", result.stdout)
        self.assertIn("[DryRun] Inno Setup compiler:", result.stdout)
        self.assertIn("/DAppVersion=0.1.0", result.stdout)
        self.assertIn("Veritra-Setup-0.1.0-x64.exe", result.stdout)

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

            result = self.run_ps(
                "-AppDir",
                str(app_dir),
                "-AppVersion",
                version,
                "-OutDir",
                str(out_dir),
                "-IsccPath",
                str(mock_iscc),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(target_installer.exists())

            sums_file = out_dir / "SHA256SUMS"
            self.assertTrue(sums_file.exists())
            content = sums_file.read_text(encoding="ascii").strip()
            expected_hash = hashlib.sha256(target_installer.read_bytes()).hexdigest().lower()
            self.assertEqual(content, f"{expected_hash}  Veritra-Setup-{version}-x64.exe")
            self.assertIn(f"SHA256: {expected_hash}", result.stdout)


if __name__ == "__main__":
    unittest.main()
