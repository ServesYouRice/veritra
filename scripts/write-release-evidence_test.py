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


def _rmtree(path, ignore_errors=False):
    """rmtree that also removes read-only repository objects on Windows."""

    def clear_readonly(func, target, _exc):
        os.chmod(target, 0o700)
        func(target)

    if sys.version_info >= (3, 12):
        shutil.rmtree(path, ignore_errors=ignore_errors, onexc=clear_readonly)
    else:
        shutil.rmtree(path, ignore_errors=ignore_errors, onerror=clear_readonly)

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
        "independent_review": {"path": "release/approvals/{commit}/review.json"},
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
    # The digest must be the immutable form the checker accepts, not a tag
    # or a typo.
    for bad_digest in ("latest", "sha256:ABC", "sha256:" + "a" * 63, "sha256:" + "A" * 64, "sha256:" + "a" * 65,
                       "sha512:" + "a" * 64, "a" * 64, DIGEST + "\n", " " + DIGEST, IMAGE + "@" + DIGEST):
        expect_value_error(f"digest {bad_digest!r}", digest=bad_digest)
    assert build(digest="sha256:" + "0" * 64)["container"]["digest"] == "sha256:" + "0" * 64

    # 3. Invalid approvals structure in policy, or no approvals commit
    expect_value_error("non-dict approvals", policy={"schema_version": 3, "approvals": "not a dict"})
    expect_value_error(
        "missing approval path", policy={"schema_version": 3, "approvals": {**POLICY["approvals"], "bad": {"no_path": 1}}}
    )
    expect_value_error(
        "empty approval path", policy={"schema_version": 3, "approvals": {**POLICY["approvals"], "bad": {"path": ""}}}
    )
    # A path not keyed by the candidate would serve one approval file to
    # every candidate.
    unkeyed = {**POLICY["approvals"], "production_crypto": {"path": "release/approvals/crypto.json"}}
    expect_value_error("approval path without {commit}", policy={"schema_version": 3, "approvals": unkeyed})
    # A missing or empty approvals section, or one without a required
    # approval, cannot produce a manifest (before, both gave one with no
    # approvals at all).
    expect_value_error("no approvals key", policy={"schema_version": 3})
    expect_value_error("empty approvals", policy={"schema_version": 3, "approvals": {}})
    assert writer.REQUIRED_APPROVALS, "the writer requires no approvals"

    def never_loaded(path: str) -> dict[str, object]:
        raise AssertionError(f"loaded {path} although the policy is incomplete")

    for name in writer.REQUIRED_APPROVALS:
        partial = {key: value for key, value in POLICY["approvals"].items() if key != name}
        partial["other"] = {"path": "release/approvals/{commit}/other.json"}
        try:
            build(policy={"schema_version": 3, "approvals": partial}, approval_loader=never_loaded)
        except ValueError as exc:
            assert name in str(exc), exc
        else:
            raise AssertionError(f"expected a policy without {name} to fail validation")
    # An invalid entry is refused before anything is loaded.
    try:
        build(policy={"schema_version": 3, "approvals": {**POLICY["approvals"], "bad": 7}}, approval_loader=never_loaded)
    except ValueError:
        pass
    else:
        raise AssertionError("expected an invalid approval entry to fail validation")
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
        "independent_review": MOCK_APPROVALS[f"release/approvals/{COMMIT}/review.json"],
    }
    assert "production_crypto" not in manifest

    # 6. CI job evidence cannot inject mobile records: only the separate
    # mobile artifact file reaches the manifest.
    smuggled = dict(CI_EVIDENCE, mobile_artifacts=[{"artifact_type": "signed-release"}])
    assert build(ci=smuggled)["mobile_artifacts"] == MOBILE
    assert build(mobile_artifacts=[])["mobile_artifacts"] == []


def test_required_approvals_match_the_gate() -> None:
    """The writer requires exactly what the checker and the policy do."""
    checker_path = MODULE_PATH.with_name("check-release-evidence.py")
    checker_spec = importlib.util.spec_from_file_location("check_release_evidence", checker_path)
    assert checker_spec and checker_spec.loader
    checker = importlib.util.module_from_spec(checker_spec)
    checker_spec.loader.exec_module(checker)
    assert set(writer.REQUIRED_APPROVALS) == set(checker.REQUIRED_APPROVALS)
    assert writer.DIGEST_PATTERN.pattern == checker.DIGEST_RE.pattern
    policy = json.loads((MODULE_PATH.parents[1] / "release/release-policy.json").read_text(encoding="utf-8"))
    assert set(writer.REQUIRED_APPROVALS) == set(policy["approvals"])


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
        _rmtree(temp)


