#!/usr/bin/env python3
"""Tests for scripts/verify-attestation.sh with synthetic SEV-SNP evidence.

A throwaway AMD-shaped chain (RSA-PSS ARK and ASK, EC P-384 VCEK with a hwID
extension) signs reports built here in the SEV-SNP layout. Local HTTPS
servers on 127.0.0.1 answer GET /api/v1/attestation for the script's own
nonce, so the online path, the TLS binding and a relay to a second machine
are all exercised. Nothing here is real hardware: a run on a real
confidential VM is the owner's step (docs/operations.md). POSIX only (the
script needs openssl and curl).
"""

from __future__ import annotations

import posix_shell

import base64
import hashlib
import http.server
import json
import os
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
import urllib.parse
from pathlib import Path

SCRIPT = Path(__file__).resolve().with_name("verify-attestation.sh")
LABEL = b"veritra-attest-v1"
MEASUREMENT = bytes(range(48))
CHIP_ID = bytes((i * 7) & 0xFF for i in range(64))
# Never printed by the script, whatever the outcome (L3 wording rule).
BANNED = ("secure", "trusted", "operator-proof", "zero access", "cannot see")


def openssl(*args: str, cwd: Path) -> None:
    subprocess.run(["openssl", *args], cwd=cwd, check=True, capture_output=True)


def der_signature_to_rs(der: bytes) -> tuple[int, int]:
    assert der[0] == 0x30
    offset = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    values = []
    for _ in range(2):
        assert der[offset] == 0x02
        length = der[offset + 1]
        values.append(int.from_bytes(der[offset + 2 : offset + 2 + length], "big"))
        offset += 2 + length
    return values[0], values[1]


class Fixtures:
    def __init__(self, root: Path) -> None:
        self.root = root
        ext = root / "ext.cnf"
        ext.write_text(
            "[req]\ndistinguished_name=dn\n[dn]\n"
            "[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
            "[vcek]\nbasicConstraints=critical,CA:FALSE\n"
            "1.3.6.1.4.1.3704.1.4=DER:" + ":".join(f"{b:02x}" for b in CHIP_ID) + "\n"
            "[vcek_wrapped]\nbasicConstraints=critical,CA:FALSE\n"
            "1.3.6.1.4.1.3704.1.4=DER:04:40:" + ":".join(f"{b:02x}" for b in CHIP_ID) + "\n"
            "[vcek_other_chip]\nbasicConstraints=critical,CA:FALSE\n"
            "1.3.6.1.4.1.3704.1.4=DER:" + ":".join("ee" for _ in CHIP_ID) + "\n"
            "[tls]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\n",
            encoding="utf-8",
        )
        pss = ["-sigopt", "rsa_padding_mode:pss", "-sigopt", "rsa_pss_saltlen:48", "-sha384"]
        for name in ("ark", "other_ark"):
            openssl("genpkey", "-algorithm", "RSA-PSS", "-pkeyopt", "rsa_keygen_bits:2048",
                    "-out", f"{name}.key", cwd=root)
            openssl("req", "-x509", "-new", "-key", f"{name}.key", "-subj", "/CN=ARK-test",
                    "-days", "2", *pss, "-config", "ext.cnf", "-extensions", "ca",
                    "-out", f"{name}.pem", cwd=root)
        openssl("genpkey", "-algorithm", "RSA-PSS", "-pkeyopt", "rsa_keygen_bits:2048",
                "-out", "ask.key", cwd=root)
        openssl("req", "-new", "-key", "ask.key", "-subj", "/CN=SEV-test", "-config", "ext.cnf",
                "-out", "ask.csr", cwd=root)
        openssl("x509", "-req", "-in", "ask.csr", "-CA", "ark.pem", "-CAkey", "ark.key",
                "-set_serial", "2", "-days", "2", *pss, "-extfile", "ext.cnf",
                "-extensions", "ca", "-out", "ask.pem", cwd=root)
        openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-384",
                "-out", "vcek.key", cwd=root)
        openssl("req", "-new", "-key", "vcek.key", "-subj", "/CN=SEV-VCEK-test",
                "-config", "ext.cnf", "-out", "vcek.csr", cwd=root)
        for serial, (name, section) in enumerate(
            (("vcek", "vcek"), ("vcek_wrapped", "vcek_wrapped"),
             ("vcek_other_chip", "vcek_other_chip")), start=3):
            openssl("x509", "-req", "-in", "vcek.csr", "-CA", "ask.pem", "-CAkey", "ask.key",
                    "-set_serial", str(serial), "-days", "2", *pss, "-extfile", "ext.cnf",
                    "-extensions", section, "-outform", "DER", "-out", f"{name}.der", cwd=root)
        for name in ("tls", "relay_tls"):
            openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-nodes", "-keyout", f"{name}.key", "-subj", "/CN=localhost", "-days", "2",
                    "-config", "ext.cnf", "-extensions", "tls",
                    "-out", f"{name}.pem", cwd=root)
        self.ca = root / "ca.pem"
        self.ca.write_text(
            (root / "tls.pem").read_text() + (root / "relay_tls.pem").read_text(), encoding="utf-8")
        der = subprocess.run(["openssl", "x509", "-in", str(root / "ark.pem"), "-outform", "DER"],
                             check=True, capture_output=True).stdout
        self.ark_sha256 = hashlib.sha256(der).hexdigest()

    def spki_sha256(self, cert: str) -> bytes:
        pub = subprocess.run(["openssl", "x509", "-in", str(self.root / f"{cert}.pem"), "-pubkey", "-noout"],
                             check=True, capture_output=True).stdout
        der = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=pub,
                             check=True, capture_output=True).stdout
        return hashlib.sha256(der).digest()

    def report(self, nonce: bytes, tls_key_hash: bytes, *, policy: int = 0x30000,
               measurement: bytes = MEASUREMENT, corrupt: bool = False) -> bytes:
        body = bytearray(0x4A0)
        body[0:4] = (3).to_bytes(4, "little")
        body[8:16] = policy.to_bytes(8, "little")
        body[0x34:0x38] = (1).to_bytes(4, "little")
        body[0x50:0x90] = hashlib.sha512(LABEL + nonce + tls_key_hash).digest()
        body[0x90:0xC0] = measurement
        body[0x180:0x188] = bytes([3, 0, 0, 0, 0, 0, 8, 115])
        body[0x1A0:0x1E0] = CHIP_ID
        signed = self.root / f"signed-{threading.get_ident()}.bin"
        signed.write_bytes(bytes(body[:0x2A0]))
        der = subprocess.run(["openssl", "dgst", "-sha384", "-sign", str(self.root / "vcek.key"),
                              str(signed)], check=True, capture_output=True).stdout
        r, s = der_signature_to_rs(der)
        body[0x2A0:0x2E8] = r.to_bytes(72, "little")
        body[0x2E8:0x330] = s.to_bytes(72, "little")
        if corrupt:
            body[0x90] ^= 1
        return bytes(body)


