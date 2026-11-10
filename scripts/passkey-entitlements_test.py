#!/usr/bin/env python3
"""Fixtures for passkey-entitlements.py: the key appears only for a non-empty list."""

import os
import plistlib
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "passkey-entitlements.py")
REAL = os.path.join(HERE, "..", "mobile", "ios", "Runner", "Runner.entitlements")
KEY = "com.apple.developer.associated-domains"


def run(domains, path):
    return subprocess.run([sys.executable, SCRIPT, domains, path], capture_output=True, text=True)


class PasskeyEntitlementsTest(unittest.TestCase):
    def copy(self):
        handle, path = tempfile.mkstemp(suffix=".entitlements")
        os.close(handle)
        with open(REAL, "rb") as src, open(path, "wb") as dst:
            dst.write(src.read())
        self.addCleanup(os.unlink, path)
        return path

    def load(self, path):
        with open(path, "rb") as handle:
            return plistlib.load(handle)

    def test_checked_in_file_has_no_key(self):
        self.assertNotIn(KEY, self.load(REAL))

    def test_empty_list_leaves_no_key(self):
        path = self.copy()
        for raw in ("", " , ,"):
            result = run(raw, path)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(KEY, self.load(path))
        self.assertIn("aps-environment", self.load(path))

    def test_domains_are_written_once(self):
        path = self.copy()
        self.assertEqual(run("Chat.Example.org, chat.example.org,b.example.net", path).returncode, 0)
        self.assertEqual(
            self.load(path)[KEY],
            ["webcredentials:chat.example.org", "webcredentials:b.example.net"],
        )
        self.assertEqual(run("c.example.org", path).returncode, 0)
        self.assertEqual(self.load(path)[KEY], ["webcredentials:c.example.org"])
        self.assertEqual(run("", path).returncode, 0)
        self.assertNotIn(KEY, self.load(path))

    def test_bad_hostnames_are_refused_and_nothing_is_written(self):
        path = self.copy()
        before = self.load(path)
        for bad in ("localhost", "https://a.example.org", "a.example.org:8443",
                    "*.example.org", "10.0.0.1", "a.example.org/x"):
            result = run(bad, path)
            self.assertEqual(result.returncode, 1, bad)
            self.assertEqual(self.load(path), before, bad)


if __name__ == "__main__":
    unittest.main()
