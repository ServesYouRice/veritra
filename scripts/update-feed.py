#!/usr/bin/env python3
"""Owner tool for the Windows update feed (W12, docs/release-engineering.md).

  update-feed.py keygen --out update-key.pem
  update-feed.py sign   --key update-key.pem --installer Veritra-Setup-0.2.0-x64.exe \\
                        --version 0.2.0 --build 2 --url https://.../Veritra-Setup-0.2.0-x64.exe \\
                        --out-dir feed [--notes TEXT] [--valid-days 30]
  update-feed.py verify --pub HEX_OR_FILE --json feed/update.json --sig feed/update.json.sig

The feed is `update.json` plus a detached Ed25519 signature `update.json.sig`
(64 raw bytes) over `veritra-update-feed-v1` followed by the exact bytes of
`update.json`. The signing key is the
update key, never the Windows code-signing certificate. Sign the finished,
Authenticode-signed installer: `sign` records its SHA-256.

Uses the `openssl` command line (3.0 or newer, Ed25519 raw signing) and no
Python package. The private key stays where `--out` puts it (mode 0600) and is
never printed. The app trusts only the public key compiled into
mobile/lib/desktop/update_trust.dart.
"""

from __future__ import annotations

import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# Prepended to the feed bytes before signing and checking, the way the native
# library prepends its own domains (`domain | message`, crypto/rust c7). It keeps
# a signature made for the feed from being valid for anything else the key
# could sign, and the other way round. The app's verifier must use it too.
DOMAIN = b"veritra-update-feed-v1"
# DER prefix of an Ed25519 SubjectPublicKeyInfo; the 32-byte key follows.
SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")
VERSION = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
MAX_VALID_DAYS = 90
MAX_FEED_BYTES = 64 * 1024  # the app's maxUpdateFeedBytes
FIELDS = ("version", "build", "platform", "arch", "issued_at", "expires_at", "url", "sha256", "notes")


class FeedError(Exception):
    pass


def openssl(*args: str) -> bytes:
    try:
        proc = subprocess.run(["openssl", *args], capture_output=True, check=False)
    except FileNotFoundError as exc:
        raise FeedError("openssl is not installed") from exc
    if proc.returncode != 0:
        lines = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise FeedError("openssl failed" + (f": {lines[-1]}" if lines else ""))
    return proc.stdout


def public_key_hex(private_pem: Path) -> str:
    der = openssl("pkey", "-in", str(private_pem), "-pubout", "-outform", "DER")
    if len(der) != len(SPKI_PREFIX) + 32 or not der.startswith(SPKI_PREFIX):
        raise FeedError(f"{private_pem} is not an Ed25519 key")
    return der[len(SPKI_PREFIX):].hex()


def public_pem_from_hex(hex_key: str) -> bytes:
    if not HEX64.match(hex_key):
        raise FeedError("the public key must be 64 lowercase hex characters")
    body = base64.b64encode(SPKI_PREFIX + bytes.fromhex(hex_key)).decode()
    return f"-----BEGIN PUBLIC KEY-----\n{body}\n-----END PUBLIC KEY-----\n".encode()


def verify_signature(pub_hex: str, feed: bytes, signature: bytes) -> bool:
    message = DOMAIN + feed
    if len(signature) != 64:
        return False
    with tempfile.TemporaryDirectory() as temp:
        pub, msg, sig = (Path(temp) / name for name in ("pub.pem", "msg", "sig"))
        pub.write_bytes(public_pem_from_hex(pub_hex))
        msg.write_bytes(message)
        sig.write_bytes(signature)
        proc = subprocess.run(
            ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(pub), "-rawin", "-in", str(msg), "-sigfile", str(sig)],
            capture_output=True,
            check=False,
        )
        return proc.returncode == 0


def keygen(out: Path) -> None:
    if out.exists():
        raise FeedError(f"{out} already exists; it is not overwritten")
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(fd)
    try:
        openssl("genpkey", "-algorithm", "ED25519", "-out", str(out))
        out.chmod(0o600)
        key = public_key_hex(out)
    except Exception:
        out.unlink(missing_ok=True)
        raise
    print(f"private key written to {out} (keep it offline and back it up; it is never printed)")
    print("public key, for updateFeedPublicKeyHex in mobile/lib/desktop/update_trust.dart:")
    print(key)


