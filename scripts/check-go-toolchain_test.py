#!/usr/bin/env python3
"""Tests for the opt-in golang image digest verification in check-go-toolchain.sh.

A stub docker first on PATH stands in for `docker buildx imagetools inspect`,
so no case reaches the network. The real script runs against the real
repository files. POSIX only (the check is sh).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
SCRIPT = SCRIPTS / "check-go-toolchain.sh"
GO_VERSION = (ROOT / ".go-version").read_text(encoding="utf-8").strip()
PINNED = re.search(
    r"^FROM .*golang:\$\{GO_VERSION\}@(sha256:[0-9a-f]{64}) AS build$",
    (ROOT / "server/Dockerfile").read_text(encoding="utf-8"),
    re.MULTILINE,
).group(1)
OTHER = "sha256:" + "1" * 64
ANOTHER = "sha256:" + "2" * 64

DOCKER_STUB = """#!/bin/sh
printf '%s\\n' "$*" >> "$STUB_LOG"
case ${STUB_DOCKER_MODE:-json} in
  fail) echo "docker stub: registry unreachable" >&2; exit 1 ;;
  json) cat "$STUB_DOCKER_JSON" ;;
esac
"""


def index(digest: str, *manifests: dict[str, object]) -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "digest": digest,
        "size": 10208,
        "manifests": list(manifests),
    }


def platform(digest: str, arch: str = "amd64") -> dict[str, object]:
    return {
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "digest": digest,
        "size": 2324,
        "platform": {"architecture": arch, "os": "linux"},
    }


def attestation(digest: str) -> dict[str, object]:
    return {
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "digest": digest,
        "size": 840,
        "annotations": {"vnd.docker.reference.type": "attestation-manifest"},
        "platform": {"architecture": "unknown", "os": "unknown"},
    }


class Stub:
    def __init__(self, temp: Path) -> None:
        self.temp = temp
        self.bin = temp / "bin"
        self.bin.mkdir()
        docker = self.bin / "docker"
        docker.write_text(DOCKER_STUB, encoding="utf-8")
        docker.chmod(docker.stat().st_mode | stat.S_IXUSR)
        self.log = temp / "docker.log"
        self.json = temp / "manifest.json"

    def run(
        self,
        verify: str | None,
        manifest: object = None,
        mode: str = "json",
        path: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        self.log.write_text("", encoding="utf-8")
        self.json.write_text(manifest if isinstance(manifest, str) else json.dumps(manifest), encoding="utf-8")
        env = {key: value for key, value in os.environ.items() if key != "VERITRA_VERIFY_GO_IMAGE_DIGEST"}
        env.update(
            {
                "PATH": path or f"{self.bin}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
                "STUB_LOG": str(self.log),
                "STUB_DOCKER_JSON": str(self.json),
                "STUB_DOCKER_MODE": mode,
            }
        )
        if verify is not None:
            env["VERITRA_VERIFY_GO_IMAGE_DIGEST"] = verify
        return subprocess.run(["/bin/sh", str(SCRIPT)], env=env, capture_output=True, text=True, check=False)

    def calls(self) -> list[str]:
        return self.log.read_text(encoding="utf-8").splitlines()


def with_stub(test):
    def wrapper() -> None:
        with tempfile.TemporaryDirectory() as temp:
            test(Stub(Path(temp)))

    wrapper.__name__ = test.__name__
    return wrapper


@with_stub
def test_offline_by_default(stub: Stub) -> None:
    for verify in (None, "", "0"):
        result = stub.run(verify, index(OTHER))
        assert result.returncode == 0, (verify, result.stderr)
        assert stub.calls() == [], (verify, "docker was called without opting in")


@with_stub
def test_matching_digest_passes(stub: Stub) -> None:
    result = stub.run("1", index(PINNED, platform(OTHER), platform(ANOTHER, "arm64")))
    assert result.returncode == 0, result.stderr
    assert stub.calls() == [f"buildx imagetools inspect golang:{GO_VERSION} --format {{{{json .Manifest}}}}"], stub.calls()
    # A platform manifest of the tag's index is also golang:$GO_VERSION.
    result = stub.run("1", index(OTHER, platform(ANOTHER, "arm64"), platform(PINNED)))
    assert result.returncode == 0, result.stderr


@with_stub
def test_stale_digest_fails(stub: Stub) -> None:
    result = stub.run("1", index(OTHER, platform(ANOTHER)))
    assert result.returncode != 0, result.stdout
    assert "Go image drift" in result.stderr, result.stderr
    # An attestation manifest is not a runnable image of the tag.
    result = stub.run("1", index(OTHER, platform(ANOTHER), attestation(PINNED)))
    assert result.returncode != 0, result.stdout


@with_stub
def test_inspection_failures_fail_closed(stub: Stub) -> None:
    assert stub.run("1", mode="fail").returncode != 0
    assert stub.run("1", "not json").returncode != 0
    assert stub.run("1", {"manifests": [platform(PINNED)]}).returncode != 0
    assert stub.run("1", index("sha256:short", platform(PINNED))).returncode != 0
    assert stub.run("1", index(OTHER, {"digest": 7})).returncode != 0
    assert stub.run("1", ["not", "an", "object"]).returncode != 0


@with_stub
def test_missing_docker_fails_closed(stub: Stub) -> None:
    tools = stub.temp / "tools"
    tools.mkdir()
    for tool in ("dirname", "tr", "sed", "head", "grep", "sort", "python3"):
        found = shutil.which(tool)
        assert found, tool
        os.symlink(found, tools / tool)
    # The offline checks still pass with this PATH ...
    assert stub.run(None, path=str(tools)).returncode == 0
    # ... and verification without docker fails.
    result = stub.run("1", path=str(tools))
    assert result.returncode != 0, result.stdout
    assert "docker" in result.stderr, result.stderr


@with_stub
def test_unknown_switch_value_fails(stub: Stub) -> None:
    for verify in ("yes", "true", "2"):
        result = stub.run(verify, index(PINNED))
        assert result.returncode != 0, verify
        assert stub.calls() == [], verify


if __name__ == "__main__":
    failures = 0
    for test in (
        test_offline_by_default,
        test_matching_digest_passes,
        test_stale_digest_fails,
        test_inspection_failures_fail_closed,
        test_missing_docker_fails_closed,
        test_unknown_switch_value_fails,
    ):
        try:
            test()
        except AssertionError as exc:
            failures += 1
            print(f"FAIL {test.__name__}: {exc}", file=sys.stderr)
    if failures:
        raise SystemExit(1)
    print("Go toolchain digest verification tests passed")
