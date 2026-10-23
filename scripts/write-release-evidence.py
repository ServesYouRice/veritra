#!/usr/bin/env python3
"""Build the ephemeral release evidence manifest after artifact packaging.

With ``--ios-simulator-record FILE`` it instead prints the simulator-debug
record that the ``mobile-ios`` CI job publishes next to its simulator build,
and with ``--android-emulator-record FILE`` the emulator-debug record the
``mobile`` job publishes next to its demo APK. Neither record type can ever
satisfy the signed-release requirement.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MOBILE_RECORD_SCHEMA = "veritra-mobile-artifact/1"


def load(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


from typing import Callable


def validate_commit(commit: str, name: str = "RELEASE_COMMIT") -> None:
    if len(commit) != 40 or any(char not in "0123456789abcdef" for char in commit):
        raise ValueError(f"{name} must be a 40-character lowercase hex SHA")


def build_manifest(
    policy: dict[str, object],
    ci: dict[str, object],
    commit: str,
    image: str,
    digest: str,
    go_version: str,
    approval_loader: Callable[[str], dict[str, object]],
    mobile_artifacts: object,
    approvals_commit: str,
) -> dict[str, object]:
    """``approval_loader`` maps a repository path to its manifest entry
    (path, sha256 digest and parsed record) as read at ``approvals_commit``."""
    validate_commit(commit)
    validate_commit(approvals_commit, "RELEASE_APPROVALS_COMMIT")
    if not image or not digest:
        raise ValueError("CONTAINER_IMAGE and CONTAINER_DIGEST are required")
    approvals = policy.get("approvals", {})
    if not isinstance(approvals, dict):
        raise ValueError("release policy has no approvals")
    # Mobile records come only from the separate mobile artifact file, never
    # from CI job evidence, so a simulator CI run cannot add signed evidence.
    if not isinstance(mobile_artifacts, list) or not all(isinstance(r, dict) for r in mobile_artifacts):
        raise ValueError("mobile artifact evidence must be a list of records")
    manifest: dict[str, object] = {
        "schema_version": policy.get("schema_version"),
        "candidate_commit": commit,
        "binary_commit": commit,
        "ci_run_id": ci.get("run_id"),
        "ci_conclusion": ci.get("conclusion"),
        "ci_jobs": ci.get("jobs"),
        "container": {
            "image": image,
            "digest": digest,
            "commit": commit,
            "toolchain": go_version.strip(),
        },
        "mobile_artifacts": mobile_artifacts,
    }
    # Approvals come from a later commit on the protected branch, at a path
    # keyed by the candidate; check-release-evidence.py compares every entry
    # with git again.
    recorded: dict[str, object] = {"commit": approvals_commit}
    for name, config in approvals.items():
        if not isinstance(config, dict) or not isinstance(config.get("path"), str):
            raise ValueError(f"invalid approval configuration: {name}")
        recorded[name] = approval_loader(config["path"].format(commit=commit))
    manifest["approvals"] = recorded
    return manifest


def git_approval_loader(approvals_commit: str, root: Path = ROOT) -> Callable[[str], dict[str, object]]:
    def load_approval(path: str) -> dict[str, object]:
        try:
            blob = subprocess.run(
                ["git", "--no-replace-objects", "-C", str(root), "cat-file", "blob", f"{approvals_commit}:{path}"],
                capture_output=True,
                check=True,
            ).stdout
        except subprocess.CalledProcessError as exc:
            raise ValueError(f"approval is missing from approvals commit {approvals_commit}: {path}") from exc
        record = json.loads(blob.decode("utf-8"))
        return {"path": path, "digest": "sha256:" + hashlib.sha256(blob).hexdigest(), "record": record}

    return load_approval


def debug_record(
    platform: str, commit: str, run_id: str, artifact: Path, entry_point: str
) -> dict[str, object]:
    """Describe a hosted CI debug build. It is never release evidence."""
    artifact_type, sdk, signing, job = {
        "ios": ("simulator-debug", "iphonesimulator", "unsigned", "mobile-ios"),
        "android": ("emulator-debug", "android", "debug", "mobile"),
    }[platform]
    validate_commit(commit, "GITHUB_SHA")
    if not run_id or len(run_id) > 20 or any(char not in "0123456789" for char in run_id):
        raise ValueError("GITHUB_RUN_ID must be ASCII digits")
    hasher = hashlib.sha256()
    with artifact.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    return {
        "schema": MOBILE_RECORD_SCHEMA,
        "platform": platform,
        "artifact_type": artifact_type,
        "commit": commit,
        "file": artifact.name,
        "digest": f"sha256:{digest}",
        "build": {"sdk": sdk, "configuration": "debug", "entry_point": entry_point},
        "signing": {"status": signing},
        "provenance": {
            "builder": "github-actions",
            "workflow": ".github/workflows/ci.yml",
            "job": job,
            "run_id": run_id,
            "source_commit": commit,
        },
    }


def simulator_record(commit: str, run_id: str, artifact: Path, entry_point: str = "lib/main_demo.dart") -> dict[str, object]:
    """The mobile-ios job's simulator build: unsigned debug output."""
    return debug_record("ios", commit, run_id, artifact, entry_point)


