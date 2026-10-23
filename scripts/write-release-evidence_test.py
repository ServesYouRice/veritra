#!/usr/bin/env python3
"""Offline unit tests for release evidence manifest construction."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("write-release-evidence.py")
spec = importlib.util.spec_from_file_location("write_release_evidence", MODULE_PATH)
assert spec and spec.loader
writer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(writer)

COMMIT = "0123456789abcdef0123456789abcdef01234567"
IMAGE = "ghcr.io/veritra/messenger-server"
DIGEST = "sha256:1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff"
GO_VERSION = "1.25.12\n"

APPROVALS_COMMIT = "89abcdef0123456789abcdef0123456789abcdef"

POLICY = {
    "schema_version": 3,
    "approvals": {
        "production_crypto": {"path": "release/approvals/{commit}/crypto.json"},
        "security_review": {"path": "release/approvals/{commit}/review.json"},
    },
}

CI_EVIDENCE = {
    "run_id": 987654321,
    "conclusion": "success",
    "jobs": {
        "server": "success",
        "crypto": "success",
        "mobile": "success",
        "mobile-ios": "success",
        "compose-smoke": "success",
        "licenses": "success",
        "vulnerabilities": "success",
    },
}

MOCK_APPROVALS = {
    f"release/approvals/{COMMIT}/crypto.json": {"digest": "sha256:" + "c" * 64, "record": {"reviewer": "crypto-team"}},
    f"release/approvals/{COMMIT}/review.json": {"digest": "sha256:" + "d" * 64, "record": {"reviewer": "sec-team"}},
}

MOBILE = [{"platform": "ios", "artifact_type": "signed-release", "digest": "sha256:" + "b" * 64}]


def build(**overrides: object) -> dict[str, object]:
    args = {
        "policy": POLICY,
        "ci": CI_EVIDENCE,
        "commit": COMMIT,
        "image": IMAGE,
        "digest": DIGEST,
        "go_version": GO_VERSION,
        "approval_loader": lambda p: MOCK_APPROVALS[p],
        "mobile_artifacts": MOBILE,
        "approvals_commit": APPROVALS_COMMIT,
    }
    args.update(overrides)
    return writer.build_manifest(**args)


def expect_value_error(description: str, **overrides: object) -> None:
    try:
        build(**overrides)
    except ValueError:
        return
    raise AssertionError(f"expected {description} to fail validation")


def test_build_manifest() -> None:
    # 1. Invalid commit SHA
    for bad_commit in ["", "short", "0123456789ABCDEF0123456789ABCDEF01234567", COMMIT + "0", "z" * 40]:
        expect_value_error(f"commit {bad_commit!r}", commit=bad_commit)

    # 2. Missing image or digest
    expect_value_error("empty image", image="")
    expect_value_error("empty digest", digest="")

    # 3. Invalid approvals structure in policy, or no approvals commit
    expect_value_error("non-dict approvals", policy={"schema_version": 3, "approvals": "not a dict"})
    expect_value_error(
        "missing approval path", policy={"schema_version": 3, "approvals": {"bad": {"no_path": 1}}}
    )
    for bad_approvals in ["", "short", APPROVALS_COMMIT.upper(), APPROVALS_COMMIT + "0"]:
        expect_value_error(f"approvals commit {bad_approvals!r}", approvals_commit=bad_approvals)

    # 4. Mobile artifact evidence must be a list of records (QA02)
    for bad_mobile in [None, {}, "records", [1], [MOBILE[0], "x"]]:
        expect_value_error(f"mobile artifacts {bad_mobile!r}", mobile_artifacts=bad_mobile)

    # 5. Valid manifest construction and field propagation
    manifest = build()
    assert manifest["schema_version"] == 3
    assert manifest["candidate_commit"] == COMMIT
    assert manifest["binary_commit"] == COMMIT
    assert manifest["ci_run_id"] == 987654321
    assert manifest["ci_conclusion"] == "success"
    assert manifest["ci_jobs"] == CI_EVIDENCE["jobs"]
    assert manifest["container"] == {
        "image": IMAGE,
        "digest": DIGEST,
        "commit": COMMIT,
        "toolchain": "1.25.12",
    }
    assert manifest["mobile_artifacts"] == MOBILE
    # Approvals are read at paths keyed by the candidate, from the
    # approvals commit, and recorded with it.
    assert manifest["approvals"] == {
        "commit": APPROVALS_COMMIT,
        "production_crypto": MOCK_APPROVALS[f"release/approvals/{COMMIT}/crypto.json"],
        "security_review": MOCK_APPROVALS[f"release/approvals/{COMMIT}/review.json"],
    }
    assert "production_crypto" not in manifest

    # 6. CI job evidence cannot inject mobile records: only the separate
    # mobile artifact file reaches the manifest.
    smuggled = dict(CI_EVIDENCE, mobile_artifacts=[{"artifact_type": "signed-release"}])
    assert build(ci=smuggled)["mobile_artifacts"] == MOBILE
    assert build(mobile_artifacts=[])["mobile_artifacts"] == []


def test_simulator_record() -> None:
    temp = Path(tempfile.mkdtemp(prefix="veritra-sim-record-"))
    try:
        artifact = temp / "veritra-demo-ios-simulator.zip"
        artifact.write_bytes(b"synthetic simulator build")
        record = writer.simulator_record(COMMIT, "4242", artifact)
        assert record["artifact_type"] == "simulator-debug"
        assert record["platform"] == "ios"
        assert record["signing"] == {"status": "unsigned"}
        assert record["build"]["sdk"] == "iphonesimulator"
        assert record["provenance"]["job"] == "mobile-ios"
        assert record["provenance"]["workflow"] == ".github/workflows/ci.yml"
        assert record["commit"] == record["provenance"]["source_commit"] == COMMIT
        assert record["digest"] == "sha256:" + hashlib.sha256(b"synthetic simulator build").hexdigest()

        for bad_commit in ["", "A" * 40, "short"]:
            try:
                writer.simulator_record(bad_commit, "4242", artifact)
                raise AssertionError(f"expected simulator commit {bad_commit!r} to fail")
            except ValueError:
                pass
        for bad_run in ["", "12a", "-1", "１２３", "1" * 21]:
            try:
                writer.simulator_record(COMMIT, bad_run, artifact)
                raise AssertionError(f"expected simulator run id {bad_run!r} to fail")
            except ValueError:
                pass

        # The CLI mode CI uses prints the same record.
        env = dict(os.environ, GITHUB_SHA=COMMIT, GITHUB_RUN_ID="4242")
        result = subprocess.run(
            [sys.executable, str(MODULE_PATH), "--ios-simulator-record", str(artifact)],
            text=True,
            capture_output=True,
            check=False,
            env=env,
        )
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == record
        env["GITHUB_RUN_ID"] = ""
        result = subprocess.run(
            [sys.executable, str(MODULE_PATH), "--ios-simulator-record", str(artifact)],
            text=True,
            capture_output=True,
            check=False,
            env=env,
        )
        assert result.returncode != 0 and not result.stdout
    finally:
        shutil.rmtree(temp)


def test_missing_mobile_evidence_fails_closed() -> None:
    temp = Path(tempfile.mkdtemp(prefix="veritra-writer-"))
    try:
        ci_file = temp / "ci-evidence.json"
        ci_file.write_text(json.dumps(CI_EVIDENCE), encoding="utf-8")
        env = dict(
            os.environ,
            RELEASE_COMMIT=COMMIT,
            CI_EVIDENCE_FILE=str(ci_file),
            MOBILE_ARTIFACTS_FILE=str(temp / "absent.json"),
            CONTAINER_IMAGE=IMAGE,
            CONTAINER_DIGEST=DIGEST,
        )
        result = subprocess.run(
            [sys.executable, str(MODULE_PATH)], text=True, capture_output=True, check=False, env=env
        )
        assert result.returncode != 0
        assert "signed mobile artifact evidence is missing" in result.stderr
        assert not result.stdout
    finally:
        shutil.rmtree(temp)


def test_approvals_commit_is_required() -> None:
    temp = Path(tempfile.mkdtemp(prefix="veritra-writer-"))
    try:
        ci_file = temp / "ci-evidence.json"
        ci_file.write_text(json.dumps(CI_EVIDENCE), encoding="utf-8")
        mobile_file = temp / "mobile-artifacts.json"
        mobile_file.write_text(json.dumps({"artifacts": MOBILE}), encoding="utf-8")
        base = {key: value for key, value in os.environ.items() if key != "RELEASE_APPROVALS_COMMIT"}
        env = dict(
            base,
            RELEASE_COMMIT=COMMIT,
            CI_EVIDENCE_FILE=str(ci_file),
            MOBILE_ARTIFACTS_FILE=str(mobile_file),
            CONTAINER_IMAGE=IMAGE,
            CONTAINER_DIGEST=DIGEST,
        )
        for approvals_commit in (None, "", "f" * 40):
            if approvals_commit is not None:
                env["RELEASE_APPROVALS_COMMIT"] = approvals_commit
            result = subprocess.run(
                [sys.executable, str(MODULE_PATH)], text=True, capture_output=True, check=False, env=env
            )
            assert result.returncode != 0, result.stdout
            assert not result.stdout
            expected = "approval is missing" if approvals_commit else "RELEASE_APPROVALS_COMMIT must be"
            assert expected in result.stderr, result.stderr
    finally:
        shutil.rmtree(temp)


if __name__ == "__main__":
    test_build_manifest()
    test_simulator_record()
    test_missing_mobile_evidence_fails_closed()
    test_approvals_commit_is_required()
    print("Release evidence manifest construction tests passed")
