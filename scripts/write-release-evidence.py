#!/usr/bin/env python3
"""Build the ephemeral release evidence manifest after artifact packaging."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


from typing import Callable


def build_manifest(
    policy: dict[str, object],
    ci: dict[str, object],
    commit: str,
    image: str,
    digest: str,
    go_version: str,
    approval_loader: Callable[[str], dict[str, object]],
) -> dict[str, object]:
    if len(commit) != 40 or any(char not in "0123456789abcdef" for char in commit):
        raise ValueError("RELEASE_COMMIT must be a 40-character lowercase hex SHA")
    if not image or not digest:
        raise ValueError("CONTAINER_IMAGE and CONTAINER_DIGEST are required")
    approvals = policy.get("approvals", {})
    if not isinstance(approvals, dict):
        raise ValueError("release policy has no approvals")
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
    }
    for name, config in approvals.items():
        if not isinstance(config, dict) or not isinstance(config.get("path"), str):
            raise ValueError(f"invalid approval configuration: {name}")
        manifest[name] = approval_loader(config["path"])
    return manifest


def main() -> int:
    commit = os.environ.get("RELEASE_COMMIT") or os.environ.get("GITHUB_SHA", "")
    ci_path = Path(os.environ.get("CI_EVIDENCE_FILE", "dist/ci-evidence.json"))
    image = os.environ.get("CONTAINER_IMAGE", "")
    digest = os.environ.get("CONTAINER_DIGEST", "")
    if not commit or not image or not digest:
        print("release evidence needs RELEASE_COMMIT, CONTAINER_IMAGE and CONTAINER_DIGEST", file=sys.stderr)
        return 1
    try:
        policy = load(ROOT / "release/release-policy.json")
        ci = load((ROOT / ci_path).resolve())
        go_version = (ROOT / ".go-version").read_text(encoding="utf-8")
        manifest = build_manifest(
            policy,
            ci,
            commit,
            image,
            digest,
            go_version,
            lambda rel_path: load(ROOT / rel_path),
        )
        print(json.dumps(manifest, indent=2, sort_keys=True))
        return 0
    except (ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