def utc(text: str | None) -> datetime.datetime:
    if text is None:
        return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    parsed = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise FeedError("--now needs a time zone")
    return parsed.astimezone(datetime.timezone.utc)


def build_feed(args: argparse.Namespace) -> bytes:
    if not VERSION.match(args.version):
        raise FeedError("--version must be a plain version such as 0.2.0")
    if args.build < 1:
        raise FeedError("--build must be 1 or more")
    if not (1 <= args.valid_days <= MAX_VALID_DAYS):
        raise FeedError(f"--valid-days must be 1 to {MAX_VALID_DAYS}: a feed that never expires could be replayed for ever")
    url = args.url
    if not re.match(r"^https://[^/\s]+/\S*$", url):
        raise FeedError("--url must be https with a host")
    installer = Path(args.installer)
    if not installer.is_file() or installer.stat().st_size == 0:
        raise FeedError(f"installer not found or empty: {installer}")
    digest = hashlib.sha256()
    with installer.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    issued = utc(args.now)
    expires = issued + datetime.timedelta(days=args.valid_days)
    notes = Path(args.notes_file).read_text(encoding="utf-8") if args.notes_file else args.notes
    feed = {
        "version": args.version,
        "build": args.build,
        "platform": args.platform,
        "arch": args.arch,
        "issued_at": issued.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expires_at": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "url": url,
        "sha256": digest.hexdigest(),
        "notes": notes,
    }
    assert tuple(feed) == FIELDS
    data = (json.dumps(feed, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    if len(data) > MAX_FEED_BYTES:
        raise FeedError("the feed is larger than the app accepts; shorten --notes")
    return data


def sign(args: argparse.Namespace) -> None:
    key = Path(args.key)
    data = build_feed(args)
    pub = public_key_hex(key)
    with tempfile.TemporaryDirectory() as temp:
        msg = Path(temp) / "update.json"
        msg.write_bytes(DOMAIN + data)
        signature = openssl("pkeyutl", "-sign", "-inkey", str(key), "-rawin", "-in", str(msg))
    if not verify_signature(pub, data, signature):
        raise FeedError("the new signature does not verify; nothing was written")
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "update.json").write_bytes(data)
    (out / "update.json.sig").write_bytes(signature)
    print(f"wrote {out / 'update.json'} and {out / 'update.json.sig'}")
    print(f"signed with the key whose public half is {pub}")
    print("publish both files next to the release, then check them with: update-feed.py verify")


def verify(args: argparse.Namespace) -> None:
    pub = args.pub
    if not HEX64.match(pub):
        try:
            pub = Path(pub).read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise FeedError(f"--pub is neither 64 hex characters nor a readable file: {exc}") from exc
    data = Path(args.json).read_bytes()
    if len(data) > MAX_FEED_BYTES:
        raise FeedError("the feed is larger than the app accepts")
    if not verify_signature(pub, data, Path(args.sig).read_bytes()):
        raise FeedError("the signature does not verify")
    feed = json.loads(data)
    if not isinstance(feed, dict) or tuple(feed) != FIELDS:
        raise FeedError("the feed does not have exactly the fields the app reads")
    print(f"signature ok; version {feed['version']} build {feed['build']}, expires {feed['expires_at']}")


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    k = sub.add_parser("keygen")
    k.add_argument("--out", required=True)
    s = sub.add_parser("sign")
    s.add_argument("--key", required=True)
    s.add_argument("--installer", required=True)
    s.add_argument("--version", required=True)
    s.add_argument("--build", required=True, type=int)
    s.add_argument("--url", required=True)
    s.add_argument("--out-dir", required=True)
    s.add_argument("--notes", default="")
    s.add_argument("--notes-file")
    s.add_argument("--valid-days", type=int, default=30)
    s.add_argument("--platform", default="windows")
    s.add_argument("--arch", default="x64")
    s.add_argument("--now", help="ISO time with zone; for reproducible test fixtures only")
    v = sub.add_parser("verify")
    v.add_argument("--pub", required=True)
    v.add_argument("--json", required=True)
    v.add_argument("--sig", required=True)
    return p


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "keygen":
            keygen(Path(args.out))
        elif args.command == "sign":
            sign(args)
        else:
            verify(args)
    except FeedError as exc:
        print(f"update-feed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
