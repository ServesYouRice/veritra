#!/usr/bin/env python3
import json
import sys

metadata = json.load(sys.stdin)
missing_licenses = sorted(
    f'{package["name"]}@{package["version"]}'
    for package in metadata["packages"]
    if not package.get("license")
)
if missing_licenses:
    raise SystemExit("dependencies without declared licenses: " + ", ".join(missing_licenses))
packages = [
    {
        "name": package["name"],
        "version": package["version"],
        "license": package.get("license"),
        "source": package.get("source"),
    }
    for package in metadata["packages"]
]
json.dump(
    {"format_version": 1, "packages": sorted(packages, key=lambda item: (item["name"], item["version"]))},
    sys.stdout,
    indent=2,
    sort_keys=True,
)
sys.stdout.write("\n")
