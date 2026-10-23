#!/usr/bin/env python3
"""Validate the positive, commit-bound release evidence contract.

Mobile artifacts (QA02) use one record schema for two separate artifact
types. ``simulator-debug`` is what hosted CI builds (job ``mobile-ios``); it is
validated when present but never counts as release evidence. The release needs
exactly one ``signed-release`` iOS record whose bytes are present, match the
recorded digest, and are structurally a device-signed app: Payload/*.app,
iphoneos Info.plist, arm64 iOS Mach-O with a code signature, and an embedded
distribution provisioning profile. These checks are structural only; signature
and attestation cryptography is verified by codesign and the G24 process.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import struct
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Any


COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
SCHEMA_VERSION = 2
REQUIRED_CI_JOBS = (
    "server",
    "crypto",
    "mobile",
    "mobile-ios",
    "compose-smoke",
    "licenses",
    "vulnerabilities",
)
MOBILE_RECORD_SCHEMA = "veritra-mobile-artifact/1"
SIGNED_RELEASE = "signed-release"
SIMULATOR_DEBUG = "simulator-debug"
SIMULATOR_CI_JOBS = {"ios": "mobile-ios"}
REQUIRED_MOBILE_ARTIFACTS = {
    "record_schema": MOBILE_RECORD_SCHEMA,
    "required": [{"platform": "ios", "artifact_type": SIGNED_RELEASE}],
    "simulator_ci_jobs": SIMULATOR_CI_JOBS,
}
CI_WORKFLOW = ".github/workflows/ci.yml"
RECORD_KEYS = frozenset(
    {"schema", "platform", "artifact_type", "commit", "file", "digest", "build", "signing", "provenance"}
)
# Per (platform, artifact_type): fixed build facts and the file suffix.
ARTIFACT_RULES = {
    ("ios", SIMULATOR_DEBUG): {
        "suffix": ".zip",
        "sdk": "iphonesimulator",
        "configuration": "debug",
        "entry_points": ("lib/main.dart", "lib/main_demo.dart"),
        "signing": "unsigned",
    },
    ("ios", SIGNED_RELEASE): {
        "suffix": ".ipa",
        "sdk": "iphoneos",
        "configuration": "release",
        "entry_points": ("lib/main.dart",),
        "signing": "signed",
    },
}
FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
RUN_ID_RE = re.compile(r"^[0-9]{1,20}$")  # ASCII only; str.isdigit accepts other scripts
WORKFLOW_RE = re.compile(r"^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$")
MAX_IPA_MEMBER = 256 * 1024 * 1024
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
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
        errors.append(f"release policy schema version is not protected version {SCHEMA_VERSION}")
    if policy.get("required_ci_jobs") != list(REQUIRED_CI_JOBS):
        errors.append("release policy required CI jobs do not match the protected set")
    if policy.get("mobile_artifacts") != REQUIRED_MOBILE_ARTIFACTS:
        errors.append("release policy mobile artifact rules do not match the protected set")
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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def macho_slices(data: bytes) -> list[bytes]:
    magic = struct.unpack_from(">I", data)[0]
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        return [data]
    count = struct.unpack_from(">I", data, 4)[0]
    if not 1 <= count <= 16:
        raise ValueError("bad fat header")
    slices = []
    for index in range(count):
        if magic == FAT_MAGIC:
            _, _, offset, size, _ = struct.unpack_from(">iiIII", data, 8 + 20 * index)
        else:
            _, _, offset, size, _, _ = struct.unpack_from(">iiQQII", data, 8 + 32 * index)
        if offset + size > len(data):
            raise ValueError("fat slice out of range")
        slices.append(data[offset : offset + size])
    return slices


def macho_errors(data: bytes) -> list[str]:
    """Every slice must be a code-signed arm64 Mach-O built for iOS devices."""
    try:
        for piece in macho_slices(data):
            magic, cputype, _, _, ncmds, sizeofcmds = struct.unpack_from("<IiiIII", piece)
            if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64:
                return ["signed ios executable is not an arm64 device Mach-O"]
            offset, end = 32, 32 + sizeofcmds
            if end > len(piece) or ncmds > 4096:
                raise ValueError("load commands out of range")
            platforms: set[int] = set()
            code_signature = False
            for _ in range(ncmds):
                cmd, cmdsize = struct.unpack_from("<II", piece, offset)
                if cmdsize < 8 or offset + cmdsize > end:
                    raise ValueError("bad load command")
                if cmd == LC_BUILD_VERSION:
                    if cmdsize < 24:
                        raise ValueError("short build version command")
                    platforms.add(struct.unpack_from("<I", piece, offset + 8)[0])
                elif cmd == LC_CODE_SIGNATURE:
                    code_signature = True
                offset += cmdsize
            if platforms != {PLATFORM_IOS}:
                return ["signed ios executable is not built for iOS devices"]
            if not code_signature:
                return ["signed ios executable has no code signature"]
    except (struct.error, ValueError):
        return ["signed ios executable is not a readable Mach-O"]
    return []


def profile_errors(blob: bytes) -> list[str]:
    # The profile is CMS-wrapped; only its embedded plist is read, never echoed.
    start, end = blob.find(b"<?xml"), blob.find(b"</plist>")
    if start < 0 or end < start:
        return ["signed ios provisioning profile has no readable property list"]
    try:
        profile = plistlib.loads(blob[start : end + len(b"</plist>")])
    except Exception:  # plistlib raises several types for malformed input
        return ["signed ios provisioning profile has no readable property list"]
    entitlements = profile.get("Entitlements") if isinstance(profile, dict) else None
    if not isinstance(entitlements, dict) or entitlements.get("get-task-allow") is not False:
        return ["signed ios provisioning profile is not a distribution profile"]
    return []


def read_member(archive: zipfile.ZipFile, name: str) -> bytes:
    info = archive.getinfo(name)
    if info.file_size > MAX_IPA_MEMBER:
        raise ValueError("member too large")
    return archive.read(info)


def ipa_errors(path: Path) -> list[str]:
    """Structural device-signing checks; cryptographic checks happen in G24."""
    try:
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())
            apps = {
                name.split("/")[1]
                for name in names
                if name.startswith("Payload/") and name.count("/") >= 2 and name.split("/")[1].endswith(".app")
            }
            if len(apps) != 1:
                return ["signed ios artifact must hold exactly one Payload/*.app bundle"]
            app = f"Payload/{apps.pop()}/"
            info = plistlib.loads(read_member(archive, app + "Info.plist"))
            if not isinstance(info, dict):
                return ["signed ios Info.plist is not a dictionary"]
            errors: list[str] = []
            if info.get("DTPlatformName") != "iphoneos" or info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
                errors.append("signed ios artifact is not built for iphoneos devices")
            executable = info.get("CFBundleExecutable")
            if not isinstance(executable, str) or not FILE_RE.fullmatch(executable):
                return errors + ["signed ios Info.plist has no valid executable name"]
            if app + "_CodeSignature/CodeResources" not in names:
                errors.append("signed ios app bundle has no code signature resources")
            if app + "embedded.mobileprovision" not in names:
                errors.append("signed ios app bundle has no embedded provisioning profile")
            else:
                errors.extend(profile_errors(read_member(archive, app + "embedded.mobileprovision")))
            if app + executable not in names:
                return errors + ["signed ios app bundle is missing its executable"]
            errors.extend(macho_errors(read_member(archive, app + executable)))
            return errors
    except Exception:  # BadZipFile, KeyError, plist and size errors all fail closed
        return ["signed ios artifact is not a readable iOS app archive"]


def check_mobile_record(
    index: int,
    record: Any,
    candidate: str,
    ci_run_id: Any,
    artifacts_dir: Path,
    errors: list[str],
) -> tuple[str, str, str] | None:
    """Validate one record; return (platform, type, digest) only if it is sound."""
    label = f"mobile artifact {index}"
    if not isinstance(record, dict) or set(record) != RECORD_KEYS:
        errors.append(f"{label} fields do not match the protected record schema")
        return None
    start = len(errors)
    if record.get("schema") != MOBILE_RECORD_SCHEMA:
        errors.append(f"{label} record schema is not {MOBILE_RECORD_SCHEMA}")
    platform, artifact_type = record.get("platform"), record.get("artifact_type")
    rules = None
    if isinstance(platform, str) and isinstance(artifact_type, str):
        rules = ARTIFACT_RULES.get((platform, artifact_type))
    if rules is None:
        errors.append(f"{label} has an unsupported platform or artifact type")
        return None
    label = f"{platform} {artifact_type} artifact"
    if record.get("commit") != candidate:
        errors.append(f"{label} is not bound to the candidate commit")
    file_name, digest = record.get("file"), record.get("digest")
    if not isinstance(file_name, str) or not FILE_RE.fullmatch(file_name) or not file_name.endswith(rules["suffix"]):
        errors.append(f"{label} file name is not a plain {rules['suffix']} name")
        file_name = None
    if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest):
        errors.append(f"{label} digest is not an immutable sha256 digest")
        digest = None

    build, signing, provenance = record.get("build"), record.get("signing"), record.get("provenance")
    if not all(isinstance(value, dict) for value in (build, signing, provenance)):
        errors.append(f"{label} build, signing and provenance must be objects")
        return None
    if (
        build.get("sdk") != rules["sdk"]
        or build.get("configuration") != rules["configuration"]
        or build.get("entry_point") not in rules["entry_points"]
    ):
        errors.append(f"{label} build is not {rules['sdk']}/{rules['configuration']} from an allowed entry point")
    if signing.get("status") != rules["signing"]:
        errors.append(f"{label} signing status is not {rules['signing']!r}")

    run_id = provenance.get("run_id")
    workflow, job = provenance.get("workflow"), provenance.get("job")
    if (
        provenance.get("builder") != "github-actions"
        or not isinstance(workflow, str)
        or not WORKFLOW_RE.fullmatch(workflow)
        or not isinstance(job, str)
        or not job
        or not isinstance(run_id, str)
        or not RUN_ID_RE.fullmatch(run_id)
    ):
        errors.append(f"{label} provenance does not name a GitHub Actions workflow, job and run")
    if provenance.get("source_commit") != candidate:
        errors.append(f"{label} provenance is not bound to the candidate commit")

    simulator_job = SIMULATOR_CI_JOBS[platform]
    if artifact_type == SIMULATOR_DEBUG:
        if workflow != CI_WORKFLOW or job != simulator_job:
            errors.append(f"{label} provenance is not the {simulator_job} CI job")
    else:
        if signing.get("identity") != "distribution" or signing.get("verification") != "pass" or not signing.get("verifier"):
            errors.append(f"{label} signature was not verified as a distribution signature")
        # Compare run IDs as integers so "0123" cannot dodge CI run 123.
        same_run = (
            isinstance(run_id, str)
            and RUN_ID_RE.fullmatch(run_id) is not None
            and RUN_ID_RE.fullmatch(str(ci_run_id)) is not None
            and int(run_id) == int(str(ci_run_id))
        )
        if workflow == CI_WORKFLOW or job == simulator_job or same_run:
            errors.append(f"{label} provenance is the debug simulator CI build")
        if file_name and digest:
            path = artifacts_dir / file_name
            if not path.is_file():
                errors.append(f"{label} file is missing from the artifact directory")
            elif sha256_file(path) != digest:
                errors.append(f"{label} file does not match its recorded digest")
            else:
                errors.extend(ipa_errors(path))
    if len(errors) != start or digest is None:
        return None
    return platform, artifact_type, digest


def validate_mobile_artifacts(
    manifest: dict[str, Any],
    candidate: str,
    artifacts_dir: Path,
    errors: list[str],
) -> None:
    records = manifest.get("mobile_artifacts")
    if not isinstance(records, list):
        errors.append("release evidence has no mobile artifact records")
        records = []
    sound = []
    for index, record in enumerate(records):
        result = check_mobile_record(index, record, candidate, manifest.get("ci_run_id"), artifacts_dir, errors)
        if result is not None:
            sound.append(result)
    simulator_digests = {digest for _, kind, digest in sound if kind == SIMULATOR_DEBUG}
    for required in REQUIRED_MOBILE_ARTIFACTS["required"]:
        key = (required["platform"], required["artifact_type"])
        name = " ".join(key)
        declared = [r for r in records if isinstance(r, dict) and (r.get("platform"), r.get("artifact_type")) == key]
        matches = [digest for platform, kind, digest in sound if (platform, kind) == key]
        if len(declared) > 1:
            errors.append(f"release evidence has more than one {name} artifact")
        elif not matches:
            errors.append(f"release evidence has no valid {name} artifact")
        elif matches[0] in simulator_digests:
            errors.append(f"{name} artifact has the same digest as a simulator build")


def validate_manifest(
    root: Path,
    policy: dict[str, Any],
    manifest: dict[str, Any],
    candidate: str,
    artifacts_dir: Path | None = None,
) -> list[str]:
    errors = validate_preflight(root, policy, candidate)
    if manifest.get("schema_version") != policy.get("schema_version"):
        errors.append("release evidence schema version is not current")
    if manifest.get("candidate_commit") != candidate:
        errors.append("release evidence is not bound to the candidate commit")
    if manifest.get("binary_commit") != candidate:
        errors.append("packaged binary commit evidence does not match candidate")
    ci_run_id = manifest.get("ci_run_id")
    if not isinstance(ci_run_id, (int, str)) or not RUN_ID_RE.fullmatch(str(ci_run_id)):
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

    if artifacts_dir is None:
        errors.append("no mobile artifact directory to verify signed artifacts against")
    else:
        validate_mobile_artifacts(manifest, candidate, artifacts_dir, errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--policy", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--expected-commit")
    parser.add_argument(
        "--artifacts-dir",
        type=Path,
        help="signed mobile artifact directory (default: $MOBILE_ARTIFACTS_DIR, else the evidence file's directory)",
    )
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
            env_dir = os.environ.get("MOBILE_ARTIFACTS_DIR")
            artifacts_dir = (args.artifacts_dir or (Path(env_dir) if env_dir else evidence_path.parent)).resolve()
            errors.extend(validate_manifest(root, policy, load_json(evidence_path), candidate, artifacts_dir))
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
