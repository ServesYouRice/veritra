#!/usr/bin/env python3
"""Tests for scripts/update-feed.py and its committed test vector."""

from __future__ import annotations

import datetime
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
TOOL = SCRIPTS / "update-feed.py"
FIXTURE = SCRIPTS.parent / "mobile" / "test" / "fixtures" / "update-feed"
FIELDS = ["version", "build", "platform", "arch", "issued_at", "expires_at", "url", "sha256", "notes"]


def openssl_ok() -> bool:
    if shutil.which("openssl") is None:
        return False
    out = subprocess.run(["openssl", "version"], capture_output=True, text=True, check=False).stdout
    match = re.match(r"OpenSSL (\d+)\.", out)
    return bool(match and int(match.group(1)) >= 3)


def tool(*args: str):
    return subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True, check=False)


@unittest.skipUnless(openssl_ok(), "OpenSSL 3 is not available")
class UpdateFeedTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.installer = self.dir / "Veritra-Setup-0.2.0-x64.exe"
        self.installer.write_bytes(b"installer bytes")
        self.key = self.dir / "update-key.pem"
        result = tool("keygen", "--out", str(self.key))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.pub = result.stdout.strip().splitlines()[-1]
        self.assertRegex(self.pub, r"^[0-9a-f]{64}$")
        self.out_dir = self.dir / "feed"

    def sign(self, *extra: str, **override: str):
        args = {
            "--key": str(self.key),
            "--installer": str(self.installer),
            "--version": "0.2.0",
            "--build": "2",
            "--url": "https://example.com/Veritra-Setup-0.2.0-x64.exe",
            "--out-dir": str(self.out_dir),
        }
        args.update(override)
        flat = [item for pair in args.items() for item in pair]
        return tool("sign", *flat, *extra)

    def verify(self, pub: str | None = None):
        return tool("verify", "--pub", pub or self.pub, "--json", str(self.out_dir / "update.json"), "--sig", str(self.out_dir / "update.json.sig"))

    def test_keygen_protects_and_never_prints_the_private_key(self) -> None:
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)
        result = tool("keygen", "--out", str(self.dir / "second.pem"))
        self.assertNotIn("PRIVATE", result.stdout + result.stderr)
        again = tool("keygen", "--out", str(self.key))
        self.assertEqual(again.returncode, 1)
        self.assertIn("not overwritten", again.stderr)

    def test_sign_then_verify_and_the_feed_has_the_app_fields(self) -> None:
        result = self.sign("--notes", "Fixes", "--now", "2026-11-21T00:00:00Z")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.verify().returncode, 0)
        feed = json.loads((self.out_dir / "update.json").read_text())
        self.assertEqual(list(feed), FIELDS)
        self.assertEqual(len((self.out_dir / "update.json.sig").read_bytes()), 64)
        self.assertRegex(feed["sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(feed["issued_at"], "2026-11-21T00:00:00Z")
        self.assertEqual(feed["expires_at"], "2026-12-21T00:00:00Z")
        self.assertTrue(feed["url"].startswith("https://"))

    def test_any_change_to_the_feed_or_signature_or_key_is_rejected(self) -> None:
        self.sign()
        feed_path, sig_path = self.out_dir / "update.json", self.out_dir / "update.json.sig"
        original, signature = feed_path.read_bytes(), sig_path.read_bytes()
        feed_path.write_bytes(original.replace(b"0.2.0", b"9.9.9", 1))
        self.assertEqual(self.verify().returncode, 1)
        feed_path.write_bytes(original)
        sig_path.write_bytes(bytes([signature[0] ^ 1]) + signature[1:])
        self.assertEqual(self.verify().returncode, 1)
        sig_path.write_bytes(signature[:63])
        self.assertEqual(self.verify().returncode, 1)
        sig_path.write_bytes(signature)
        self.assertEqual(self.verify().returncode, 0)
        other = tool("keygen", "--out", str(self.dir / "other.pem")).stdout.strip().splitlines()[-1]
        self.assertEqual(self.verify(other).returncode, 1)

    def test_signature_is_over_the_domain_and_the_feed(self) -> None:
        self.sign()
        feed = (self.out_dir / "update.json").read_bytes()
        raw = self.dir / "raw-feed"
        raw.write_bytes(feed)
        # A signature over the bare feed bytes (no domain) must not verify.
        bare = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(self.key), "-rawin", "-in", str(raw)], capture_output=True, check=True).stdout
        (self.out_dir / "update.json.sig").write_bytes(bare)
        self.assertEqual(self.verify().returncode, 1)
        # And the domain-prefixed one is what sign wrote.
        domain = self.dir / "domain-feed"
        domain.write_bytes(b"veritra-update-feed-v1" + feed)
        good = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(self.key), "-rawin", "-in", str(domain)], capture_output=True, check=True).stdout
        (self.out_dir / "update.json.sig").write_bytes(good)
        self.assertEqual(self.verify().returncode, 0)

    def test_refuses_what_the_app_would_refuse(self) -> None:
        cases = {
            "http url": {"--url": "http://example.com/x.exe"},
            "no host": {"--url": "https:///x.exe"},
            "bad version": {"--version": "../evil"},
            "build 0": {"--build": "0"},
            "missing installer": {"--installer": str(self.dir / "nope.exe")},
            "missing key": {"--key": str(self.dir / "nope.pem")},
        }
        for name, override in cases.items():
            result = self.sign(**override)
            self.assertEqual(result.returncode, 1, (name, result.stdout))
            self.assertFalse((self.out_dir / "update.json").exists(), name)
        for days in ("0", "91"):
            self.assertEqual(self.sign("--valid-days", days).returncode, 1, days)
        (self.dir / "empty.exe").write_bytes(b"")
        self.assertEqual(self.sign(**{"--installer": str(self.dir / "empty.exe")}).returncode, 1)


@unittest.skipUnless(openssl_ok(), "OpenSSL 3 is not available")
class CommittedVectorTest(unittest.TestCase):
    """The vector the Dart tests parse and the future verifier must accept."""

    def test_vector_signature_verifies_and_matches_the_dart_rules(self) -> None:
        pub = (FIXTURE / "public-key.hex").read_text().strip()
        result = tool("verify", "--pub", pub, "--json", str(FIXTURE / "update.json"), "--sig", str(FIXTURE / "update.json.sig"))
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = json.loads((FIXTURE / "update.json").read_text())
        self.assertEqual(list(feed), FIELDS)
        issued = datetime.datetime.fromisoformat(feed["issued_at"].replace("Z", "+00:00"))
        expires = datetime.datetime.fromisoformat(feed["expires_at"].replace("Z", "+00:00"))
        self.assertLess(issued, expires)
        self.assertRegex(feed["sha256"], r"^[0-9a-f]{64}$")

    def test_vector_is_not_a_real_key(self) -> None:
        trust = (SCRIPTS.parent / "mobile/lib/desktop/update_trust.dart").read_text()
        pub = (FIXTURE / "public-key.hex").read_text().strip()
        self.assertNotIn(pub, trust)
        self.assertEqual(list(FIXTURE.glob("*.pem")), [])


if __name__ == "__main__":
    unittest.main()