class Server:
    """An HTTPS attestation endpoint on 127.0.0.1 with its own TLS key.

    `report_for` is the key hash the report is bound to: its own, or another
    server's (a relay that passes a second machine's report on)."""

    def __init__(self, fixtures: Fixtures, cert: str, *, kind: str = "sev_guest",
                 report_for: str | None = None, **report_args) -> None:
        tls_key_hash = fixtures.spki_sha256(report_for or cert)

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                query = urllib.parse.urlparse(self.path)
                nonce_hex = urllib.parse.parse_qs(query.query).get("nonce", [""])[0]
                if query.path != "/api/v1/attestation" or len(nonce_hex) != 64:
                    self.send_response(400)
                    self.end_headers()
                    return
                report = fixtures.report(bytes.fromhex(nonce_hex), tls_key_hash, **report_args)
                body = json.dumps({
                    "claimed_build": {"version": "1.2.3", "commit": "abc"},
                    "format": "veritra-attest-v1",
                    "kind": kind,
                    "report": base64.b64encode(report).decode(),
                }, separators=(",", ":")).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args) -> None:
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(fixtures.root / f"{cert}.pem", fixtures.root / f"{cert}.key")
        self.httpd.socket = context.wrap_socket(self.httpd.socket, server_side=True)
        self.url = f"https://127.0.0.1:{self.httpd.server_address[1]}"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self) -> "Server":
        self.thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


class VerifyAttestationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = Path(tempfile.mkdtemp(prefix="verify-attestation-"))
        cls.fx = Fixtures(cls.tmp)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_script(self, *extra: str, vcek: str = "vcek.der", ark: str = "ark.pem",
                   ark_sha256: str | None = None,
                   measurement: bytes = MEASUREMENT) -> subprocess.CompletedProcess:
        root = self.fx.root
        args = [posix_shell.find("sh"), str(SCRIPT), "--release", "v1.2.3",
                "--measurement", measurement.hex(), "--ark", str(root / ark),
                "--ark-sha256", ark_sha256 or self.fx.ark_sha256, "--ask", str(root / "ask.pem"),
                "--vcek", str(root / vcek), *extra]
        env = {**os.environ, "LC_ALL": "C"}
        env.pop("HTTPS_PROXY", None)
        env.pop("https_proxy", None)
        result = subprocess.run(args, capture_output=True, text=True, env=env, timeout=120)
        everything = (result.stdout + result.stderr).lower()
        for word in BANNED:
            self.assertNotIn(word, everything, msg=everything)
        return result

    def online(self, server: Server, **kwargs) -> subprocess.CompletedProcess:
        with server:
            return self.run_script("--cacert", str(self.fx.ca), server.url, **kwargs)

    def assert_no_match(self, result: subprocess.CompletedProcess, reason: str) -> None:
        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        last = result.stdout.strip().splitlines()[-1]
        self.assertTrue(last.startswith("does not match: "), msg=last)
        self.assertIn(reason, last)
        self.assertNotIn("matches release", result.stdout)

    def test_a_good_report_matches_the_release(self) -> None:
        result = self.online(Server(self.fx, "tls"))
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip().splitlines()[-1], "matches release v1.2.3")
        self.assertIn("measurement: " + MEASUREMENT.hex(), result.stdout)

    def test_a_vcek_with_a_wrapped_chip_id_matches(self) -> None:
        result = self.online(Server(self.fx, "tls"), vcek="vcek_wrapped.der")
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)

    def test_another_measurement_does_not_match(self) -> None:
        # The changed-image case: the image measured is not the release's.
        self.assert_no_match(self.online(Server(self.fx, "tls"), measurement=bytes(48)),
                             "measurement")

    def test_a_relayed_report_fails_the_tls_binding(self) -> None:
        # The relay holds another TLS key and passes on a report bound to
        # the first machine's key.
        self.assert_no_match(self.online(Server(self.fx, "relay_tls", report_for="tls")),
                             "relayed or replayed")

    def test_a_changed_report_fails_the_signature(self) -> None:
        self.assert_no_match(self.online(Server(self.fx, "tls", corrupt=True)), "signature")

    def test_a_debug_policy_does_not_match(self) -> None:
        self.assert_no_match(self.online(Server(self.fx, "tls", policy=0x30000 | 1 << 19)),
                             "debugging")

    def test_another_root_does_not_match(self) -> None:
        self.assert_no_match(self.online(Server(self.fx, "tls"), ark_sha256="00" * 32),
                             "expected AMD root")
        other = subprocess.run(["openssl", "x509", "-in", str(self.fx.root / "other_ark.pem"),
                                "-outform", "DER"], check=True, capture_output=True).stdout
        self.assert_no_match(
            self.online(Server(self.fx, "tls"), ark="other_ark.pem",
                        ark_sha256=hashlib.sha256(other).hexdigest()),
            "does not chain")

    def test_a_vcek_for_another_chip_does_not_match(self) -> None:
        self.assert_no_match(self.online(Server(self.fx, "tls"), vcek="vcek_other_chip.der"),
                             "chip")

    def test_tdx_is_refused_and_never_matches(self) -> None:
        result = self.online(Server(self.fx, "tls", kind="tdx_guest"))
        self.assertEqual(result.returncode, 3, msg=result.stdout + result.stderr)
        self.assertNotIn("matches", result.stdout)
        self.assertIn("not verified by this script", result.stdout)

    def test_a_recorded_response_is_checked_offline(self) -> None:
        nonce = bytes(range(32))
        report = self.fx.report(nonce, self.fx.spki_sha256("tls"))
        recorded = self.fx.root / "recorded.json"
        recorded.write_text(json.dumps({"format": "veritra-attest-v1", "kind": "sev_guest",
                                        "report": base64.b64encode(report).decode()}))
        common = ("--response", str(recorded), "--tls-cert", str(self.fx.root / "tls.pem"))
        good = self.run_script(*common, "--nonce", nonce.hex())
        self.assertEqual(good.returncode, 0, msg=good.stdout + good.stderr)
        self.assert_no_match(self.run_script(*common, "--nonce", "11" * 32), "relayed or replayed")

    def test_usage_errors_exit_2(self) -> None:
        self.assertEqual(self.run_script("http://127.0.0.1:1").returncode, 2)
        self.assertEqual(self.run_script(measurement=b"\x00" * 47).returncode, 2)
        self.assertEqual(self.run_script().returncode, 2)

    def test_no_server_does_not_match(self) -> None:
        self.assert_no_match(self.run_script("https://127.0.0.1:1"), "no TLS certificate")


if __name__ == "__main__":
    if os.name == "nt":
        print("verify-attestation_test: POSIX only, not run on Windows")
    else:
        unittest.main()
