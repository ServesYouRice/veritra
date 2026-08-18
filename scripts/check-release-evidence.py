#!/usr/bin/env python3
"""Validate the positive, commit-bound release evidence contract."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
SCHEMA_VERSION = 1
REQUIRED_CI_JOBS = (
    "server",
    "crypto",
    "mobile",
    "mobile-ios",
    "compose-smoke",
    "licenses",
    "vulnerabilities",
)
REQUIRED_APPROVALS = {
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
}


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"missing evidence file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"evidence root must be an object: {path}")
    return value


def expected_commit(root: Path, supplied: str | None) -> str:
    if supplied:
        return supplied
    try:
        return subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ValueError("cannot determine the candidate commit") from exc


def require(value: Any, description: str, errors: list[str]) -> None:
    if not value:
        errors.append(f"missing {description}")


def check_approval(
    root: Path,
    approval_name: str,
    approval_policy: dict[str, Any],
    candidate: str,
    errors: list[str],
) -> dict[str, Any] | None:
    path_value = approval_policy.get("path")
    if not isinstance(path_value, str):
        errors.append(f"{approval_name} approval path is not configured")
        return None
    try:
        approval = load_json(root / path_value)
    except ValueError as exc:
        errors.append(str(exc))
        return None
    if approval.get("status") != approval_policy.get("status"):
        errors.append(f"{approval_name} approval is not {approval_policy.get('status')!r}")
    if approval.get("reviewed_commit") != candidate:
        errors.append(f"{approval_name} approval is not bound to candidate {candidate}")
    required_behavior = approval_policy.get("behavior_test")
    if required_behavior is not None and approval.get("behavior_test") != required_behavior:
        errors.append(f"{approval_name} behavior evidence is not {required_behavior!r}")
    if approval_policy.get("not_author") and approval.get("reviewer_is_author") is not False:
        errors.append(f"{approval_name} reviewer is not independently identified")
    require(approval.get("reviewer"), f"{approval_name} reviewer", errors)
    return approval


def validate_preflight(root: Path, policy: dict[str, Any], candidate: str) -> list[str]:
    errors: list[str] = []
    if policy.get("schema_version") != SCHEMA_VERSION:
        errors.append("release policy schema version is not protected version 1")
    if policy.get("required_ci_jobs") != list(REQUIRED_CI_JOBS):
        errors.append("release policy required CI jobs do not match the protected set")
    approvals = policy.get("approvals")
    if approvals != REQUIRED_APPROVALS:
        errors.append("release policy approvals do not match the protected set")
        approvals = REQUIRED_APPROVALS
    for name, approval_policy in approvals.items():
        if not isinstance(approval_policy, dict):
            errors.append(f"{name} approval policy is not an object")
            continue
        check_approval(root, name, approval_policy, candidate, errors)
    return errors


def validate_manifest(
    root: Path,
    policy: dict[str, Any],
    manifest: dict[str, Any],
    candidate: str,
) -> list[str]:
    errors = validate_preflight(root, policy, candidate)
    if manifest.get("schema_version") != policy.get("schema_version"):
        errors.append("release evidence schema version is not current")
    if manifest.get("candidate_commit") != candidate:
        errors.append("release evidence is not bound to the candidate commit")
    if manifest.get("binary_commit") != candidate:
        errors.append("packaged binary commit evidence does not match candidate")
    ci_run_id = manifest.get("ci_run_id")
    if not isinstance(ci_run_id, (int, str)) or not str(ci_run_id).isdigit():
        errors.append("release evidence has no valid CI run ID")
    if manifest.get("ci_conclusion") != "success":
        errors.append("required CI conclusion is not success")

    required_jobs = REQUIRED_CI_JOBS
    ci_jobs = manifest.get("ci_jobs")
    if not isinstance(ci_jobs, dict):
        errors.append("release evidence has no CI job map")
    else:
        for job in required_jobs:
            if ci_jobs.get(job) != "success":
                errors.append(f"required CI job {job!r} is missing or not successful")

    approvals = REQUIRED_APPROVALS
    for name, approval_policy in approvals.items():
        recorded = manifest.get(name)
        if not isinstance(recorded, dict):
            errors.append(f"release evidence has no {name} approval")
            continue
        if recorded.get("status") != approval_policy.get("status"):
            errors.append(f"release evidence {name} approval is not approved")
        if recorded.get("reviewed_commit") != candidate:
            errors.append(f"release evidence {name} approval is not commit-bound")
        if approval_policy.get("behavior_test") is not None and recorded.get("behavior_test") != approval_policy["behavior_test"]:
            errors.append(f"release evidence {name} behavior test did not pass")
        if approval_policy.get("not_author") and recorded.get("reviewer_is_author") is not False:
            errors.append(f"release evidence {name} reviewer is not independent")
        require(recorded.get("reviewer"), f"release evidence {name} reviewer", errors)

    container = manifest.get("container")
    if not isinstance(container, dict):
        errors.append("release evidence has no container record")
    else:
        require(container.get("image"), "container image", errors)
        if not isinstance(container.get("digest"), str) or not DIGEST_RE.fullmatch(container["digest"]):
            errors.append("container digest is not an immutable sha256 digest")
        if container.get("commit") != candidate:
            errors.append("container commit label does not match candidate")
        canonical_version = (root / ".go-version").read_text(encoding="utf-8").strip()
        if container.get("toolchain") != canonical_version:
            errors.append("container toolchain does not match .go-version")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--policy", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--expected-commit")
    parser.add_argument("--preflight", action="store_true")
    args = parser.parse_args()

    root = args.root.resolve()
    policy_path = (args.policy or root / "release/release-policy.json").resolve()
    candidate = expected_commit(root, args.expected_commit)
    if not COMMIT_RE.fullmatch(candidate):
        print("candidate commit is not a full lowercase SHA-1", file=sys.stderr)
        return 1
    try:
        policy = load_json(policy_path)
        errors = validate_preflight(root, policy, candidate)
        if not args.preflight:
            evidence_path = (args.evidence or root / "dist/release-evidence.json").resolve()
            errors.extend(validate_manifest(root, policy, load_json(evidence_path), candidate))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if errors:
        for error in dict.fromkeys(errors):
            print(f"release evidence blocked: {error}", file=sys.stderr)
        return 1
    print(f"release evidence valid for {candidate}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
