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


def main() -> int:
    commit = os.environ.get("RELEASE_COMMIT") or os.environ.get("GITHUB_SHA", "")
    ci_path = Path(os.environ.get("CI_EVIDENCE_FILE", "dist/ci-evidence.json"))
    image = os.environ.get("CONTAINER_IMAGE", "")
    digest = os.environ.get("CONTAINER_DIGEST", "")
    if len(commit) != 40 or not image or not digest:
        print("release evidence needs RELEASE_COMMIT, CONTAINER_IMAGE and CONTAINER_DIGEST", file=sys.stderr)
        return 1
    policy = load(ROOT / "release/release-policy.json")
    ci = load((ROOT / ci_path).resolve())
    approvals = policy.get("approvals", {})
    if not isinstance(approvals, dict):
        print("release policy has no approvals", file=sys.stderr)
        return 1
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
            "toolchain": (ROOT / ".go-version").read_text(encoding="utf-8").strip(),
        },
    }
    for name, config in approvals.items():
        if not isinstance(config, dict) or not isinstance(config.get("path"), str):
            print(f"invalid approval configuration: {name}", file=sys.stderr)
            return 1
        manifest[name] = load(ROOT / config["path"])
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
