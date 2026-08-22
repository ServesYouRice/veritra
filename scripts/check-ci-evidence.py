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


def main() -> int:
    commit = os.environ.get("GITHUB_SHA", "")
    if len(commit) != 40 or any(char not in "0123456789abcdef" for char in commit):
        print("GITHUB_SHA must be a full lowercase commit SHA", file=sys.stderr)
        return 1
    policy = json.loads(POLICY.read_text(encoding="utf-8"))
    required_jobs = REQUIRED_CI_JOBS
    if policy.get("required_ci_jobs") != list(required_jobs):
        print("release policy required CI jobs do not match the protected set", file=sys.stderr)
        return 1
    try:
        runs = gh_json(
            "run",
            "list",
            "--workflow",
            "ci.yml",
            "--event",
            "push",
            "--status",
            "completed",
            "--limit",
            "20",
            "--json",
            "databaseId,headSha,status,conclusion,createdAt",
        )
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
            jobs_payload = gh_json("run", "view", run_id, "--json", "jobs")
            jobs = jobs_payload.get("jobs") if isinstance(jobs_payload, dict) else None
            if not isinstance(jobs, list):
                continue
            conclusions = {
                str(job.get("name")): job.get("conclusion")
                for job in jobs
                if isinstance(job, dict)
            }
            if all(conclusions.get(job) == "success" for job in required_jobs):
                print(
                    json.dumps(
                        {
                            "run_id": int(run_id),
                            "head_sha": commit,
                            "conclusion": "success",
                            "jobs": {job: conclusions[job] for job in required_jobs},
                        },
                        sort_keys=True,
                    )
                )
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
