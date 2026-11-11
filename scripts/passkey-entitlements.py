#!/usr/bin/env python3
"""Adds the associated-domains entitlement for passkeys (B7, S3).

Usage: passkey-entitlements.py DOMAINS ENTITLEMENTS_PLIST

DOMAINS is the value of `--dart-define=VERITRA_PASSKEY_DOMAINS`: hostnames
separated by commas. The key `com.apple.developer.associated-domains` is
written only when the list is not empty. An empty key can still require the
capability in the provisioning profile and break the simulator build, so a
default build carries no such key (docs/designs/B7-passkeys.md, "iOS
entitlements"). Run it before `flutter build ios` or `flutter build macos`
when the build is team-signed.

Each hostname must be a plain DNS name with a dot (no scheme, port, path or
wildcard); anything else is an error. The plist is rewritten in place and an
existing key is replaced, so the script is idempotent.
"""

from __future__ import annotations

import plistlib
import re
import sys

KEY = "com.apple.developer.associated-domains"
HOST = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")


def parse_domains(raw: str) -> list[str]:
    hosts: list[str] = []
    for part in raw.split(","):
        host = part.strip().lower()
        if not host:
            continue
        if not HOST.match(host):
            raise ValueError(f"not a plain hostname: {host!r}")
        if host not in hosts:
            hosts.append(host)
    return hosts


def apply(domains: str, path: str) -> bool:
    """Returns whether the file now carries the key."""
    hosts = parse_domains(domains)
    with open(path, "rb") as handle:
        plist = plistlib.load(handle)
    if hosts:
        plist[KEY] = [f"webcredentials:{host}" for host in hosts]
    else:
        plist.pop(KEY, None)
    with open(path, "wb") as handle:
        plistlib.dump(plist, handle, sort_keys=False)
    return bool(hosts)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        present = apply(argv[1], argv[2])
    except (ValueError, OSError, plistlib.InvalidFileException) as err:
        print(f"passkey-entitlements: {err}", file=sys.stderr)
        return 1
    print("associated domains written" if present else "no passkey domains; unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