def test_emulator_record() -> None:
    temp = Path(tempfile.mkdtemp(prefix="veritra-emu-record-"))
    try:
        artifact = temp / "app-debug.apk"
        artifact.write_bytes(b"synthetic debug apk")
        record = writer.emulator_record(COMMIT, "4243", artifact)
        assert record["platform"] == "android"
        assert record["artifact_type"] == "emulator-debug"
        assert record["file"] == "app-debug.apk"
        assert record["signing"] == {"status": "debug"}
        assert record["build"] == {"sdk": "android", "configuration": "debug", "entry_point": "lib/main_demo.dart"}
        assert record["provenance"]["job"] == "mobile"
        assert record["provenance"]["workflow"] == ".github/workflows/ci.yml"
        assert record["commit"] == record["provenance"]["source_commit"] == COMMIT
        assert record["digest"] == "sha256:" + hashlib.sha256(b"synthetic debug apk").hexdigest()
        for bad_run in ["", "x", "１２３"]:
            try:
                writer.emulator_record(COMMIT, bad_run, artifact)
                raise AssertionError(f"expected emulator run id {bad_run!r} to fail")
            except ValueError:
                pass

        env = dict(os.environ, GITHUB_SHA=COMMIT, GITHUB_RUN_ID="4243")
        command = [sys.executable, str(MODULE_PATH), "--android-emulator-record", str(artifact)]
        result = subprocess.run(command, text=True, capture_output=True, check=False, env=env)
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == record
        # One debug record per call: both flags together are refused.
        result = subprocess.run(command + ["--ios-simulator-record", str(artifact)], text=True, capture_output=True, check=False, env=env)
        assert result.returncode != 0 and not result.stdout
    finally:
        _rmtree(temp)


# --- The CLI against a real git repository: a candidate commit holding the
# policy and .go-version, a later approvals commit, and a copy of the writer
# at <repo>/scripts/, so that its ROOT is that repository.

GIT_ENV = {
    **{key: value for key, value in os.environ.items() if not key.startswith("GIT_")},
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
    "GIT_COMMITTER_NAME": "fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
}


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(root), *args], check=True, capture_output=True, text=True, env=GIT_ENV
    ).stdout.strip()


def commit_files(root: Path, start: str, files: dict[str, str | None], message: str) -> str:
    """Commit ``files`` (None deletes) on a detached HEAD at ``start``."""
    if start:
        git(root, "checkout", "-q", "--detach", start)
    for path, content in files.items():
        if content is None:
            git(root, "rm", "-q", path)
            continue
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        git(root, "add", path)
    git(root, "commit", "-q", "-m", message)
    return git(root, "rev-parse", "HEAD")


class Repository:
    def __init__(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="veritra-writer-repo-"))
        git(self.root, "init", "-q", "-b", "main")
        self.candidate = commit_files(
            self.root, "", {"release/release-policy.json": json.dumps(POLICY), ".go-version": GO_VERSION}, "candidate"
        )
        self.approvals = commit_files(
            self.root,
            self.candidate,
            {
                f"release/approvals/{self.candidate}/crypto.json": json.dumps({"reviewer": "crypto-team"}),
                f"release/approvals/{self.candidate}/review.json": json.dumps({"reviewer": "sec-team"}),
            },
            "approve",
        )
        (self.root / "scripts").mkdir()
        shutil.copy(MODULE_PATH, self.root / "scripts" / MODULE_PATH.name)
        (self.root / "ci-evidence.json").write_text(json.dumps(CI_EVIDENCE), encoding="utf-8")
        (self.root / "mobile-artifacts.json").write_text(json.dumps({"artifacts": MOBILE}), encoding="utf-8")

    def run(self, **changes: str | None) -> subprocess.CompletedProcess[str]:
        env = {key: value for key, value in GIT_ENV.items() if not key.startswith("RELEASE_")}
        env.update(
            RELEASE_COMMIT=self.candidate,
            RELEASE_APPROVALS_COMMIT=self.approvals,
            CI_EVIDENCE_FILE=str(self.root / "ci-evidence.json"),
            MOBILE_ARTIFACTS_FILE=str(self.root / "mobile-artifacts.json"),
            CONTAINER_IMAGE=IMAGE,
            CONTAINER_DIGEST=DIGEST,
        )
        for key, value in changes.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        script = self.root / "scripts" / MODULE_PATH.name
        return subprocess.run([sys.executable, str(script)], text=True, capture_output=True, check=False, env=env)

    def close(self) -> None:
        _rmtree(self.root)


def expect_refused(result: subprocess.CompletedProcess[str], reason: str) -> None:
    assert result.returncode != 0, result.stdout
    assert not result.stdout, result.stdout
    assert reason in result.stderr, result.stderr


