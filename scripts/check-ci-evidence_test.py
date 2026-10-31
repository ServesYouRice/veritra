#!/usr/bin/env python3
"""Offline unit tests for CI evidence query and selection logic."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("check-ci-evidence.py")
spec = importlib.util.spec_from_file_location("check_ci_evidence", MODULE_PATH)
assert spec and spec.loader
check_ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_ci)

COMMIT = "0123456789abcdef0123456789abcdef01234567"
REQUIRED_JOBS = check_ci.REQUIRED_CI_JOBS


def test_commit_validation() -> None:
    check_ci.parse_and_validate_commit(COMMIT)
    for bad in ["", "short", "0123456789ABCDEF0123456789ABCDEF01234567", COMMIT + "0", "g" * 40]:
        try:
            check_ci.parse_and_validate_commit(bad)
            raise AssertionError(f"expected commit {bad!r} to fail validation")
        except ValueError:
            pass


def test_policy_validation() -> None:
    check_ci.validate_policy_jobs({"required_ci_jobs": list(REQUIRED_JOBS)}, REQUIRED_JOBS)
    for bad_policy in [
        {},
        {"required_ci_jobs": []},
        {"required_ci_jobs": list(REQUIRED_JOBS)[:-1]},
        {"required_ci_jobs": list(REQUIRED_JOBS) + ["extra"]},
    ]:
        try:
            check_ci.validate_policy_jobs(bad_policy, REQUIRED_JOBS)
            raise AssertionError(f"expected policy {bad_policy!r} to fail validation")
        except ValueError:
            pass


def test_select_ci_evidence() -> None:
    # 1. Non-list payload raises RuntimeError
    try:
        check_ci.select_ci_evidence(COMMIT, {"not": "a list"}, lambda _: {})
        raise AssertionError("expected non-list runs to raise RuntimeError")
    except RuntimeError:
        pass

    # 2. No matching runs -> returns None
    assert check_ci.select_ci_evidence(COMMIT, [], lambda _: {}) is None

    # 3. Runs with wrong commit, uncompleted status, or failed conclusion are ignored
    runs = [
        {"databaseId": 101, "headSha": "a" * 40, "status": "completed", "conclusion": "success", "createdAt": "2026-08-24T10:00:00Z"},
        {"databaseId": 102, "headSha": COMMIT, "status": "in_progress", "conclusion": None, "createdAt": "2026-08-24T11:00:00Z"},
        {"databaseId": 103, "headSha": COMMIT, "status": "completed", "conclusion": "failure", "createdAt": "2026-08-24T12:00:00Z"},
    ]
    assert check_ci.select_ci_evidence(COMMIT, runs, lambda _: {}) is None

    # 4. Incomplete/skipped jobs in run
    candidate_run = {"databaseId": 201, "headSha": COMMIT, "status": "completed", "conclusion": "success", "createdAt": "2026-08-24T12:00:00Z"}
    
    # Missing some required jobs
    missing_jobs_fetcher = lambda _: {"jobs": [{"name": job, "conclusion": "success"} for job in list(REQUIRED_JOBS)[:-1]]}
    assert check_ci.select_ci_evidence(COMMIT, [candidate_run], missing_jobs_fetcher) is None

    # One required job failed or skipped
    skipped_job_fetcher = lambda _: {
        "jobs": [{"name": job, "conclusion": "success" if job != "compose-smoke" else "skipped"} for job in REQUIRED_JOBS]
    }
    assert check_ci.select_ci_evidence(COMMIT, [candidate_run], skipped_job_fetcher) is None

    # 5. Complete exact-run success
    all_success_fetcher = lambda _: {
        "jobs": [{"name": job, "conclusion": "success"} for job in REQUIRED_JOBS]
    }
    result = check_ci.select_ci_evidence(COMMIT, [candidate_run], all_success_fetcher)
    assert result is not None
    assert result["run_id"] == 201
    assert result["head_sha"] == COMMIT
    assert result["conclusion"] == "success"
    assert len(result["jobs"]) == len(REQUIRED_JOBS)
    assert all(result["jobs"][job] == "success" for job in REQUIRED_JOBS)

    # 6. Multiple candidate runs: picks newest by createdAt
    newer_candidate = {"databaseId": 302, "headSha": COMMIT, "status": "completed", "conclusion": "success", "createdAt": "2026-08-24T14:00:00Z"}
    older_candidate = {"databaseId": 301, "headSha": COMMIT, "status": "completed", "conclusion": "success", "createdAt": "2026-08-24T13:00:00Z"}
    runs_multiple = [older_candidate, newer_candidate]
    result_multiple = check_ci.select_ci_evidence(COMMIT, runs_multiple, all_success_fetcher)
    assert result_multiple is not None
    assert result_multiple["run_id"] == 302


def test_simulator_job_stays_mandatory() -> None:
    """QA02: the debug simulator job is required, and CI evidence is jobs only."""
    assert "mobile-ios" in REQUIRED_JOBS
    candidate_run = {"databaseId": 401, "headSha": COMMIT, "status": "completed", "conclusion": "success", "createdAt": "2026-08-24T15:00:00Z"}

    def jobs_with(overrides: dict[str, object], extra: list[dict[str, object]] | None = None):
        jobs = []
        for job in REQUIRED_JOBS:
            conclusion = overrides.get(job, "success")
            if conclusion is not None:  # None drops the job entirely
                jobs.append({"name": job, "conclusion": conclusion})
        return lambda _: {"jobs": jobs + (extra or [])}

    # Skipped, cancelled or absent simulator job: no evidence.
    for conclusion in ["skipped", "cancelled", "neutral", "failure", ""]:
        assert check_ci.select_ci_evidence(COMMIT, [candidate_run], jobs_with({"mobile-ios": conclusion})) is None
    assert check_ci.select_ci_evidence(COMMIT, [candidate_run], jobs_with({"mobile-ios": None})) is None

    # A skipped duplicate cannot hide behind a successful copy, in either order.
    duplicate = [{"name": "mobile-ios", "conclusion": "skipped"}]
    assert check_ci.select_ci_evidence(COMMIT, [candidate_run], jobs_with({}, duplicate)) is None
    reordered = lambda _: {"jobs": duplicate + [{"name": job, "conclusion": "success"} for job in REQUIRED_JOBS]}
    assert check_ci.select_ci_evidence(COMMIT, [candidate_run], reordered) is None

    # A job that claims to be a signed build adds nothing: the evidence carries
    # job conclusions only, never mobile artifact records.
    signed_claim = [{"name": "ios-signed-release", "conclusion": "success"}]
    result = check_ci.select_ci_evidence(COMMIT, [candidate_run], jobs_with({}, signed_claim))
    assert result is not None
    assert set(result) == {"run_id", "head_sha", "conclusion", "jobs"}
    assert set(result["jobs"]) == set(REQUIRED_JOBS)


def has_pair(args: list[str], flag: str, value: str) -> bool:
    return any(args[i] == flag and args[i + 1] == value for i in range(len(args) - 1))


def test_run_query_is_filtered_by_commit() -> None:
    """The run query asks GitHub for the release commit's runs only, so
    qualifying evidence older than the latest workflow runs is still found."""
    args = check_ci.run_list_args(COMMIT)
    assert has_pair(args, "--commit", COMMIT), args
    assert has_pair(args, "--workflow", "ci.yml"), args
    assert has_pair(args, "--event", "push"), args
    assert has_pair(args, "--status", "completed"), args
    assert args[:2] == ["run", "list"], args


def test_main_uses_commit_filtered_query() -> None:
    calls: list[tuple[str, ...]] = []
    candidate_run = {"databaseId": 501, "headSha": COMMIT, "status": "completed", "conclusion": "success", "createdAt": "2026-08-24T16:00:00Z"}

    def fake_gh_json(*args: str) -> object:
        calls.append(args)
        if args[:2] == ("run", "list"):
            return [candidate_run]
        return {"jobs": [{"name": job, "conclusion": "success"} for job in REQUIRED_JOBS]}

    original_gh_json = check_ci.gh_json
    original_sha = os.environ.get("GITHUB_SHA")
    check_ci.gh_json = fake_gh_json
    os.environ["GITHUB_SHA"] = COMMIT
    try:
        with contextlib.redirect_stdout(io.StringIO()) as output:
            assert check_ci.main() == 0
    finally:
        check_ci.gh_json = original_gh_json
        if original_sha is None:
            os.environ.pop("GITHUB_SHA", None)
        else:
            os.environ["GITHUB_SHA"] = original_sha
    run_list = [call for call in calls if call[:2] == ("run", "list")]
    assert len(run_list) == 1, calls
    assert has_pair(list(run_list[0]), "--commit", COMMIT), run_list
    assert json.loads(output.getvalue())["run_id"] == 501


if __name__ == "__main__":
    test_commit_validation()
    test_policy_validation()
    test_select_ci_evidence()
    test_simulator_job_stays_mandatory()
    test_run_query_is_filtered_by_commit()
    test_main_uses_commit_filtered_query()
    print("CI evidence selection adversarial tests passed")
