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
COMMIT = "0123456789abcdef0123456789abcdef01234567"
OTHER_COMMIT = "fedcba9876543210fedcba9876543210fedcba98"
CI_RUN_ID = 123
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


def fixture() -> tuple[Path, dict[str, object]]:
    temp = Path(tempfile.mkdtemp(prefix="veritra-release-evidence-"))
    (temp / ".go-version").write_text("1.25.12\n", encoding="utf-8")
    policy = {
        "schema_version": 2,
        "required_ci_jobs": list(JOBS),
        "mobile_artifacts": MOBILE_POLICY,
        "approvals": {
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
        },
    }
    write_json(temp / "release/release-policy.json", policy)
    write_json(
        temp / "release/production-crypto-approval.json",
        {
            "status": "approved",
            "behavior_test": "pass",
            "reviewed_commit": COMMIT,
            "reviewer": "crypto-reviewer",
            "reviewer_is_author": False,
        },
    )
    write_json(
        temp / "release/independent-review-approval.json",
        {
            "status": "approved",
            "reviewed_commit": COMMIT,
            "reviewer": "independent-reviewer",
            "reviewer_is_author": False,
        },
    )
    signed_digest = build_signed_ipa(temp / "dist" / SIGNED_IPA)
    manifest = {
        "schema_version": 2,
        "candidate_commit": COMMIT,
        "binary_commit": COMMIT,
        "ci_run_id": CI_RUN_ID,
        "ci_conclusion": "success",
        "ci_jobs": JOBS.copy(),
        "production_crypto": {
            "status": "approved",
            "behavior_test": "pass",
            "reviewed_commit": COMMIT,
            "reviewer": "crypto-reviewer",
            "reviewer_is_author": False,
        },
        "independent_review": {
            "status": "approved",
            "reviewed_commit": COMMIT,
            "reviewer": "independent-reviewer",
            "reviewer_is_author": False,
        },
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
    environment = {key: value for key, value in os.environ.items() if key != "MOBILE_ARTIFACTS_DIR"}
    environment.update(env or {})
    return subprocess.run(
        [sys.executable, str(CHECKER), "--root", str(root), "--expected-commit", COMMIT, *extra],
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
    crypto = manifest.pop("production_crypto")
    expect_blocked(root, manifest, "has no production_crypto approval")
    manifest["production_crypto"] = crypto
    expect_valid(root, manifest)

    manifest["ci_jobs"]["mobile-ios"] = "skipped"
    expect_blocked(root, manifest, "required CI job 'mobile-ios' is missing or not successful")
    manifest["ci_jobs"]["mobile-ios"] = "success"

    manifest["independent_review"]["status"] = "pending"
    expect_blocked(root, manifest, "independent_review approval is not approved")
    manifest["independent_review"]["status"] = "approved"

    manifest["independent_review"]["reviewer_is_author"] = True
    expect_blocked(root, manifest, "independent_review reviewer is not independent")
    manifest["independent_review"]["reviewer_is_author"] = False

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
        lambda rel: json.loads((root / rel).read_text(encoding="utf-8")),
        [simulator, signed],
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
        qa02_cases(root, manifest)
        # The repository policy must equal the protected rules the fixtures use.
        repo_policy = json.loads((ROOT / "release/release-policy.json").read_text(encoding="utf-8"))
        assert repo_policy["mobile_artifacts"] == MOBILE_POLICY, "repository policy drifted from the fixture"
        assert repo_policy["schema_version"] == 2
    finally:
        shutil.rmtree(root)
    print("release evidence adversarial tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
