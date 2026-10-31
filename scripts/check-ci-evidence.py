#!/usr/bin/env python3
"""Find a complete successful CI run for the exact release commit."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "release/release-policy.json"
REQUIRED_CI_JOBS = (
    "server",
    "crypto",
    "mobile",
    "mobile-ios",
    "compose-smoke",
    "licenses",
    "vulnerabilities",
)


def gh_json(*args: str) -> object:
    try:
        output = subprocess.check_output(["gh", *args], text=True)
        return json.loads(output)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"GitHub Actions evidence query failed: {exc}") from exc


from typing import Callable


def parse_and_validate_commit(commit: str) -> None:
    if len(commit) != 40 or any(char not in "0123456789abcdef" for char in commit):
        raise ValueError("GITHUB_SHA must be a full lowercase commit SHA")


def validate_policy_jobs(policy: dict[str, object], required_jobs: tuple[str, ...]) -> None:
    if policy.get("required_ci_jobs") != list(required_jobs):
        raise ValueError("release policy required CI jobs do not match the protected set")


def run_list_args(commit: str) -> list[str]:
    """gh arguments listing completed push runs of ci.yml for one commit.

    GitHub filters by head SHA, so a qualifying run is found however many later
    runs exist; select_ci_evidence still checks headSha on every result.
    """
    return [
        "run",
        "list",
        "--workflow",
        "ci.yml",
        "--event",
        "push",
        "--status",
        "completed",
        "--commit",
        commit,
        "--limit",
        "20",
        "--json",
        "databaseId,headSha,status,conclusion,createdAt",
    ]


def select_ci_evidence(
    commit: str,
    runs: object,
    fetch_jobs_payload: Callable[[str], object],
    required_jobs: tuple[str, ...] = REQUIRED_CI_JOBS,
) -> dict[str, object] | None:
    if not isinstance(runs, list):
        raise RuntimeError("CI run query did not return a list")
    candidates = [
        run
        for run in runs
        if isinstance(run, dict)
        and run.get("headSha") == commit
        and run.get("status") == "completed"
        and run.get("conclusion") == "success"
    ]
    candidates.sort(key=lambda run: str(run.get("createdAt", "")), reverse=True)
    for run in candidates:
        run_id = str(run.get("databaseId", ""))
        jobs_payload = fetch_jobs_payload(run_id)
        jobs = jobs_payload.get("jobs") if isinstance(jobs_payload, dict) else None
        if not isinstance(jobs, list):
            continue
        conclusions: dict[str, list[object]] = {}
        for job in jobs:
            if isinstance(job, dict):
                conclusions.setdefault(str(job.get("name")), []).append(job.get("conclusion"))
        # Each required job must appear exactly once and succeed, so a skipped
        # duplicate (such as a second mobile-ios) cannot hide behind a success.
        # This evidence only reports job conclusions: mobile-ios is the debug
        # simulator build and never stands in for signed-release evidence.
        if all(conclusions.get(job) == ["success"] for job in required_jobs):
            return {
                "run_id": int(run_id),
                "head_sha": commit,
                "conclusion": "success",
                "jobs": {job: "success" for job in required_jobs},
            }
    return None


def main() -> int:
    commit = os.environ.get("GITHUB_SHA", "")
    try:
        parse_and_validate_commit(commit)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    policy = json.loads(POLICY.read_text(encoding="utf-8"))
    try:
        validate_policy_jobs(policy, REQUIRED_CI_JOBS)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    try:
        runs = gh_json(*run_list_args(commit))
        evidence = select_ci_evidence(
            commit,
            runs,
            lambda run_id: gh_json("run", "view", run_id, "--json", "jobs"),
            REQUIRED_CI_JOBS,
        )
        if evidence is not None:
            print(json.dumps(evidence, sort_keys=True))
            return 0
        print(
            f"no completed successful CI run contains every required job for {commit}",
            file=sys.stderr,
        )
        return 1
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
