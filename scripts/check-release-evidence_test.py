#!/usr/bin/env python3
"""Adversarial tests for the release evidence validator."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check-release-evidence.py"
# Set by fixture() to real commits of the fixture's own git repository.
COMMIT = ""
TREE = ""
APPROVALS_COMMIT = ""
OTHER_COMMIT = "fedcba9876543210fedcba9876543210fedcba98"
CI_RUN_ID = 123
APPROVAL_FILES = {
    "production_crypto": "production-crypto.json",
    "independent_review": "independent-review.json",
}
GIT_ENV = {
    **{key: value for key, value in os.environ.items() if not key.startswith("GIT_")},
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
    "GIT_COMMITTER_NAME": "fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
}
JOBS = {
    "server": "success",
    "crypto": "success",
    "mobile": "success",
    "mobile-ios": "success",
    "compose-smoke": "success",
    "licenses": "success",
    "vulnerabilities": "success",
}
MOBILE_POLICY = {
    "record_schema": "veritra-mobile-artifact/1",
    "required": [{"platform": "ios", "artifact_type": "signed-release"}],
    "simulator_ci_jobs": {"ios": "mobile-ios"},
}
SIGNED_IPA = "Veritra-ios.ipa"
SIMULATOR_ZIP = "veritra-demo-ios-simulator.zip"

spec = importlib.util.spec_from_file_location("write_release_evidence", ROOT / "scripts/write-release-evidence.py")
assert spec and spec.loader
writer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(writer)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


# --- Synthetic iOS artifacts. No signing material: every "signature",
# "profile" and "code signature" below is placeholder bytes.

ARM64 = 0x0100000C
X86_64 = 0x01000007


def macho(*, platform: int = 2, cputype: int = ARM64, code_signature: bool = True) -> bytes:
    commands = struct.pack("<IIIIII", 0x32, 24, platform, 0x000D0000, 0x00120000, 0)
    count = 1
    if code_signature:
        commands += struct.pack("<IIII", 0x1D, 16, 4096, 16)
        count += 1
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, cputype, 0, 2, count, len(commands), 0, 0)
    return header + commands + b"\0" * 64


def fat(*slices: bytes) -> bytes:
    offset = 4096
    header = struct.pack(">II", 0xCAFEBABE, len(slices))
    body = b""
    for piece in slices:
        cputype = struct.unpack_from("<i", piece, 4)[0]
        header += struct.pack(">iiIII", cputype, 0, offset + len(body), len(piece), 12)
        body += piece
    return header.ljust(offset, b"\0") + body


def profile(get_task_allow: bool) -> bytes:
    plist = plistlib.dumps({"Name": "synthetic fixture", "Entitlements": {"get-task-allow": get_task_allow}})
    return b"SYNTHETIC-CMS-PLACEHOLDER" + plist + b"SYNTHETIC-CMS-PLACEHOLDER"


def build_app_zip(
    path: Path,
    *,
    prefix: str = "Payload/Runner.app/",
    platform_name: str = "iphoneos",
    supported: tuple[str, ...] = ("iPhoneOS",),
    executable: bytes | None = None,
    code_resources: bool = True,
    provisioning: bytes | None = None,
    extra_apps: tuple[str, ...] = (),
) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        info = {"CFBundleExecutable": "Runner", "DTPlatformName": platform_name, "CFBundleSupportedPlatforms": list(supported)}
        archive.writestr(prefix + "Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        archive.writestr(prefix + "Runner", macho() if executable is None else executable)
        if code_resources:
            archive.writestr(prefix + "_CodeSignature/CodeResources", b"synthetic placeholder")
        if provisioning is not None:
            archive.writestr(prefix + "embedded.mobileprovision", provisioning)
        archive.writestr(prefix + "Frameworks/App.framework/App", b"synthetic")
        for app in extra_apps:
            archive.writestr(f"Payload/{app}/Info.plist", b"")
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def build_signed_ipa(path: Path, **overrides: object) -> str:
    options: dict[str, object] = {"provisioning": profile(False)}
    options.update(overrides)
    return build_app_zip(path, **options)  # type: ignore[arg-type]


def build_simulator_app(path: Path, prefix: str) -> str:
    # The shape the mobile-ios CI job builds: iphonesimulator, arm64 simulator
    # Mach-O, ad-hoc code resources and no provisioning profile.
    return build_app_zip(
        path,
        prefix=prefix,
        platform_name="iphonesimulator",
        supported=("iPhoneSimulator",),
        executable=macho(platform=7),
    )


def signed_record(file_name: str, digest: str) -> dict[str, object]:
    return {
        "schema": "veritra-mobile-artifact/1",
        "platform": "ios",
        "artifact_type": "signed-release",
        "commit": COMMIT,
        "file": file_name,
        "digest": digest,
        "build": {"sdk": "iphoneos", "configuration": "release", "entry_point": "lib/main.dart"},
        "signing": {"status": "signed", "identity": "distribution", "verifier": "codesign", "verification": "pass"},
        "provenance": {
            "builder": "github-actions",
            "workflow": ".github/workflows/ios-signed.yml",
            "job": "ios-signed-release",
            "run_id": "456",
            "source_commit": COMMIT,
        },
    }


APPROVALS_POLICY = {
    "production_crypto": {
        "path": "release/approvals/{commit}/production-crypto.json",
        "status": "approved",
        "behavior_test": "pass",
        "not_author": True,
    },
    "independent_review": {
        "path": "release/approvals/{commit}/independent-review.json",
        "status": "approved",
        "not_author": True,
    },
}


# --- A real git repository: a base commit, the frozen candidate, then the
# approvals in a later commit, then unrelated later work on the branch.


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(root), *args], check=True, capture_output=True, text=True, env=GIT_ENV
    ).stdout.strip()


def commit_on(root: Path, start: str, files: dict[str, bytes | None], message: str = "change") -> str:
    """Commit ``files`` (None deletes) on a detached HEAD at ``start``."""
    if start:
        git(root, "checkout", "-q", "--detach", start)
    for path, content in files.items():
        if content is None:
            git(root, "rm", "-q", path)
            continue
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        git(root, "add", path)
    git(root, "commit", "-q", "-m", message)
    return git(root, "rev-parse", "HEAD")


def merge_on(root: Path, first: str, second: str) -> str:
    git(root, "checkout", "-q", "--detach", first)
    git(root, "merge", "-q", "--no-ff", "-m", "merge", second)
    return git(root, "rev-parse", "HEAD")


def approval_path(name: str, commit: str | None = None) -> str:
    return f"release/approvals/{commit or COMMIT}/{APPROVAL_FILES[name]}"


def approval_record(name: str, **changes: object) -> dict[str, object]:
    record: dict[str, object] = {
        "schema": "veritra-release-approval/1",
        "approval": name,
        "status": "approved",
        "reviewed_commit": COMMIT,
        "reviewed_tree": TREE,
        "reviewer": f"{name}-reviewer",
        "reviewer_is_author": False,
    }
    if name == "production_crypto":
        record["behavior_test"] = "pass"
    for key, value in changes.items():
        if value is REMOVE:
            record.pop(key, None)
        else:
            record[key] = value
    return record


REMOVE = object()


def approval_bytes(record: object) -> bytes:
    return (json.dumps(record, indent=2, sort_keys=True) + "\n").encode("utf-8")


def approval_files(**records: object) -> dict[str, bytes | None]:
    """Both approvals for the candidate; keyword arguments replace one."""
    files: dict[str, bytes | None] = {}
    for name in APPROVAL_FILES:
        value = records.get(name, approval_record(name))
        files[approval_path(name)] = value if isinstance(value, bytes) or value is None else approval_bytes(value)
    return files


def manifest_approvals(root: Path, approvals_commit: str) -> dict[str, object]:
    recorded: dict[str, object] = {"commit": approvals_commit}
    for name in APPROVAL_FILES:
        blob = subprocess.run(
            ["git", "-C", str(root), "cat-file", "blob", f"{approvals_commit}:{approval_path(name)}"],
            check=True,
            capture_output=True,
            env=GIT_ENV,
        ).stdout
        recorded[name] = {
            "path": approval_path(name),
            "digest": "sha256:" + hashlib.sha256(blob).hexdigest(),
            "record": json.loads(blob),
        }
    return recorded


def fixture() -> tuple[Path, dict[str, object]]:
    global COMMIT, TREE, APPROVALS_COMMIT
    temp = Path(tempfile.mkdtemp(prefix="veritra-release-evidence-"))
    git(temp, "init", "-q", "-b", "main")
    base = commit_on(temp, "", {"README": b"base\n"}, "base")
    COMMIT = commit_on(temp, base, {"src.txt": b"frozen candidate\n"}, "candidate")
    TREE = git(temp, "rev-parse", f"{COMMIT}^{{tree}}")
    approved = commit_on(temp, COMMIT, approval_files(), "approve the candidate")
    # Later, unrelated work on the protected branch does not disturb them.
    APPROVALS_COMMIT = commit_on(temp, approved, {"README": b"later work\n"}, "later work")
    git(temp, "checkout", "-q", "--detach", COMMIT)
    # Untracked, so checkouts in the cases below never touch them.
    (temp / ".go-version").write_text("1.25.12\n", encoding="utf-8")
    policy = {
        "schema_version": 3,
        "required_ci_jobs": list(JOBS),
        "mobile_artifacts": MOBILE_POLICY,
        "approvals": APPROVALS_POLICY,
    }
    write_json(temp / "release/release-policy.json", policy)
    signed_digest = build_signed_ipa(temp / "dist" / SIGNED_IPA)
    manifest = {
        "schema_version": 3,
        "candidate_commit": COMMIT,
        "binary_commit": COMMIT,
        "ci_run_id": CI_RUN_ID,
        "ci_conclusion": "success",
        "ci_jobs": JOBS.copy(),
        "approvals": manifest_approvals(temp, APPROVALS_COMMIT),
        "container": {
            "image": "ghcr.io/example/veritra:v1",
            "digest": "sha256:" + "a" * 64,
            "commit": COMMIT,
            "toolchain": "1.25.12",
        },
        "mobile_artifacts": [signed_record(SIGNED_IPA, signed_digest)],
    }
    write_json(temp / "dist/release-evidence.json", manifest)
    return temp, manifest


def run(root: Path, *extra: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    # A later --approvals-commit in ``extra`` overrides the default one.
    environment = {
        key: value for key, value in os.environ.items() if key != "MOBILE_ARTIFACTS_DIR" and not key.startswith("GIT_")
    }
    environment.update(env or {})
    return subprocess.run(
        [
            sys.executable,
            str(CHECKER),
            "--root",
            str(root),
            "--expected-commit",
            COMMIT,
            "--approvals-commit",
            APPROVALS_COMMIT,
            *extra,
        ],
        text=True,
        capture_output=True,
        check=False,
        env=environment,
    )


def expect_valid(root: Path, manifest: dict[str, object], *extra: str, env: dict[str, str] | None = None) -> None:
    write_json(root / "dist/release-evidence.json", manifest)
    result = run(root, *extra, env=env)
    if result.returncode != 0:
        raise AssertionError(f"expected valid evidence to pass: {result.stderr.strip()}")


def expect_blocked(
    root: Path,
    manifest: dict[str, object],
    *reasons: str,
    absent: tuple[str, ...] = (),
    extra: tuple[str, ...] = (),
    env: dict[str, str] | None = None,
) -> None:
    # Each negative case must fail for its own reason, not a leftover one.
    write_json(root / "dist/release-evidence.json", manifest)
    result = run(root, *extra, env=env)
    missing = [reason for reason in reasons if reason not in result.stderr]
    leaked = [text for text in absent if text in result.stderr]
    if result.returncode == 0 or missing or leaked:
        raise AssertionError(
            f"expected {missing or reasons!r} without {leaked!r}, got rc={result.returncode}: {result.stderr.strip()}"
        )


def qa01_cases(root: Path, manifest: dict[str, object]) -> None:
    # A renamed/moved placeholder cannot satisfy positive approval evidence.
    approvals = manifest["approvals"]
    crypto = approvals.pop("production_crypto")
    expect_blocked(root, manifest, "has no production_crypto approval")
    approvals["production_crypto"] = crypto
    expect_valid(root, manifest)

    manifest["ci_jobs"]["mobile-ios"] = "skipped"
    expect_blocked(root, manifest, "required CI job 'mobile-ios' is missing or not successful")
    manifest["ci_jobs"]["mobile-ios"] = "success"

    # The manifest cannot say more than git holds at the approvals commit.
    review = approvals["independent_review"]["record"]
    review["status"] = "pending"
    expect_blocked(root, manifest, "independent_review approval does not match the approvals commit")
    review["status"] = "approved"

    review["reviewer_is_author"] = True
    expect_blocked(root, manifest, "independent_review approval does not match the approvals commit")
    review["reviewer_is_author"] = False

    manifest["binary_commit"] = OTHER_COMMIT
    expect_blocked(root, manifest, "packaged binary commit evidence does not match candidate")
    manifest["binary_commit"] = COMMIT

    manifest["container"]["digest"] = "sha256:" + "a" * 63
    expect_blocked(root, manifest, "container digest is not an immutable sha256 digest")
    manifest["container"]["digest"] = "sha256:" + "a" * 64

    manifest["container"]["commit"] = OTHER_COMMIT
    expect_blocked(root, manifest, "container commit label does not match candidate")
    manifest["container"]["commit"] = COMMIT

    expect_valid(root, manifest)


def approval_cases(root: Path, valid: dict[str, object]) -> None:
    """Approvals come from a later commit that descends from the candidate."""
    base = git(root, "rev-parse", f"{COMMIT}^")

    def check(approvals_commit: str, *reasons: str, preflight: bool = False) -> None:
        manifest = copy.deepcopy(valid)
        extra = ("--approvals-commit", approvals_commit) + (("--preflight",) if preflight else ())
        if reasons:
            expect_blocked(root, manifest, *reasons, extra=extra)
        else:
            manifest["approvals"] = manifest_approvals(root, approvals_commit)
            expect_valid(root, manifest, *extra)

    def approved(**records: object) -> str:
        return commit_on(root, COMMIT, approval_files(**records), "approve")

    # Accepted: the fixture's tip (approvals, then later work); the approval
    # commit itself; approvals merged as a pull request; each approval in
    # its own change; the preflight gate alone.
    check(APPROVALS_COMMIT)
    check(APPROVALS_COMMIT, preflight=True)
    check(approved())
    main_moved_on = commit_on(root, COMMIT, {"README": b"main moved on\n"})
    check(merge_on(root, main_moved_on, approved()))
    files = approval_files()
    first, second = list(files)
    one = commit_on(root, COMMIT, {first: files[first]})
    check(commit_on(root, commit_on(root, one, {"README": b"between\n"}), {second: files[second]}))

    # No approvals commit, or not a usable one.
    for bad in ("", "abc", APPROVALS_COMMIT.upper(), APPROVALS_COMMIT[:39]):
        check(bad, "approvals commit is not a full lowercase SHA-1")
        check(bad, "approvals commit is not a full lowercase SHA-1", preflight=True)
    check("f" * 40, "approvals commit is not in this repository")
    # A file cannot name the commit it is in, so the candidate itself never
    # holds its approvals.
    check(COMMIT, "approvals commit must be a later commit than the candidate")
    # Approvals on a line that never contained the candidate.
    sibling = commit_on(root, base, approval_files(), "approve from the side")
    check(sibling, "approvals commit does not descend from the candidate commit")

    # A pull request head may hold perfect approvals; the protected branch
    # tip without them still blocks, and the workflow never reads PR refs.
    pull_request_head = approved()
    protected_tip = commit_on(root, COMMIT, {"README": b"no approvals merged\n"})
    check(protected_tip, "production_crypto approval is missing", "independent_review approval is missing")
    check(merge_on(root, protected_tip, pull_request_head))

    # Approvals for another commit, or at another commit's path.
    check(approved(production_crypto=approval_record("production_crypto", reviewed_commit=OTHER_COMMIT)),
          f"production_crypto approval is not bound to candidate {COMMIT}")
    elsewhere = commit_on(root, COMMIT, {
        approval_path(name, OTHER_COMMIT): approval_bytes(approval_record(name)) for name in APPROVAL_FILES
    })
    check(elsewhere, "production_crypto approval is missing from the approvals commit")
    check(approved(independent_review=approval_record("independent_review", reviewed_tree="0" * 40)),
          "independent_review approval is not bound to the candidate source tree")
    check(approved(production_crypto=approval_record("production_crypto", reviewed_tree=REMOVE)),
          "production_crypto approval fields do not match the protected approval schema")

    # One approval cannot stand in for the other.
    swapped = approval_record("independent_review", behavior_test="pass")
    check(approved(production_crypto=swapped), "production_crypto approval names a different approval")

    # Content.
    check(approved(independent_review=approval_record("independent_review", status="pending")),
          "independent_review approval is not 'approved'")
    check(approved(production_crypto=approval_record("production_crypto", behavior_test="fail")),
          "production_crypto behavior evidence is not 'pass'")
    for author in (True, None, "false", 0):
        check(approved(independent_review=approval_record("independent_review", reviewer_is_author=author)),
              "independent_review reviewer is not independently identified")
    for reviewer in ("", "   ", None, 7):
        check(approved(independent_review=approval_record("independent_review", reviewer=reviewer)),
              "missing independent_review reviewer")
    check(approved(independent_review=approval_record("independent_review", schema="veritra-release-approval/0")),
          "independent_review approval schema is not veritra-release-approval/1")
    check(approved(independent_review=approval_record("independent_review", notes="extra")),
          "independent_review approval fields do not match the protected approval schema")
    check(approved(independent_review=approval_record("independent_review", behavior_test="pass")),
          "independent_review approval fields do not match the protected approval schema")
    check(approved(production_crypto=approval_record("production_crypto", behavior_test=REMOVE)),
          "production_crypto approval fields do not match the protected approval schema")
    check(approved(independent_review=approval_bytes([approval_record("independent_review")])),
          "independent_review approval fields do not match the protected approval schema")
    check(approved(independent_review=b"{not json"), "independent_review approval is not valid JSON")
    check(approved(independent_review=b"\xff\xfe"), "independent_review approval is not valid JSON")
    check(approved(independent_review=b" " * (64 * 1024 + 1)), "independent_review approval is too large")

    # An approval must land in its own change, after the candidate.
    smuggled = commit_on(root, COMMIT, {**approval_files(), "src.txt": b"changed with the approval\n"})
    check(smuggled, "production_crypto approval did not land in its own change touching only release/approvals/")
    branch = commit_on(root, approved(), {"src.txt": b"code in the same pull request\n"})
    check(merge_on(root, main_moved_on, branch), "did not land in its own change")
    with_other_candidate = commit_on(root, COMMIT, {
        **approval_files(), approval_path("production_crypto", OTHER_COMMIT): b"{}\n"
    })
    check(with_other_candidate, "did not land in its own change")
    touched_later = commit_on(root, APPROVALS_COMMIT, {
        approval_path("independent_review"): approval_bytes(approval_record("independent_review", reviewer="renamed")),
        "README": b"and something else\n",
    })
    check(touched_later, "independent_review approval did not land in its own change")
    # The candidate sat on a side branch while the approval landed on main;
    # the approval change came before the candidate reached the branch.
    side = commit_on(root, base, {"README": b"main before the candidate\n"})
    early = commit_on(root, side, approval_files())
    check(merge_on(root, early, COMMIT), "production_crypto approval landed before the candidate commit")

    # The manifest must hold exactly what git holds at the approvals commit.
    def tampered(mutate) -> dict[str, object]:
        manifest = copy.deepcopy(valid)
        mutate(manifest["approvals"])
        return manifest

    expect_blocked(root, tampered(lambda a: a.__setitem__("commit", COMMIT)),
                   "release evidence approvals are not from the verified approvals commit")
    expect_blocked(root, tampered(lambda a: a["production_crypto"].__setitem__("digest", "sha256:" + "0" * 64)),
                   "release evidence production_crypto approval does not match the approvals commit")
    expect_blocked(root, tampered(lambda a: a["production_crypto"].__setitem__("path", "release/production-crypto-approval.json")),
                   "release evidence production_crypto approval does not match the approvals commit")
    expect_blocked(root, tampered(lambda a: a["production_crypto"]["record"].__setitem__("reviewer", "someone else")),
                   "release evidence production_crypto approval does not match the approvals commit")
    expect_blocked(root, tampered(lambda a: a.__setitem__("extra", {})),
                   "release evidence approvals do not match the protected set")
    expect_blocked(root, tampered(lambda a: a.pop("independent_review")), "release evidence has no independent_review approval")
    manifest = copy.deepcopy(valid)
    manifest.pop("approvals")
    expect_blocked(root, manifest, "release evidence has no approvals record")
    # The schema 2 shape, with approvals inlined at the top level, is stale.
    legacy = copy.deepcopy(valid)
    legacy.pop("approvals")
    legacy["schema_version"] = 2
    legacy["production_crypto"] = valid["approvals"]["production_crypto"]["record"]
    expect_blocked(root, legacy, "release evidence schema version is not current", "release evidence has no approvals record")

    # The approval rules cannot be moved back into the candidate tree.
    policy_path = root / "release/release-policy.json"
    original_policy = policy_path.read_text(encoding="utf-8")
    for tampered_approvals in (
        dict(APPROVALS_POLICY, production_crypto=dict(APPROVALS_POLICY["production_crypto"], path="release/production-crypto-approval.json")),
        {"independent_review": APPROVALS_POLICY["independent_review"]},
        dict(APPROVALS_POLICY, independent_review=dict(APPROVALS_POLICY["independent_review"], not_author=False)),
    ):
        policy = json.loads(original_policy)
        policy["approvals"] = tampered_approvals
        write_json(policy_path, policy)
        expect_blocked(root, valid, "release policy approvals do not match the protected set")
    policy_path.write_text(original_policy, encoding="utf-8")
    git(root, "checkout", "-q", "--detach", COMMIT)
    expect_valid(root, valid)


def qa02_cases(root: Path, valid: dict[str, object]) -> None:
    dist = root / "dist"
    signed = valid["mobile_artifacts"][0]
    no_signed = "release evidence has no valid ios signed-release artifact"
    label = "ios signed-release artifact"

    def variant(mutate) -> dict[str, object]:
        manifest = copy.deepcopy(valid)
        mutate(manifest)
        return manifest

    def with_record(record: dict[str, object]) -> dict[str, object]:
        return variant(lambda m: m.__setitem__("mobile_artifacts", [record]))

    def record(**changes: object) -> dict[str, object]:
        value = copy.deepcopy(signed)
        for key, change in changes.items():
            if isinstance(change, dict) and isinstance(value.get(key), dict):
                value[key].update(change)
            else:
                value[key] = change
        return value

    def signed_bytes(name: str, **options: object) -> dict[str, object]:
        digest = build_signed_ipa(dist / name, **options)
        return record(file=name, digest=digest)

    # Missing evidence.
    expect_blocked(root, variant(lambda m: m.pop("mobile_artifacts")), "has no mobile artifact records", no_signed)
    expect_blocked(root, with_record_list([], valid), no_signed)
    expect_blocked(root, variant(lambda m: m.__setitem__("mobile_artifacts", {"ios": signed})), "has no mobile artifact records")

    # Simulator-only: exactly what the mobile-ios CI job publishes. The record
    # itself is valid simulator-debug evidence, and it still cannot release.
    build_simulator_app(dist / SIMULATOR_ZIP, "Runner.app/")  # ditto --keepParent layout
    simulator = writer.simulator_record(COMMIT, "789", dist / SIMULATOR_ZIP)
    expect_blocked(root, with_record_list([simulator], valid), no_signed, absent=("simulator-debug artifact",))
    # Simulator record next to a valid signed one is fine (informational only).
    expect_valid(root, with_record_list([simulator, signed], valid))

    # Simulator evidence relabelled as signed-release.
    relabelled = copy.deepcopy(simulator)
    relabelled["artifact_type"] = "signed-release"
    expect_blocked(
        root,
        with_record_list([relabelled], valid),
        f"{label} file name is not a plain .ipa name",
        f"{label} build is not iphoneos/release",
        f"{label} signing status is not 'signed'",
        f"{label} signature was not verified as a distribution signature",
        f"{label} provenance is the debug simulator CI build",
        no_signed,
    )
    # Simulator bytes wrapped as an .ipa behind an otherwise perfect record.
    wrapped = record(file="wrapped-simulator.ipa", digest=build_simulator_app(dist / "wrapped-simulator.ipa", "Payload/Runner.app/"))
    expect_blocked(
        root,
        with_record(wrapped),
        "signed ios artifact is not built for iphoneos devices",
        "signed ios app bundle has no embedded provisioning profile",
        "signed ios executable is not built for iOS devices",
        no_signed,
    )
    # Forged device Info.plist and profile over a simulator executable.
    expect_blocked(root, with_record(signed_bytes("forged-plist.ipa", executable=macho(platform=7))), "signed ios executable is not built for iOS devices", no_signed)
    expect_blocked(root, with_record(signed_bytes("x86.ipa", executable=macho(cputype=X86_64))), "signed ios executable is not an arm64 device Mach-O")
    expect_blocked(root, with_record(signed_bytes("fat-mixed.ipa", executable=fat(macho(), macho(cputype=X86_64)))), "not an arm64 device Mach-O")
    expect_blocked(root, with_record(signed_bytes("fat-sim.ipa", executable=fat(macho(), macho(platform=7)))), "not built for iOS devices")
    expect_blocked(root, with_record(signed_bytes("garbage-macho.ipa", executable=struct.pack("<IiiIIIII", 0xFEEDFACF, ARM64, 0, 2, 3, 0xFFFF, 0, 0))), "is not a readable Mach-O")
    expect_blocked(root, with_record(signed_bytes("short-macho.ipa", executable=b"\xcf\xfa")), "is not a readable Mach-O")
    short_build = struct.pack("<IIII", 0x32, 16, 2, 0) + struct.pack("<IIII", 0x1D, 16, 4096, 16)
    short_header = struct.pack("<IiiIIIII", 0xFEEDFACF, ARM64, 0, 2, 2, len(short_build), 0, 0)
    expect_blocked(root, with_record(signed_bytes("short-build.ipa", executable=short_header + short_build)), "is not a readable Mach-O")
    expect_valid(root, with_record(signed_bytes("fat-device.ipa", executable=fat(macho()))))
    # Same digest as a simulator build cannot be both.
    twin = copy.deepcopy(simulator)
    twin["digest"] = signed["digest"]
    expect_blocked(root, with_record_list([twin, signed], valid), "ios signed-release artifact has the same digest as a simulator build")

    # Skipped or missing simulator CI: a signed artifact never replaces it.
    expect_blocked(root, variant(lambda m: m["ci_jobs"].__setitem__("mobile-ios", "skipped")), "required CI job 'mobile-ios' is missing or not successful")
    expect_blocked(root, variant(lambda m: m["ci_jobs"].pop("mobile-ios")), "required CI job 'mobile-ios' is missing or not successful")

    # Unsigned: honest record, and a record that claims a signature the bytes lack.
    expect_blocked(root, with_record(record(signing={"status": "unsigned"})), f"{label} signing status is not 'signed'", no_signed)
    unsigned_bytes = signed_bytes("unsigned.ipa", executable=macho(code_signature=False), code_resources=False, provisioning=None)
    expect_blocked(
        root,
        with_record(unsigned_bytes),
        "signed ios app bundle has no code signature resources",
        "signed ios app bundle has no embedded provisioning profile",
        "signed ios executable has no code signature",
        no_signed,
    )
    expect_blocked(root, with_record(signed_bytes("no-lc-sig.ipa", executable=macho(code_signature=False))), "signed ios executable has no code signature")
    # Development-signed or unverified signatures are not release evidence.
    expect_blocked(root, with_record(signed_bytes("development.ipa", provisioning=profile(True))), "signed ios provisioning profile is not a distribution profile")
    expect_blocked(root, with_record(signed_bytes("bad-profile.ipa", provisioning=b"not a profile")), "provisioning profile has no readable property list")
    for signing in ({"identity": "development"}, {"verification": "fail"}, {"verifier": ""}):
        expect_blocked(root, with_record(record(signing=signing)), f"{label} signature was not verified as a distribution signature")

    # Wrong commit (stale evidence).
    expect_blocked(root, with_record(record(commit=OTHER_COMMIT)), f"{label} is not bound to the candidate commit", no_signed)
    expect_blocked(root, with_record(record(provenance={"source_commit": OTHER_COMMIT})), f"{label} provenance is not bound to the candidate commit", no_signed)

    # Wrong platform.
    for platform in ("android", "iOS", "macos", None):
        expect_blocked(root, with_record(record(platform=platform)), "mobile artifact 0 has an unsupported platform or artifact type", no_signed)

    # Wrong type.
    expect_blocked(root, with_record(record(artifact_type="simulator-debug")), "ios simulator-debug artifact", no_signed)
    for kind in ("signed", "release", "signed-debug", None):
        expect_blocked(root, with_record(record(artifact_type=kind)), "unsupported platform or artifact type", no_signed)
    expect_blocked(root, with_record(record(build={"entry_point": "lib/main_demo.dart"})), f"{label} build is not iphoneos/release")
    expect_blocked(root, with_record(record(build={"configuration": "debug"})), f"{label} build is not iphoneos/release")
    expect_blocked(root, with_record(record(build={"sdk": "iphonesimulator"})), f"{label} build is not iphoneos/release")

    # Malformed digest, and well-formed digests that do not match the bytes.
    for digest in ("sha256:" + "b" * 63, "sha256:" + "B" * 64, "sha1:" + "b" * 40, "b" * 64, "", None, 7):
        expect_blocked(root, with_record(record(digest=digest)), f"{label} digest is not an immutable sha256 digest", no_signed)
    expect_blocked(root, with_record(record(digest="sha256:" + "b" * 64)), f"{label} file does not match its recorded digest", no_signed)

    # Missing or unsafe artifact files.
    expect_blocked(root, with_record(record(file="absent.ipa")), f"{label} file is missing from the artifact directory")
    for name in ("../Veritra-ios.ipa", "sub/Veritra-ios.ipa", ".hidden.ipa", "Veritra-ios.zip", ""):
        expect_blocked(root, with_record(record(file=name)), f"{label} file name is not a plain .ipa name")
    empty = root / "empty-artifacts"
    empty.mkdir()
    expect_blocked(root, valid, f"{label} file is missing", extra=("--artifacts-dir", str(empty)))
    expect_blocked(root, valid, f"{label} file is missing", env={"MOBILE_ARTIFACTS_DIR": str(empty)})
    elsewhere = root / "staged-artifacts"
    elsewhere.mkdir()
    shutil.copy(dist / SIGNED_IPA, elsewhere / SIGNED_IPA)
    expect_valid(root, valid, env={"MOBILE_ARTIFACTS_DIR": str(elsewhere)})
    not_zip = dist / "not-a-zip.ipa"
    not_zip.write_bytes(b"synthetic, not an archive")
    expect_blocked(root, with_record(record(file=not_zip.name, digest="sha256:" + hashlib.sha256(not_zip.read_bytes()).hexdigest())), "is not a readable iOS app archive")
    expect_blocked(root, with_record(signed_bytes("two-apps.ipa", extra_apps=("Other.app",))), "must hold exactly one Payload/*.app bundle")

    # Provenance must be a separate GitHub Actions build, never the simulator CI.
    for provenance in (
        {"workflow": ".github/workflows/ci.yml"},
        {"job": "mobile-ios"},
        {"run_id": str(CI_RUN_ID)},
        {"run_id": "0" + str(CI_RUN_ID)},  # review finding: string compare missed this
    ):
        expect_blocked(root, with_record(record(provenance=provenance)), f"{label} provenance is the debug simulator CI build")
    for provenance in (
        {"builder": "local"},
        {"workflow": "ci.yml"},
        {"workflow": "../workflows/x.yml"},
        {"job": ""},
        {"run_id": 456},
        {"run_id": "abc"},
        {"run_id": "１２３"},  # full-width digits pass str.isdigit
        {"run_id": ""},
    ):
        expect_blocked(root, with_record(record(provenance=provenance)), f"{label} provenance does not name a GitHub Actions workflow, job and run")

    # Schema shape.
    expect_blocked(root, with_record(record(signed=True)), "mobile artifact 0 fields do not match the protected record schema")
    without_provenance = record()
    without_provenance.pop("provenance")
    expect_blocked(root, with_record(without_provenance), "fields do not match the protected record schema")
    expect_blocked(root, with_record(record(schema="veritra-mobile-artifact/0")), "record schema is not veritra-mobile-artifact/1")
    expect_blocked(root, with_record(record(signing="signed")), "build, signing and provenance must be objects")
    expect_blocked(root, with_record_list([signed, copy.deepcopy(signed)], valid), "more than one ios signed-release artifact")
    expect_blocked(root, with_record_list(["signed"], valid), "mobile artifact 0 fields do not match")

    # A stale (schema 1) manifest without mobile records is not current.
    expect_blocked(root, variant(lambda m: m.__setitem__("schema_version", 1)), "release evidence schema version is not current")

    # The requirement cannot be dropped from the policy.
    policy_path = root / "release/release-policy.json"
    original_policy = policy_path.read_text(encoding="utf-8")
    for tampered in (
        dict(MOBILE_POLICY, required=[]),
        dict(MOBILE_POLICY, required=[{"platform": "ios", "artifact_type": "simulator-debug"}]),
        dict(MOBILE_POLICY, simulator_ci_jobs={}),
    ):
        policy = json.loads(original_policy)
        policy["mobile_artifacts"] = tampered
        write_json(policy_path, policy)
        expect_blocked(root, valid, "release policy mobile artifact rules do not match the protected set")
    policy = json.loads(original_policy)
    policy.pop("mobile_artifacts")
    write_json(policy_path, policy)
    expect_blocked(root, valid, "release policy mobile artifact rules do not match the protected set")
    policy_path.write_text(original_policy, encoding="utf-8")

    # The writer's manifest shape passes, with the simulator record alongside.
    written = writer.build_manifest(
        json.loads(original_policy),
        {"run_id": CI_RUN_ID, "conclusion": "success", "jobs": JOBS.copy()},
        COMMIT,
        valid["container"]["image"],
        valid["container"]["digest"],
        "1.25.12\n",
        writer.git_approval_loader(APPROVALS_COMMIT, root),
        [simulator, signed],
        APPROVALS_COMMIT,
    )
    expect_valid(root, written)

    # One valid synthetic signed artifact passes.
    expect_valid(root, valid)


def with_record_list(records: list[object], valid: dict[str, object]) -> dict[str, object]:
    manifest = copy.deepcopy(valid)
    manifest["mobile_artifacts"] = copy.deepcopy(records)
    return manifest


def main() -> int:
    root, manifest = fixture()
    try:
        expect_valid(root, manifest)
        qa01_cases(root, manifest)
        approval_cases(root, manifest)
        qa02_cases(root, manifest)
        # The repository policy must equal the protected rules the fixtures use.
        repo_policy = json.loads((ROOT / "release/release-policy.json").read_text(encoding="utf-8"))
        assert repo_policy["mobile_artifacts"] == MOBILE_POLICY, "repository policy drifted from the fixture"
        assert repo_policy["approvals"] == APPROVALS_POLICY, "repository approval rules drifted from the fixture"
        assert repo_policy["schema_version"] == 3
    finally:
        shutil.rmtree(root)
    print("release evidence adversarial tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
