#!/usr/bin/env python3
"""Offline unit tests for release evidence manifest construction."""

from __future__ import annotations

import importlib.util
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

POLICY = {
    "schema_version": 1,
    "approvals": {
        "production_crypto": {"path": "release/approvals/crypto.json"},
        "security_review": {"path": "release/approvals/review.json"},
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
    "release/approvals/crypto.json": {"approved": True, "reviewer": "crypto-team"},
    "release/approvals/review.json": {"approved": True, "reviewer": "sec-team"},
}


def test_build_manifest() -> None:
    # 1. Invalid commit SHA
    for bad_commit in ["", "short", "0123456789ABCDEF0123456789ABCDEF01234567", COMMIT + "0", "z" * 40]:
        try:
            writer.build_manifest(POLICY, CI_EVIDENCE, bad_commit, IMAGE, DIGEST, GO_VERSION, lambda p: MOCK_APPROVALS[p])
            raise AssertionError(f"expected commit {bad_commit!r} to fail validation")
        except ValueError:
            pass

    # 2. Missing image or digest
    try:
        writer.build_manifest(POLICY, CI_EVIDENCE, COMMIT, "", DIGEST, GO_VERSION, lambda p: MOCK_APPROVALS[p])
        raise AssertionError("expected empty image to fail validation")
    except ValueError:
        pass
    try:
        writer.build_manifest(POLICY, CI_EVIDENCE, COMMIT, IMAGE, "", GO_VERSION, lambda p: MOCK_APPROVALS[p])
        raise AssertionError("expected empty digest to fail validation")
    except ValueError:
        pass

    # 3. Invalid approvals structure in policy
    try:
        writer.build_manifest({"schema_version": 1, "approvals": "not a dict"}, CI_EVIDENCE, COMMIT, IMAGE, DIGEST, GO_VERSION, lambda p: MOCK_APPROVALS[p])
        raise AssertionError("expected non-dict approvals to fail validation")
    except ValueError:
        pass
    try:
        bad_policy = {"schema_version": 1, "approvals": {"bad": {"no_path": 1}}}
        writer.build_manifest(bad_policy, CI_EVIDENCE, COMMIT, IMAGE, DIGEST, GO_VERSION, lambda p: MOCK_APPROVALS[p])
        raise AssertionError("expected missing approval path to fail validation")
    except ValueError:
        pass

    # 4. Valid manifest construction and field propagation
    manifest = writer.build_manifest(
        POLICY,
        CI_EVIDENCE,
        COMMIT,
        IMAGE,
        DIGEST,
        GO_VERSION,
        lambda p: MOCK_APPROVALS[p],
    )
    assert manifest["schema_version"] == 1
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
    assert manifest["production_crypto"] == MOCK_APPROVALS["release/approvals/crypto.json"]
    assert manifest["security_review"] == MOCK_APPROVALS["release/approvals/review.json"]


if __name__ == "__main__":
    test_build_manifest()
    print("Release evidence manifest construction tests passed")
