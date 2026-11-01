#!/usr/bin/env python3
"""Tests for the opt-in golang image digest verification in check-go-toolchain.sh.

A stub docker first on PATH stands in for `docker buildx imagetools inspect`
(the image config of the pinned digest), so no case reaches the network. The
real script runs against the real repository files. POSIX only (the check is sh).
"""

from __future__ import annotations

import posix_shell

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

DOCKER_STUB = """#!/bin/sh
printf '%s\\n' "$*" >> "$STUB_LOG"
case ${STUB_DOCKER_MODE:-json} in
  fail) echo "docker stub: registry unreachable" >&2; exit 1 ;;
  json) cat "$STUB_DOCKER_JSON" ;;
esac
"""


def image(version: str | None = GO_VERSION, arch: str = "amd64", env: object = None) -> dict[str, object]:
    if env is None:
        env = ["PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "GOTOOLCHAIN=local", "GOPATH=/go"]
        if version is not None:
            env.insert(1, f"GOLANG_VERSION={version}")
    return {
        "created": "2026-10-01T00:00:00Z",
        "architecture": arch,
        "os": "linux",
        "config": {"Env": env, "Cmd": ["bash"], "WorkingDir": "/go"},
        "rootfs": {"type": "layers", "diff_ids": ["sha256:" + "3" * 64]},
    }


class Stub:
    def __init__(self, temp: Path) -> None:
        self.temp = temp
        self.bin = temp / "bin"
        self.bin.mkdir()
        docker = self.bin / "docker"
        docker.write_text(DOCKER_STUB, encoding="utf-8", newline="\n")
        docker.chmod(docker.stat().st_mode | stat.S_IXUSR)
        self.log = temp / "docker.log"
        self.json = temp / "image.json"

    def run(
        self,
        verify: str | None,
        config: object = None,
        mode: str = "json",
        path: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        self.log.write_text("", encoding="utf-8")
        self.json.write_text(config if isinstance(config, str) else json.dumps(config), encoding="utf-8")
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
        return subprocess.run([posix_shell.find("sh"), str(SCRIPT)], env=env, capture_output=True, text=True, check=False)

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
        result = stub.run(verify, image("0.0.1"))
        assert result.returncode == 0, (verify, result.stderr)
        assert stub.calls() == [], (verify, "docker was called without opting in")


@with_stub
def test_docker_command_line(stub: Stub) -> None:
    result = stub.run("1", image())
    assert result.returncode == 0, result.stderr
    # The pinned digest itself, not whatever golang:$GO_VERSION points to today.
    assert stub.calls() == [f"buildx imagetools inspect golang@{PINNED} --format {{{{json .Image}}}}"], stub.calls()


@with_stub
def test_single_image_passes(stub: Stub) -> None:
    result = stub.run("1", image())
    assert result.returncode == 0, result.stderr
    assert f"verified as Go {GO_VERSION}" in result.stdout, result.stdout


@with_stub
def test_multi_platform_passes(stub: Stub) -> None:
    configs = {
        "linux/amd64": image(),
        "linux/arm64/v8": image(arch="arm64"),
        "windows/amd64": image(arch="amd64"),
    }
    result = stub.run("1", configs)
    assert result.returncode == 0, result.stderr


@with_stub
def test_wrong_version_fails(stub: Stub) -> None:
    result = stub.run("1", image("1.25.9"))
    assert result.returncode != 0, result.stdout
    assert "Go image drift" in result.stderr and "GOLANG_VERSION=1.25.9" in result.stderr, result.stderr
    # A prefix match is not the pinned version.
    assert stub.run("1", image(GO_VERSION + "0")).returncode != 0
    assert stub.run("1", image(GO_VERSION.rsplit(".", 1)[0])).returncode != 0


@with_stub
def test_missing_golang_version_fails(stub: Stub) -> None:
    result = stub.run("1", image(None))
    assert result.returncode != 0, result.stdout
    assert "no GOLANG_VERSION" in result.stderr, result.stderr
    # Missing Env or config entirely.
    no_env = image()
    del no_env["config"]["Env"]
    assert stub.run("1", no_env).returncode != 0
    no_config = image()
    del no_config["config"]
    assert stub.run("1", no_config).returncode != 0
    assert stub.run("1", image(env="GOLANG_VERSION=" + GO_VERSION)).returncode != 0
    assert stub.run("1", {"linux/amd64": image(), "linux/arm64": image(None, "arm64")}).returncode != 0


@with_stub
def test_one_platform_with_other_version_fails(stub: Stub) -> None:
    configs = {"linux/amd64": image(), "linux/arm64": image("1.25.9", "arm64")}
    result = stub.run("1", configs)
    assert result.returncode != 0, result.stdout
    assert "linux/arm64" in result.stderr, result.stderr
    # Two GOLANG_VERSION entries, one of them wrong, is not exactly the pin.
    both = image(env=[f"GOLANG_VERSION={GO_VERSION}", "GOLANG_VERSION=1.25.9"])
    assert stub.run("1", {"linux/amd64": both}).returncode != 0


@with_stub
def test_unreadable_json_fails(stub: Stub) -> None:
    for config in ("not json", "", "{", json.dumps([image()]), "{}", "null", json.dumps({"linux/amd64": "x"})):
        result = stub.run("1", config)
        assert result.returncode != 0, (config, result.stdout)
        assert "Go image" in result.stderr, (config, result.stderr)
    # Only attestation entries means no image was checked.
    assert stub.run("1", {"unknown/unknown": image(None)}).returncode != 0


@with_stub
def test_docker_failure_fails(stub: Stub) -> None:
    result = stub.run("1", image(), mode="fail")
    assert result.returncode != 0, result.stdout
    assert f"cannot inspect golang@{PINNED}" in result.stderr, result.stderr


@with_stub
def test_missing_docker_fails_closed(stub: Stub) -> None:
    tools = stub.temp / "tools"
    tools.mkdir()
    path = str(tools)
    if posix_shell.usr_bin():
        # Windows: the coreutils need their DLLs beside them, so keep Git's
        # directory on PATH instead of symlinking (it has no docker).
        posix_shell.write_python3_shim(tools)
        path = os.pathsep.join([str(tools), posix_shell.usr_bin()])
        assert shutil.which("docker", path=path) is None
    else:
        for tool in ("dirname", "tr", "sed", "head", "grep", "sort", "python3"):
            found = shutil.which(tool)
            assert found, tool
            os.symlink(found, tools / tool)
    # The offline checks still pass with this PATH ...
    assert stub.run(None, path=path).returncode == 0
    # ... and verification without docker fails.
    result = stub.run("1", path=path)
    assert result.returncode != 0, result.stdout
    assert "docker" in result.stderr, result.stderr


@with_stub
def test_unknown_switch_value_fails(stub: Stub) -> None:
    for verify in ("yes", "true", "2"):
        result = stub.run(verify, image())
        assert result.returncode != 0, verify
        assert stub.calls() == [], verify


if __name__ == "__main__":
    failures = 0
    for test in (
        test_offline_by_default,
        test_docker_command_line,
        test_single_image_passes,
        test_multi_platform_passes,
        test_wrong_version_fails,
        test_missing_golang_version_fails,
        test_one_platform_with_other_version_fails,
        test_unreadable_json_fails,
        test_docker_failure_fails,
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