def test_policy_and_toolchain_come_from_the_candidate_commit() -> None:
    repo = Repository()
    try:
        result = repo.run()
        assert result.returncode == 0, result.stderr
        manifest = json.loads(result.stdout)
        assert manifest["candidate_commit"] == repo.candidate
        # A working tree that differs from the candidate changes nothing:
        # the manifest attests the candidate, so it reads the candidate.
        drifted = json.loads(json.dumps(POLICY))
        drifted["schema_version"] = 99
        drifted["approvals"]["extra"] = {"path": "release/approvals/{commit}/extra.json"}
        (repo.root / "release/release-policy.json").write_text(json.dumps(drifted), encoding="utf-8")
        (repo.root / ".go-version").write_text("9.9.9\n", encoding="utf-8")
        result = repo.run()
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == manifest
        assert manifest["schema_version"] == 3
        assert manifest["container"]["toolchain"] == GO_VERSION.strip()
        assert set(manifest["approvals"]) == {"commit", "production_crypto", "independent_review"}
        # Nor does a working tree without them.
        (repo.root / "release/release-policy.json").unlink()
        (repo.root / ".go-version").unlink()
        result = repo.run()
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == manifest

        # A file missing from the candidate commit fails, naming it.
        for path in (".go-version", "release/release-policy.json"):
            missing = commit_files(repo.root, repo.candidate, {path: None}, f"no {path}")
            expect_refused(repo.run(RELEASE_COMMIT=missing), f"{path} is missing from candidate commit {missing}")
        for content, reason in (("{not json", "release/release-policy.json"), ("[]", "must contain a JSON object")):
            broken = commit_files(repo.root, repo.candidate, {"release/release-policy.json": content}, "bad policy")
            expect_refused(repo.run(RELEASE_COMMIT=broken), reason)
        # A commit that is not in the repository, or not a full SHA.
        expect_refused(repo.run(RELEASE_COMMIT="f" * 40), "is missing from candidate commit")
        expect_refused(repo.run(RELEASE_COMMIT="HEAD"), "RELEASE_COMMIT must be a 40-character lowercase hex SHA")
    finally:
        repo.close()


def test_missing_mobile_evidence_fails_closed() -> None:
    repo = Repository()
    try:
        expect_refused(repo.run(MOBILE_ARTIFACTS_FILE=str(repo.root / "absent.json")),
                       "signed mobile artifact evidence is missing")
        expect_refused(repo.run(CONTAINER_DIGEST="latest"), "CONTAINER_DIGEST must be sha256:<64 lowercase hex>")
    finally:
        repo.close()


def test_approvals_commit_is_required() -> None:
    repo = Repository()
    try:
        assert repo.run().returncode == 0
        for approvals_commit in (None, ""):
            expect_refused(repo.run(RELEASE_APPROVALS_COMMIT=approvals_commit), "RELEASE_APPROVALS_COMMIT must be")
        expect_refused(repo.run(RELEASE_APPROVALS_COMMIT="f" * 40), "approval is missing")
        # An approval that is not a JSON object.
        listed = commit_files(repo.root, repo.candidate, {
            f"release/approvals/{repo.candidate}/crypto.json": "[]",
            f"release/approvals/{repo.candidate}/review.json": json.dumps({"reviewer": "sec-team"}),
        }, "approve with a list")
        expect_refused(repo.run(RELEASE_APPROVALS_COMMIT=listed), "is not a JSON object")
    finally:
        repo.close()


def test_git_reads_only_the_repository() -> None:
    """The caller's GIT_* variables cannot point git at other objects: an
    approvals commit only another copy of the repository holds is not found
    through an alternate object directory or GIT_DIR."""
    repo = Repository()
    other = repo.root.parent / (repo.root.name + "-other")
    try:
        shutil.copytree(repo.root, other)
        outside = commit_files(other, repo.candidate, {
            f"release/approvals/{repo.candidate}/crypto.json": json.dumps({"reviewer": "someone"}),
            f"release/approvals/{repo.candidate}/review.json": json.dumps({"reviewer": "someone"}),
        }, "approve outside the repository")
        for redirect in ({"GIT_ALTERNATE_OBJECT_DIRECTORIES": str(other / ".git/objects")},
                         {"GIT_OBJECT_DIRECTORY": str(other / ".git/objects")},
                         {"GIT_DIR": str(other / ".git")}):
            expect_refused(repo.run(RELEASE_APPROVALS_COMMIT=outside, **redirect), "approval is missing")
        # The redirected policy is not read either: here GIT_DIR's copy
        # holds a candidate the repository does not.
        moved = commit_files(other, repo.candidate, {".go-version": "9.9.9\n"}, "other toolchain")
        expect_refused(repo.run(RELEASE_COMMIT=moved, GIT_DIR=str(other / ".git")), "is missing from candidate commit")
    finally:
        _rmtree(other, ignore_errors=True)
        repo.close()


if __name__ == "__main__":
    test_build_manifest()
    test_required_approvals_match_the_gate()
    test_simulator_record()
    test_emulator_record()
    test_policy_and_toolchain_come_from_the_candidate_commit()
    test_missing_mobile_evidence_fails_closed()
    test_approvals_commit_is_required()
    test_git_reads_only_the_repository()
    print("Release evidence manifest construction tests passed")