def emulator_record(commit: str, run_id: str, artifact: Path, entry_point: str = "lib/main_demo.dart") -> dict[str, object]:
    """The mobile job's demo APK: debug-signed, for emulators and test devices."""
    return debug_record("android", commit, run_id, artifact, entry_point)


def main() -> int:
    parser = argparse.ArgumentParser()
    debug = parser.add_mutually_exclusive_group()
    debug.add_argument("--ios-simulator-record", type=Path, metavar="FILE")
    debug.add_argument("--android-emulator-record", type=Path, metavar="FILE")
    args = parser.parse_args()
    if args.ios_simulator_record or args.android_emulator_record:
        make = simulator_record if args.ios_simulator_record else emulator_record
        try:
            record = make(
                os.environ.get("GITHUB_SHA", ""),
                os.environ.get("GITHUB_RUN_ID", ""),
                args.ios_simulator_record or args.android_emulator_record,
            )
        except (ValueError, OSError) as exc:
            print(str(exc), file=sys.stderr)
            return 1
        print(json.dumps(record, indent=2, sort_keys=True))
        return 0

    commit = os.environ.get("RELEASE_COMMIT") or os.environ.get("GITHUB_SHA", "")
    approvals_commit = os.environ.get("RELEASE_APPROVALS_COMMIT", "")
    ci_path = Path(os.environ.get("CI_EVIDENCE_FILE", "dist/ci-evidence.json"))
    mobile_path = Path(os.environ.get("MOBILE_ARTIFACTS_FILE", "dist/mobile-artifacts.json"))
    image = os.environ.get("CONTAINER_IMAGE", "")
    digest = os.environ.get("CONTAINER_DIGEST", "")
    if not commit or not image or not digest:
        print("release evidence needs RELEASE_COMMIT, CONTAINER_IMAGE and CONTAINER_DIGEST", file=sys.stderr)
        return 1
    try:
        policy = load(ROOT / "release/release-policy.json")
        ci = load((ROOT / ci_path).resolve())
        mobile_file = (ROOT / mobile_path).resolve()
        if not mobile_file.is_file():
            raise ValueError(f"signed mobile artifact evidence is missing (G24): {mobile_file}")
        go_version = (ROOT / ".go-version").read_text(encoding="utf-8")
        manifest = build_manifest(
            policy,
            ci,
            commit,
            image,
            digest,
            go_version,
            git_approval_loader(approvals_commit),
            load(mobile_file).get("artifacts"),
            approvals_commit,
        )
        print(json.dumps(manifest, indent=2, sort_keys=True))
        return 0
    except (ValueError, OSError, UnicodeDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
