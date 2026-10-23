#!/usr/bin/env python3
"""Adversarial tests for the release evidence validator."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check-release-evidence.py"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
JOBS = {
    "server": "success",
    "crypto": "success",
    "mobile": "success",
    "mobile-ios": "success",
    "compose-smoke": "success",
    "licenses": "success",
    "vulnerabilities": "success",
}


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def fixture() -> tuple[Path, dict[str, object]]:
    temp = Path(tempfile.mkdtemp(prefix="veritra-release-evidence-"))
    (temp / ".go-version").write_text("1.25.12\n", encoding="utf-8")
    policy = {
        "schema_version": 1,
        "required_ci_jobs": list(JOBS),
        "approvals": {
            "production_crypto": {
                "path": "release/production-crypto-approval.json",
                "status": "approved",
                "behavior_test": "pass",
                "not_author": True,
            },
            "independent_review": {
                "path": "release/independent-review-approval.json",
                "status": "approved",
                "not_author": True,
            },
        },
    }
    write_json(temp / "release/release-policy.json", policy)
    write_json(
        temp / "release/production-crypto-approval.json",
        {
            "status": "approved",
            "behavior_test": "pass",
            "reviewed_commit": COMMIT,
            "reviewer": "crypto-reviewer",
            "reviewer_is_author": False,
        },
    )
    write_json(
        temp / "release/independent-review-approval.json",
        {
            "status": "approved",
            "reviewed_commit": COMMIT,
            "reviewer": "independent-reviewer",
            "reviewer_is_author": False,
        },
    )
    manifest = {
        "schema_version": 1,
        "candidate_commit": COMMIT,
        "binary_commit": COMMIT,
        "ci_run_id": 123,
        "ci_conclusion": "success",
        "ci_jobs": JOBS.copy(),
        "production_crypto": {
            "status": "approved",
            "behavior_test": "pass",
            "reviewed_commit": COMMIT,
            "reviewer": "crypto-reviewer",
            "reviewer_is_author": False,
        },
        "independent_review": {
            "status": "approved",
            "reviewed_commit": COMMIT,
            "reviewer": "independent-reviewer",
            "reviewer_is_author": False,
        },
        "container": {
            "image": "ghcr.io/example/veritra:v1",
            "digest": "sha256:" + "a" * 64,
            "commit": COMMIT,
            "toolchain": "1.25.12",
        },
    }
    write_json(temp / "dist/release-evidence.json", manifest)
    return temp, manifest


def run(root: Path, *extra: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECKER), "--root", str(root), "--expected-commit", COMMIT, *extra],
        text=True,
        capture_output=True,
        check=False,
    )


def expect_valid(root: Path, manifest: dict[str, object]) -> None:
    write_json(root / "dist/release-evidence.json", manifest)
    result = run(root)
    if result.returncode != 0:
        raise AssertionError(f"expected valid evidence to pass: {result.stderr.strip()}")


def expect_blocked(root: Path, manifest: dict[str, object], reason: str) -> None:
    # Each negative case must fail for its own reason, not a leftover one.
    write_json(root / "dist/release-evidence.json", manifest)
    result = run(root)
    if result.returncode == 0 or reason not in result.stderr:
        raise AssertionError(f"expected {reason!r}, got rc={result.returncode}: {result.stderr.strip()}")


def main() -> int:
    root, manifest = fixture()
    try:
        expect_valid(root, manifest)

        # A renamed/moved placeholder cannot satisfy positive approval evidence.
        crypto = manifest.pop("production_crypto")
        expect_blocked(root, manifest, "has no production_crypto approval")
        manifest["production_crypto"] = crypto
        expect_valid(root, manifest)

        manifest["ci_jobs"]["mobile-ios"] = "skipped"
        expect_blocked(root, manifest, "required CI job 'mobile-ios' is missing or not successful")
        manifest["ci_jobs"]["mobile-ios"] = "success"

        manifest["independent_review"]["status"] = "pending"
        expect_blocked(root, manifest, "independent_review approval is not approved")
        manifest["independent_review"]["status"] = "approved"

        manifest["independent_review"]["reviewer_is_author"] = True
        expect_blocked(root, manifest, "independent_review reviewer is not independent")
        manifest["independent_review"]["reviewer_is_author"] = False

        manifest["binary_commit"] = "fedcba9876543210fedcba9876543210fedcba98"
        expect_blocked(root, manifest, "packaged binary commit evidence does not match candidate")
        manifest["binary_commit"] = COMMIT

        manifest["container"]["digest"] = "sha256:" + "a" * 63
        expect_blocked(root, manifest, "container digest is not an immutable sha256 digest")
        manifest["container"]["digest"] = "sha256:" + "a" * 64

        manifest["container"]["commit"] = "fedcba9876543210fedcba9876543210fedcba98"
        expect_blocked(root, manifest, "container commit label does not match candidate")
        manifest["container"]["commit"] = COMMIT

        expect_valid(root, manifest)
    finally:
        import shutil

        shutil.rmtree(root)
    print("release evidence adversarial tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
