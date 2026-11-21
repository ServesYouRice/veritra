#!/usr/bin/env python3
"""Tests for scripts/g24-matrix.py with an adb and an apksigner shim.

They prove the preflight refuses (unpinned or wrong signer, a changed APK, a
commit that is not the frozen one, messaging switched off, not exactly two
phones), and that no device serial reaches the record, the output or a note.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
REPO = SCRIPTS.parent


def load_module(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


g24 = load_module("g24_matrix", "g24-matrix.py")
rc = load_module("release_rc", "release-rc.py")

SERIALS = ("R58M12ABCDEF", "ZY22XCAFEBABE0")
PIN = "a" * 64


def executable(path: Path, body: str) -> None:
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class G24Test(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.root = base / "repo"
        for relative, text in (
            ("crypto/rust/src/lib.rs", "// production crypto wired\n"),
            ("mobile/lib/main.dart", "// production crypto wired\n"),
            ("release/release-policy.json", json.dumps({"android": {"release_certificate_sha256": PIN}})),
        ):
            (self.root / relative).parent.mkdir(parents=True, exist_ok=True)
            (self.root / relative).write_text(text)
        self.git("init", "-q")
        self.commit("candidate")
        self.candidate = self.git("rev-parse", "HEAD")
        self.apk = base / "veritra.apk"
        self.apk.write_bytes(b"signed apk bytes")
        self.bin = base / "bin"
        self.bin.mkdir()
        self.calls = base / "adb-calls.txt"
        self.set_devices(SERIALS)
        executable(self.bin / "apksigner", 'echo "Signer #1 certificate SHA-256 digest: ${G24_SIGNER:-' + PIN + '}"\n')
        self.env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "G24_CALLS": str(self.calls)}
        self.saved_env = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)
        self.addCleanup(self.restore_env)
        g24.ROOT, g24.RECORD, g24.POLICY = self.root, self.root / "testing/evidence/G24-matrix.json", self.root / "release/release-policy.json"

    def restore_env(self) -> None:
        for key, value in self.saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        os.environ.pop("G24_SIGNER", None)

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True, check=True,
                              env={**os.environ, "GIT_CONFIG_GLOBAL": os.devnull}).stdout.strip()

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", message)

    def set_devices(self, serials, sdk: str = "34", state: str = "device") -> None:
        lines = "".join(f"printf '%s\\t{state}\\n' '{s}'\n" for s in serials)
        executable(
            self.bin / "adb",
            f'echo "$@" >> "$G24_CALLS"\n'
            'if [ "$1" = devices ]; then\n  echo "List of devices attached"\n  ' + lines.replace("\n", "\n  ") + '\n  exit 0\nfi\n'
            'shift 2\n'
            'case "$*" in\n'
            '  "shell getprop ro.build.version.release") echo 14 ;;\n'
            f'  "shell getprop ro.build.version.sdk") echo {sdk} ;;\n'
            '  "shell getprop ro.product.cpu.abi") echo arm64-v8a ;;\n'
            '  install*) echo Success ;;\n'
            '  "shell pm list packages "*) echo package:org.veritra.private_messenger ;;\n'
            '  *) exit 1 ;;\n'
            'esac\n',
        )

    def run_cli(self, *args: str) -> tuple[int, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = g24.main(list(args))
            except SystemExit as exit_:
                code = int(exit_.code or 0)
        return code, out.getvalue() + err.getvalue()

    def init(self) -> None:
        code, out = self.run_cli("init", "--android-apk", str(self.apk))
        self.assertEqual(code, 0, out)

    def everything_text(self, output: str) -> str:
        record = g24.RECORD.read_text() if g24.RECORD.exists() else ""
        return output + record

    def assertNoSerials(self, text: str) -> None:
        for serial in SERIALS:
            self.assertNotIn(serial, text)

    # --- init -----------------------------------------------------------

    def test_init_records_the_commit_and_the_apk_digest_and_is_not_overwritten(self) -> None:
        self.init()
        data = json.loads(g24.RECORD.read_text())
        self.assertEqual(data["candidate_commit"], self.candidate)
        self.assertEqual(len(data["artifacts"]["android"]["sha256"]), 64)
        self.assertEqual(data["artifacts"]["android"]["file"], "veritra.apk")
        self.assertEqual(self.run_cli("init", "--android-apk", str(self.apk))[0], 1)
        self.assertEqual(self.run_cli("init", "--out", str(self.root / "x.json"))[0], 1)
        self.assertEqual(self.run_cli("init", "--android-apk", str(self.apk), "--commit", "abc", "--out", str(self.root / "y.json"))[0], 1)

    # --- preflight ------------------------------------------------------

    def test_preflight_passes_and_never_writes_or_prints_a_serial(self) -> None:
        self.init()
        code, out = self.run_cli("preflight", "--android-apk", str(self.apk), "--write")
        self.assertEqual(code, 0, out)
        self.assertIn("D1 Android 14", out)
        self.assertNoSerials(self.everything_text(out))
        data = json.loads(g24.RECORD.read_text())
        self.assertEqual(data["platforms"]["android"]["devices"], [
            {"label": "D1", "os": "14", "sdk": 34, "abi": "arm64-v8a"},
            {"label": "D2", "os": "14", "sdk": 34, "abi": "arm64-v8a"},
        ])

    def refused(self, needle: str, *extra: str) -> None:
        code, out = self.run_cli("preflight", "--android-apk", str(self.apk), *extra)
        self.assertEqual(code, 1, out)
        self.assertIn(needle, out)
        self.assertIn("preflight FAILED", out)
        self.assertNoSerials(out)

    def test_preflight_refuses_an_unpinned_or_other_signer(self) -> None:
        self.init()
        g24.POLICY.write_text(json.dumps({"android": {"release_certificate_sha256": None}}))
        self.refused("is not pinned")
        g24.POLICY.write_text(json.dumps({"android": {"release_certificate_sha256": PIN}}))
        os.environ["G24_SIGNER"] = "b" * 64
        self.refused("other than the pinned one")

    def test_preflight_refuses_a_changed_apk(self) -> None:
        self.init()
        self.apk.write_bytes(b"another build")
        self.refused("differs from the one recorded")

    def test_preflight_refuses_when_messaging_is_switched_off(self) -> None:
        (self.root / "crypto/rust/src/lib.rs").write_text("pub const PM_CRYPTO_UNAVAILABLE: i32 = 1;\n")
        self.commit("gate still closed")
        data_commit = self.git("rev-parse", "HEAD")
        code, out = self.run_cli("init", "--android-apk", str(self.apk), "--commit", data_commit)
        self.assertEqual(code, 0, out)
        self.refused("messaging is switched off")

    def test_preflight_refuses_a_commit_that_is_not_the_frozen_one_or_a_dirty_tree(self) -> None:
        self.init()
        (self.root / "mobile/lib/main.dart").write_text("// edited\n")
        self.refused("uncommitted changes")
        self.commit("later")
        self.refused("check out the frozen candidate")

    def test_preflight_needs_exactly_two_authorized_phones_on_a_supported_android(self) -> None:
        self.init()
        self.set_devices(SERIALS[:1])
        self.refused("exactly 2 are needed")
        self.set_devices(SERIALS + ("EXTRA00000000",))
        self.refused("exactly 2 are needed")
        self.set_devices(SERIALS, state="unauthorized")
        self.refused("exactly 2 are needed")
        self.set_devices(SERIALS, sdk="23")
        self.refused("needs 24 or later")

    def test_an_adb_failure_does_not_echo_the_serial(self) -> None:
        self.init()
        executable(self.bin / "adb", f'echo "error: device \'{SERIALS[0]}\' not found" >&2\nexit 1\n')
        code, out = self.run_cli("install", "--android-apk", str(self.apk))
        self.assertEqual(code, 1)
        self.assertNoSerials(out)

    # --- install ----------------------------------------------------------

    def test_install_puts_the_build_on_both_phones_without_naming_them(self) -> None:
        self.init()
        code, out = self.run_cli("install", "--android-apk", str(self.apk))
        self.assertEqual(code, 0, out)
        self.assertIn("installed on D1", out)
        self.assertIn("installed on D2", out)
        self.assertNoSerials(self.everything_text(out))
        self.assertEqual(self.calls.read_text().count("install -r"), 2)

    def test_install_does_nothing_when_the_preflight_fails(self) -> None:
        self.init()
        g24.POLICY.write_text(json.dumps({"android": {"release_certificate_sha256": None}}))
        code, out = self.run_cli("install", "--android-apk", str(self.apk))
        self.assertEqual(code, 1, out)
        self.assertNotIn("install -r", self.calls.read_text())

    # --- record and status --------------------------------------------------

    def test_notes_that_look_like_identifiers_are_refused(self) -> None:
        self.init()
        for note in (SERIALS[0], f"push late on {SERIALS[1]}", "imei 356938035643809", "alice@example.com", "0123456789abcdef0123", "x" * 301):
            code, out = self.run_cli("record", "--platform", "android", "--row", "push-wake", "--result", "fail", "--note", note)
            self.assertEqual(code, 1, (note, out))
        self.assertEqual(json.loads(g24.RECORD.read_text())["platforms"]["android"]["rows"][5]["result"], "pending")
        code, out = self.run_cli("record", "--platform", "android", "--row", "push-wake", "--result", "fail", "--note", "arrived after 4 minutes")
        self.assertEqual(code, 0, out)

    def test_unknown_row_and_a_corrupted_record_are_refused(self) -> None:
        self.init()
        self.assertEqual(self.run_cli("record", "--platform", "android", "--row", "nope", "--result", "pass")[0], 1)
        data = json.loads(g24.RECORD.read_text())
        data["platforms"]["ios"]["rows"][0]["result"] = "maybe"
        g24.RECORD.write_text(json.dumps(data))
        self.assertEqual(self.run_cli("status")[0], 1)

    def test_status_is_complete_only_when_every_row_passes_on_two_devices_per_platform(self) -> None:
        self.init()
        self.assertEqual(self.run_cli("status")[0], 1)
        self.assertEqual(self.run_cli("preflight", "--android-apk", str(self.apk), "--write")[0], 0)
        for platform in ("android", "ios"):
            for row in g24.ROWS:
                self.assertEqual(self.run_cli("record", "--platform", platform, "--row", row["id"], "--result", "pass")[0], 0)
        code, out = self.run_cli("status")
        self.assertEqual(code, 1, out)  # iOS devices are not recorded yet
        self.assertIn("two devices (D1, D2) are not recorded yet", out)
        for label in ("D1", "D2"):
            self.assertEqual(self.run_cli("device", "--platform", "ios", "--label", label, "--os", "17.5")[0], 0)
        code, out = self.run_cli("status")
        self.assertEqual(code, 0, out)
        self.assertIn("COMPLETE", out)
        # one failure anywhere makes it incomplete again
        self.assertEqual(self.run_cli("record", "--platform", "ios", "--row", "accessibility", "--result", "fail")[0], 0)
        self.assertEqual(self.run_cli("status")[0], 1)

    def test_release_rc_reads_the_same_record(self) -> None:
        self.init()
        (self.root / "testing/evidence").mkdir(parents=True, exist_ok=True)
        self.assertEqual(rc.g24_state(self.root)[0], rc.MISSING)
        data = json.loads(g24.RECORD.read_text())
        for platform in g24.PLATFORMS:
            for row in data["platforms"][platform]["rows"]:
                row["result"] = "pass"
        g24.RECORD.write_text(json.dumps(data))
        self.assertEqual(rc.g24_state(self.root)[0], rc.DONE)
        data["platforms"]["android"]["rows"][3]["result"] = "fail"
        g24.RECORD.write_text(json.dumps(data))
        self.assertEqual(rc.g24_state(self.root)[0], rc.MISSING)

    # --- checklist ------------------------------------------------------------

    def test_checklist_covers_every_row_with_steps(self) -> None:
        code, out = self.run_cli("checklist", "--platform", "ios")
        self.assertEqual(code, 0)
        for number, row in enumerate(g24.ROWS, 1):
            self.assertIn(f"{number}. {row['name']}", out)
            self.assertTrue(len(row["steps"]) >= 3)

    def test_rows_match_the_matrix_in_security_review(self) -> None:
        text = (REPO / "docs" / "security-review.md").read_text(encoding="utf-8")
        table = text.split("| Real-device flow | Android | iOS |")[1].split("\n\n")[0]
        names = [line.split("|")[1].strip() for line in table.splitlines()[2:] if line.startswith("|")]
        self.assertEqual(names, [row["name"] for row in g24.ROWS])
        self.assertEqual(len({row["id"] for row in g24.ROWS}), len(g24.ROWS))


if __name__ == "__main__":
    unittest.main()
