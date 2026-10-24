#!/usr/bin/env python3
"""Validate the positive, commit-bound release evidence contract.

Mobile artifacts (QA02) use one record schema for separate artifact types.
``simulator-debug`` (iOS, job ``mobile-ios``) and ``emulator-debug`` (Android,
job ``mobile``) are what hosted CI builds; they are validated when present but
never count as release evidence. The release needs exactly one
``signed-release`` record per platform whose bytes are present and match the
recorded digest:

- iOS: structurally a device-signed app: Payload/*.app, iphoneos Info.plist,
  arm64 iOS Mach-O with a code signature, and an embedded distribution
  provisioning profile, for the team and bundle ID pinned in the policy
  (``ios.team_id``, ``ios.bundle_id``). While either pin is null, no iOS
  signed-release record counts.
- Both: an unambiguous zip (no comment, one end record, no ZIP64, no
  duplicate entry names).
- Android: an APK of the Veritra app, not debuggable, minSdkVersion 24 or
  later, shipping the arm64 crypto library, with an APK Signature Scheme v2
  block (and any v3 blocks) that has exactly one signer whose certificate is
  the release certificate pinned in the policy
  (``android.release_certificate_sha256``, which the record must also name)
  and is not the Android debug certificate. While the pin is null, no Android
  signed-release record counts.

These checks are structural only; signature and attestation cryptography is
verified by codesign/apksigner in the G24 build and by ``gh attestation
verify`` in release.yml.

Approvals cannot live in the candidate commit: a file cannot name the SHA of
the commit that contains it. Each approval is instead read from git at a
separate approvals commit, which the release workflow resolves from the tip of
the protected default branch. The approvals commit must descend from the
candidate. Each approval sits at a path keyed by the candidate SHA, names that
SHA and its source tree, and must have landed on the branch, after the
candidate, in a change that touched nothing but that candidate's approval
directory. The manifest records the approvals commit and each approval's
sha256, so the published evidence pins the exact approval bytes.
"""

from __future__ import annotations

import argparse
import hashlib
import io
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
SCHEMA_VERSION = 3
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
EMULATOR_DEBUG = "emulator-debug"
DEBUG_TYPES = frozenset({SIMULATOR_DEBUG, EMULATOR_DEBUG})
# The hosted CI job that builds each platform's debug (never release) app.
DEBUG_CI_JOBS = {"ios": "mobile-ios", "android": "mobile"}
REQUIRED_MOBILE_ARTIFACTS = {
    "record_schema": MOBILE_RECORD_SCHEMA,
    "required": [
        {"platform": "ios", "artifact_type": SIGNED_RELEASE},
        {"platform": "android", "artifact_type": SIGNED_RELEASE},
    ],
    "debug_ci_jobs": DEBUG_CI_JOBS,
}
CI_WORKFLOW = ".github/workflows/ci.yml"
RECORD_KEYS = frozenset(
    {"schema", "platform", "artifact_type", "commit", "file", "digest", "build", "signing", "provenance"}
)
# Per (platform, artifact_type): fixed build facts and the file suffix. Signed
# types also name the signing identity and the debug build they must not be.
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
        "identity": "distribution",
        "debug_build": "simulator",
    },
    ("android", EMULATOR_DEBUG): {
        "suffix": ".apk",
        "sdk": "android",
        "configuration": "debug",
        "entry_points": ("lib/main.dart", "lib/main_demo.dart"),
        "signing": "debug",
    },
    # An installable APK, the artifact G24 runs on devices. App bundles (.aab)
    # are a store upload format and are not release evidence.
    ("android", SIGNED_RELEASE): {
        "suffix": ".apk",
        "sdk": "android",
        "configuration": "release",
        "entry_points": ("lib/main.dart",),
        "signing": "signed",
        "identity": "release",
        "debug_build": "emulator",
    },
}
CERTIFICATE_RE = re.compile(r"^[0-9a-f]{64}$")
ANDROID_PIN_KEY = "release_certificate_sha256"  # policy["android"]; null until the owner pins it
# Signing identity pins in the policy, each null until the owner sets it:
# platform -> key -> (format, description).
SIGNING_PINS = {
    "android": {ANDROID_PIN_KEY: (CERTIFICATE_RE, "64 lowercase hex characters")},
    "ios": {
        "team_id": (re.compile(r"^[A-Z0-9]{10}$"), "a 10-character Apple team ID (A-Z, 0-9)"),
        "bundle_id": (re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"), "a reverse-DNS bundle ID"),
    },
}
ANDROID_APPLICATION_ID = "org.veritra.private_messenger"
ANDROID_CRYPTO_LIBRARY = "lib/arm64-v8a/libprivate_messenger_crypto.so"
ANDROID_DEBUG_CERTIFICATE_MARKER = b"Android Debug"  # CN of the SDK debug keystore
APK_SIG_BLOCK_MAGIC = b"APK Sig Block 42"
ZIP_EOCD_MAGIC, ZIP64_LOCATOR_MAGIC, ZIP_EOCD_SIZE = b"PK\x05\x06", b"PK\x06\x07", 22
APK_SIGNATURE_V2 = 0x7109871A
APK_SIGNATURE_SCHEMES = (APK_SIGNATURE_V2, 0xF05368C0, 0x1B93AD61)  # v2, v3, v3.1
MAX_APK_BYTES = 512 * 1024 * 1024
AXML_FILE, AXML_STRING_POOL, AXML_RESOURCE_MAP, AXML_START_ELEMENT = 0x0003, 0x0001, 0x0180, 0x0102
AXML_FIRST_NODE, AXML_LAST_NODE = 0x0100, 0x017F  # namespace, element, end and CDATA nodes
AXML_UTF8_FLAG = 0x100
AXML_TYPE_STRING, AXML_TYPE_BOOLEAN = 0x03, 0x12
AXML_TYPE_INTEGERS = (0x10, 0x11)  # decimal, hex
AXML_NO_INDEX = 0xFFFFFFFF
ANDROID_ATTR_DEBUGGABLE = 0x0101000F
ANDROID_ATTR_MIN_SDK = 0x0101020C
# Android 7.0. Older releases verify only v1 (JAR) signatures, which this
# check does not read; Flutter 3.44's default minSdk is 24.
ANDROID_MIN_SDK = 24
FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
RUN_ID_RE = re.compile(r"^[0-9]{1,20}$")  # ASCII only; str.isdigit accepts other scripts
# No "." in the base name: release.yml passes the path to gh as a regular
# expression, where "c..yml" would also match "ci.yml".
WORKFLOW_RE = re.compile(r"^\.github/workflows/[A-Za-z0-9_-]+\.ya?ml$")
MAX_IPA_MEMBER = 256 * 1024 * 1024
MAX_IPA_BYTES = 1024 * 1024 * 1024
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
APPROVAL_SCHEMA = "veritra-release-approval/1"
APPROVALS_DIR = "release/approvals"
# {commit} is the candidate SHA. The file is read from the approvals commit.
REQUIRED_APPROVALS = {
    "production_crypto": {
        "path": APPROVALS_DIR + "/{commit}/production-crypto.json",
        "status": "approved",
        "behavior_test": "pass",
        "not_author": True,
    },
    "independent_review": {
        "path": APPROVALS_DIR + "/{commit}/independent-review.json",
        "status": "approved",
        "not_author": True,
    },
}
APPROVAL_KEYS = frozenset(
    {"schema", "approval", "status", "reviewed_commit", "reviewed_tree", "reviewer", "reviewer_is_author"}
)
MAX_APPROVAL_BYTES = 64 * 1024


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
    head = git_text(root, "rev-parse", "HEAD")
    if not head:
        raise ValueError("cannot determine the candidate commit")
    return head


def require(value: Any, description: str, errors: list[str]) -> None:
    if not value:
        errors.append(f"missing {description}")


# History must read as committed. Replace refs and a grafts file
# (.git/info/grafts, or GIT_GRAFT_FILE from the caller) can both rewrite it
# locally: a replace ref could make a commit without approvals read as one
# with them, and a graft could give an unrelated approvals commit the
# candidate as a parent. --no-replace-objects does not disable grafts, so the
# graft file is pointed at a path under os.devnull, which is not a directory
# and so can never exist.
GIT_HISTORY_ENV = {"GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": os.path.join(os.devnull, "grafts")}


def git(root: Path, *args: str) -> bytes | None:
    """Run a read-only git query; None when git fails, so callers fail closed.

    Replace refs and grafts are ignored (``GIT_HISTORY_ENV``).
    """
    command = ["git", "--no-replace-objects", "-C", str(root), *args]
    try:
        return subprocess.run(
            command, capture_output=True, check=True, env={**os.environ, **GIT_HISTORY_ENV}
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None


def git_text(root: Path, *args: str) -> str | None:
    output = git(root, *args)
    return None if output is None else output.decode("utf-8", "replace").strip()


def approval_path(approval_policy: dict[str, Any], candidate: str) -> str:
    return str(approval_policy["path"]).format(commit=candidate)


def normalized_identity(value: str) -> str:
    return " ".join(value.split()).casefold()


def git_author(root: Path, commit: str) -> tuple[set[str], set[str]] | None:
    """(names, emails) of the commit's author, raw and after .mailmap."""
    output = git(root, "show", "-s", "--format=%an%x00%ae%x00%aN%x00%aE", commit)
    if output is None:
        return None
    parts = [normalized_identity(part) for part in output.decode("utf-8", "replace").strip("\n").split("\0")]
    if len(parts) != 4:
        return None
    return {name for name in parts[0::2] if name}, {email for email in parts[1::2] if email}


def reviewer_is_git_author(reviewer: str, author: tuple[set[str], set[str]]) -> bool:
    """Whether the self-declared reviewer is the candidate's recorded author.

    Both sides are self-declared (git identities are whatever the committer
    configured), so this only catches an author recording themselves under
    the same name or email; it is no proof of independence.
    """
    names, emails = author
    value = normalized_identity(reviewer)
    # "Name <email>" and similar forms are split so the email is compared whole.
    return value in names or not emails.isdisjoint(re.split(r"[\s<>()\[\],;:\"']+", value))


def landed_alone(root: Path, approvals_commit: str, path: str, candidate: str) -> str | None:
    """Return why the change that brought ``path`` onto the branch is unsound.

    The change is the newest first-parent commit that touched the file, so a
    merged pull request counts as one change. It must come after the
    candidate and touch nothing but this candidate's approval directory, so
    an approval cannot ride along unnoticed inside a code change.
    """
    allowed = f"{APPROVALS_DIR}/{candidate}/"
    landing = git_text(root, "log", "-1", "--first-parent", "--format=%H", approvals_commit, "--", path)
    changed = None
    if landing and COMMIT_RE.fullmatch(landing):
        output = git(root, "diff", "--no-renames", "--name-only", "-z", f"{landing}^1", landing, "--")
        if output is not None:
            changed = [name for name in output.decode("utf-8", "replace").split("\0") if name]
    if not changed or any(not name.startswith(allowed) for name in changed):
        return f"did not land in its own change touching only {allowed}"
    if git(root, "merge-base", "--is-ancestor", candidate, landing) is None:
        return "landed before the candidate commit"
    return None


def check_approval(
    root: Path,
    approval_name: str,
    approval_policy: dict[str, Any],
    candidate: str,
    candidate_tree: str,
    candidate_author: tuple[set[str], set[str]],
    approvals_commit: str,
    errors: list[str],
) -> dict[str, Any] | None:
    """Read one approval from git at the approvals commit and validate it.

    Returns its manifest entry (path, sha256 of the bytes, parsed record)
    only when it is sound, so the manifest can be compared to git exactly.
    """
    path = approval_path(approval_policy, candidate)
    label = f"{approval_name} approval"
    blob = git(root, "cat-file", "blob", f"{approvals_commit}:{path}")
    if blob is None:
        errors.append(f"{label} is missing from the approvals commit at {path}")
        return None
    if len(blob) > MAX_APPROVAL_BYTES:
        errors.append(f"{label} is too large")
        return None
    try:
        approval = json.loads(blob.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        errors.append(f"{label} is not valid JSON")
        return None
    keys = APPROVAL_KEYS | ({"behavior_test"} if "behavior_test" in approval_policy else set())
    if not isinstance(approval, dict) or set(approval) != keys:
        errors.append(f"{label} fields do not match the protected approval schema")
        return None
    start = len(errors)
    if approval.get("schema") != APPROVAL_SCHEMA:
        errors.append(f"{label} schema is not {APPROVAL_SCHEMA}")
    if approval.get("approval") != approval_name:
        errors.append(f"{label} names a different approval")
    if approval.get("status") != approval_policy.get("status"):
        errors.append(f"{label} is not {approval_policy.get('status')!r}")
    if approval.get("reviewed_commit") != candidate:
        errors.append(f"{label} is not bound to candidate {candidate}")
    if approval.get("reviewed_tree") != candidate_tree:
        errors.append(f"{label} is not bound to the candidate source tree")
    required_behavior = approval_policy.get("behavior_test")
    if required_behavior is not None and approval.get("behavior_test") != required_behavior:
        errors.append(f"{approval_name} behavior evidence is not {required_behavior!r}")
    if approval_policy.get("not_author") and approval.get("reviewer_is_author") is not False:
        errors.append(f"{approval_name} reviewer is not independently identified")
    reviewer = approval.get("reviewer")
    if not isinstance(reviewer, str) or not reviewer.strip():
        errors.append(f"missing {approval_name} reviewer")
    elif approval_policy.get("not_author") and reviewer_is_git_author(reviewer, candidate_author):
        errors.append(f"{approval_name} reviewer is the candidate commit's git author")
    problem = landed_alone(root, approvals_commit, path, candidate)
    if problem:
        errors.append(f"{label} {problem}")
    if len(errors) != start:
        return None
    return {"path": path, "digest": "sha256:" + hashlib.sha256(blob).hexdigest(), "record": approval}


def verify_approvals(
    root: Path, candidate: str, approvals_commit: str | None, errors: list[str]
) -> dict[str, dict[str, Any]]:
    """Validate every required approval; return the sound ones by name."""
    if not isinstance(approvals_commit, str) or not COMMIT_RE.fullmatch(approvals_commit):
        errors.append(
            "approvals commit is not a full lowercase SHA-1 "
            "(approvals come from a later commit on the protected branch)"
        )
        return {}
    if git(root, "cat-file", "-e", f"{approvals_commit}^{{commit}}") is None:
        errors.append("approvals commit is not in this repository")
        return {}
    candidate_tree = git_text(root, "rev-parse", "--verify", "--quiet", f"{candidate}^{{tree}}")
    if not candidate_tree:
        errors.append("candidate commit is not in this repository")
        return {}
    if approvals_commit == candidate:
        errors.append("approvals commit must be a later commit than the candidate")
        return {}
    if git(root, "merge-base", "--is-ancestor", candidate, approvals_commit) is None:
        errors.append("approvals commit does not descend from the candidate commit")
        return {}
    candidate_author = git_author(root, candidate)
    if candidate_author is None:
        errors.append("cannot read the candidate commit's git author")
        return {}
    verified = {}
    for name, approval_policy in REQUIRED_APPROVALS.items():
        entry = check_approval(
            root, name, approval_policy, candidate, candidate_tree, candidate_author, approvals_commit, errors
        )
        if entry is not None:
            verified[name] = entry
    return verified


def signing_pins(policy: dict[str, Any], errors: list[str] | None = None) -> dict[str, dict[str, str] | None]:
    """Each platform's pinned signing identity; None while any of its pins is null.

    The owner pins them in the reviewed policy (docs/security-review.md). A
    malformed block or pin is reported to ``errors`` and treated as unpinned.
    """
    pins: dict[str, dict[str, str] | None] = {}
    for platform, rules in SIGNING_PINS.items():
        block = policy.get(platform)
        shaped = isinstance(block, dict) and set(block) == set(rules)
        bad = [
            key
            for key, (pattern, _) in rules.items()
            if not shaped or not (block[key] is None or (isinstance(block[key], str) and pattern.fullmatch(block[key])))
        ]
        if errors is not None:
            errors.extend(f"release policy {platform}.{key} is not null or {rules[key][1]}" for key in bad)
        pins[platform] = None if bad or any(block[key] is None for key in rules) else dict(block)
    return pins


def preflight(
    root: Path, policy: dict[str, Any], candidate: str, approvals_commit: str | None
) -> tuple[list[str], dict[str, dict[str, Any]]]:
    errors: list[str] = []
    if policy.get("schema_version") != SCHEMA_VERSION:
        errors.append(f"release policy schema version is not protected version {SCHEMA_VERSION}")
    if policy.get("required_ci_jobs") != list(REQUIRED_CI_JOBS):
        errors.append("release policy required CI jobs do not match the protected set")
    if policy.get("mobile_artifacts") != REQUIRED_MOBILE_ARTIFACTS:
        errors.append("release policy mobile artifact rules do not match the protected set")
    signing_pins(policy, errors)
    if policy.get("approvals") != REQUIRED_APPROVALS:
        errors.append("release policy approvals do not match the protected set")
    # The protected approval rules apply whatever the policy file says.
    return errors, verify_approvals(root, candidate, approvals_commit, errors)


def validate_preflight(
    root: Path, policy: dict[str, Any], candidate: str, approvals_commit: str | None = None
) -> list[str]:
    return preflight(root, policy, candidate, approvals_commit)[0]


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


def profile_errors(blob: bytes, team_id: str | None, bundle_id: str | None) -> list[str]:
    """A distribution profile for the pinned team and app (None: nothing passes)."""
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
    if (
        team_id is None
        or profile.get("TeamIdentifier") != [team_id]
        or entitlements.get("application-identifier") != f"{team_id}.{bundle_id}"
        or entitlements.get("com.apple.developer.team-identifier", team_id) != team_id
    ):
        return ["signed ios provisioning profile is not for the pinned team and bundle ID"]
    return []


def read_member(archive: zipfile.ZipFile, name: str) -> bytes:
    info = archive.getinfo(name)
    if info.file_size > MAX_IPA_MEMBER:
        raise ValueError("member too large")
    return archive.read(info)


def ipa_errors(path: Path, pins: dict[str, str] | None) -> list[str]:
    """Structural device-signing checks; cryptographic checks happen in G24.

    The app must be the pinned bundle ID under the pinned team; with no pins,
    nothing passes. The zip must be as unambiguous as an APK's.
    """
    team_id, bundle_id = (pins["team_id"], pins["bundle_id"]) if pins else (None, None)
    try:
        if path.stat().st_size > MAX_IPA_BYTES:
            return ["signed ios artifact is too large"]
        data = path.read_bytes()
        layout = zip_layout_error(data)
        if layout:
            return [f"signed ios artifact {layout}"]
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            problem = zip_entries_error(data, archive)
            if problem:
                return [f"signed ios artifact {problem}"]
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
            if bundle_id is None or info.get("CFBundleIdentifier") != bundle_id:
                errors.append("signed ios artifact is not the pinned bundle ID")
            executable = info.get("CFBundleExecutable")
            if not isinstance(executable, str) or not FILE_RE.fullmatch(executable):
                return errors + ["signed ios Info.plist has no valid executable name"]
            if app + "_CodeSignature/CodeResources" not in names:
                errors.append("signed ios app bundle has no code signature resources")
            if app + "embedded.mobileprovision" not in names:
                errors.append("signed ios app bundle has no embedded provisioning profile")
            else:
                profile = read_member(archive, app + "embedded.mobileprovision")
                errors.extend(profile_errors(profile, team_id, bundle_id))
            if app + executable not in names:
                return errors + ["signed ios app bundle is missing its executable"]
            errors.extend(macho_errors(read_member(archive, app + executable)))
            return errors
    except Exception:  # BadZipFile, KeyError, plist and size errors all fail closed
        return ["signed ios artifact is not a readable iOS app archive"]


def length_prefixed(buffer: bytes, offset: int) -> tuple[bytes, int]:
    (size,) = struct.unpack_from("<I", buffer, offset)
    start = offset + 4
    if start + size > len(buffer):
        raise ValueError("length prefix out of range")
    return buffer[start : start + size], start + size


def length_prefixed_items(buffer: bytes) -> list[bytes]:
    items, offset = [], 0
    while offset < len(buffer):
        item, offset = length_prefixed(buffer, offset)
        items.append(item)
    return items


def zip_layout_error(data: bytes) -> str | None:
    """Why a signed APK's or IPA's zip end record is not the single, unambiguous one.

    Neither has a zip comment, so the end of central directory record is
    exactly the last 22 bytes. A comment could hide a second signing block,
    central directory and end record that a lenient reader (Python's zipfile,
    a backwards scan) would pick instead of the one the platform uses, so no
    other end record signature may appear where a comment could reach. ZIP64
    and multi-disk archives are refused too.
    """
    eocd = len(data) - ZIP_EOCD_SIZE
    if eocd < 0 or data[eocd : eocd + 4] != ZIP_EOCD_MAGIC or data[-2:] != b"\0\0":
        return "has a zip comment or does not end with its end of central directory record"
    if data.count(ZIP_EOCD_MAGIC, max(0, eocd - 0xFFFF)) != 1:
        return "has more than one end of central directory record"
    disk, directory_disk, disk_entries, entries = struct.unpack_from("<HHHH", data, eocd + 4)
    zip64 = eocd >= 20 and data[eocd - 20 : eocd - 16] == ZIP64_LOCATOR_MAGIC
    if disk or directory_disk or disk_entries != entries or zip64:
        return "is a multi-disk or ZIP64 archive"
    return None


def zip_entries_error(data: bytes, archive: zipfile.ZipFile) -> str | None:
    """Why the entries are ambiguous; run after ``zip_layout_error`` passed.

    Readers disagree on which of two same-named entries wins (zipfile takes
    the last), and zipfile cuts a name at a NUL byte the platform keeps.
    """
    entries = archive.infolist()
    if len({entry.filename for entry in entries}) != len(entries) or any(
        entry.filename != entry.orig_filename for entry in entries
    ):
        return "has duplicate or ambiguous entry names"
    if struct.unpack_from("<H", data, len(data) - ZIP_EOCD_SIZE + 10)[0] != len(entries):
        return "central directory does not match its end record"
    return None


def apk_signing_block(data: bytes) -> dict[int, bytes]:
    """ID-value pairs of the APK Signing Block; empty when there is none.

    The end record is the last 22 bytes (``zip_layout_error`` passed).
    """
    eocd = len(data) - ZIP_EOCD_SIZE
    if eocd < 0 or data[eocd : eocd + 4] != ZIP_EOCD_MAGIC:
        raise ValueError("no end of central directory")
    cd_size, cd_offset = struct.unpack_from("<II", data, eocd + 12)
    if cd_offset + cd_size != eocd:
        raise ValueError("central directory is not where the end record says")
    if cd_offset < 32 or data[cd_offset - 16 : cd_offset] != APK_SIG_BLOCK_MAGIC:
        return {}
    (size,) = struct.unpack_from("<Q", data, cd_offset - 24)
    start = cd_offset - 8 - size
    if size < 24 or start < 0 or struct.unpack_from("<Q", data, start)[0] != size:
        raise ValueError("APK signing block sizes disagree")
    pairs: dict[int, bytes] = {}
    offset, end = start + 8, cd_offset - 24
    while offset < end:
        (pair_size,) = struct.unpack_from("<Q", data, offset)
        if pair_size < 4 or offset + 8 + pair_size > end:
            raise ValueError("APK signing block pair out of range")
        (pair_id,) = struct.unpack_from("<I", data, offset + 8)
        if pair_id in pairs:
            raise ValueError("duplicate APK signing block pair")
        pairs[pair_id] = data[offset + 12 : offset + 8 + pair_size]
        offset += 8 + pair_size
    return pairs


def signer_certificates(scheme: bytes) -> list[bytes]:
    """The leaf certificate of each signer; v2, v3 and v3.1 share this layout."""
    signers, end = length_prefixed(scheme, 0)
    if end != len(scheme):
        raise ValueError("trailing bytes after signers")
    leaves = []
    for signer in length_prefixed_items(signers):
        signed_data, _ = length_prefixed(signer, 0)
        _, offset = length_prefixed(signed_data, 0)  # digests
        certificates, _ = length_prefixed(signed_data, offset)
        chain = length_prefixed_items(certificates)
        if not chain or not chain[0]:
            raise ValueError("signer without a certificate")
        leaves.append(chain[0])
    return leaves


def axml_strings(chunk: bytes) -> list[str]:
    header_size = struct.unpack_from("<H", chunk, 2)[0]
    count, _, flags, strings_start, _ = struct.unpack_from("<IIIII", chunk, 8)
    if count > 100_000:
        raise ValueError("string pool too large")
    strings = []
    for index in range(count):
        position = strings_start + struct.unpack_from("<I", chunk, header_size + 4 * index)[0]
        if flags & AXML_UTF8_FLAG:
            position += 2 if chunk[position] & 0x80 else 1  # UTF-16 length, unused
            size = chunk[position]
            if size & 0x80:
                size = ((size & 0x7F) << 8) | chunk[position + 1]
                position += 1
            position += 1
            raw = chunk[position : position + size]
            if len(raw) != size:
                raise ValueError("string out of range")
            strings.append(raw.decode("utf-8"))
        else:
            (size,) = struct.unpack_from("<H", chunk, position)
            position += 2
            if size & 0x8000:
                size = ((size & 0x7FFF) << 16) | struct.unpack_from("<H", chunk, position)[0]
                position += 2
            raw = chunk[position : position + 2 * size]
            if len(raw) != 2 * size:
                raise ValueError("string out of range")
            strings.append(raw.decode("utf-16-le"))
    return strings


def manifest_facts(data: bytes) -> tuple[str | None, bool, int]:
    """(package, debuggable, lowest minSdkVersion) from a compiled AndroidManifest.xml.

    Any ``debuggable`` attribute that is not a literal false counts as
    debuggable, so a resource reference fails closed. A missing or non-integer
    ``minSdkVersion`` counts as 1, Android's default.

    Android reads the string pool and resource map only before the first XML
    node, so one of either anywhere else, or a second one, could show this
    check other names or attribute IDs than the platform uses: both are
    refused. So is a ``manifest`` element that is not the single root, since
    the platform takes the package from the root, and an element with two
    attributes of one name or resource ID, since readers pick different ones.
    The package is what Android reads: the ``package`` attribute with no
    namespace, as its raw string, which must also be the typed value.
    """
    kind, header_size, total = struct.unpack_from("<HHI", data, 0)
    if kind != AXML_FILE or total > len(data):
        raise ValueError("not a compiled Android XML file")
    strings: list[str] | None = None
    resource_ids: list[int] | None = None
    package, debuggable = None, False
    min_sdks: list[int] = []
    in_nodes, elements = False, 0
    offset = header_size
    while offset + 8 <= total:
        kind, chunk_header, size = struct.unpack_from("<HHI", data, offset)
        if size < 8 or offset + size > total:
            raise ValueError("chunk out of range")
        chunk = data[offset : offset + size]
        if kind == AXML_STRING_POOL:
            if in_nodes or strings is not None:
                raise ValueError("string pool after the first XML node, or a second one")
            strings = axml_strings(chunk)
        elif kind == AXML_RESOURCE_MAP:
            if in_nodes or resource_ids is not None:
                raise ValueError("resource map after the first XML node, or a second one")
            resource_ids = list(struct.unpack_from(f"<{(size - chunk_header) // 4}I", chunk, chunk_header))
        elif AXML_FIRST_NODE <= kind <= AXML_LAST_NODE:
            in_nodes = True
        if kind == AXML_START_ELEMENT:
            if strings is None:
                raise ValueError("XML element without a string pool")
            ids = resource_ids or []
            _, name, attr_start, attr_size, attr_count = struct.unpack_from("<IIHHH", chunk, chunk_header)
            if attr_size < 20:
                raise ValueError("short attribute")
            element = strings[name]
            if (element == "manifest") != (elements == 0):
                raise ValueError("manifest is not the single root element")
            elements += 1
            if element == "uses-sdk":
                min_sdks.append(1)
            seen: set[tuple[Any, ...]] = set()
            for index in range(attr_count):
                at = chunk_header + attr_start + index * attr_size
                namespace, attr_name, raw, _, _, value_type, value = struct.unpack_from("<IIIHBBI", chunk, at)
                attr = strings[attr_name] if attr_name < len(strings) else ""
                attr_id = ids[attr_name] if attr_name < len(ids) else None
                keys = {("name", None if namespace == AXML_NO_INDEX else strings[namespace], attr)}
                if attr_id:
                    keys.add(("id", attr_id))
                if not seen.isdisjoint(keys):
                    raise ValueError("duplicate attribute")
                seen |= keys
                if element == "manifest" and attr == "package" and namespace == AXML_NO_INDEX:
                    # Android: the raw string (no duplicate, so the first).
                    if raw == AXML_NO_INDEX or value_type != AXML_TYPE_STRING or strings[raw] != strings[value]:
                        raise ValueError("package raw and typed values differ")
                    package = strings[raw]
                if element == "application" and (attr_id == ANDROID_ATTR_DEBUGGABLE or attr == "debuggable"):
                    if value_type != AXML_TYPE_BOOLEAN or value != 0:
                        debuggable = True
                if element == "uses-sdk" and (attr_id == ANDROID_ATTR_MIN_SDK or attr == "minSdkVersion"):
                    min_sdks[-1] = value if value_type in AXML_TYPE_INTEGERS else 1
        offset += size
    return package, debuggable, min(min_sdks, default=1)


def apk_errors(path: Path, pinned_certificate: str | None) -> list[str]:
    """Structural release-signing checks; apksigner verifies the signature in G24.

    The signer must be the pinned release certificate; with no pin, nothing passes.
    """
    try:
        if path.stat().st_size > MAX_APK_BYTES:
            return ["signed android artifact is too large"]
        data = path.read_bytes()
        layout = zip_layout_error(data)
        if layout:
            return [f"signed android artifact {layout}"]
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            problem = zip_entries_error(data, archive)
            if problem:
                return [f"signed android artifact {problem}"]
            names = set(archive.namelist())
            if "AndroidManifest.xml" not in names or "classes.dex" not in names:
                return ["signed android artifact is not an Android app package"]
            package, debuggable, min_sdk = manifest_facts(read_member(archive, "AndroidManifest.xml"))
            errors: list[str] = []
            if package != ANDROID_APPLICATION_ID:
                errors.append(f"signed android artifact is not the {ANDROID_APPLICATION_ID} app")
            if debuggable:
                errors.append("signed android artifact is debuggable")
            if min_sdk < ANDROID_MIN_SDK:
                errors.append(
                    f"signed android artifact supports Android releases that verify only v1 signatures "
                    f"(minSdkVersion {min_sdk} < {ANDROID_MIN_SDK})"
                )
            if ANDROID_CRYPTO_LIBRARY not in names:
                errors.append("signed android artifact does not ship the arm64-v8a crypto library")
    except Exception:  # BadZipFile, struct, index and decode errors all fail closed
        return ["signed android artifact is not a readable APK"]
    try:
        pairs = apk_signing_block(data)
        schemes = {scheme: signer_certificates(pairs[scheme]) for scheme in APK_SIGNATURE_SCHEMES if scheme in pairs}
    except Exception:
        return errors + ["signed android artifact has a malformed APK signing block"]
    # Android 7.0-8.1 never read v3: without v2 they verify v1 (any key).
    if APK_SIGNATURE_V2 not in schemes:
        return errors + ["signed android artifact has no APK Signature Scheme v2 signature"]
    if any(len(leaves) != 1 for leaves in schemes.values()):
        return errors + ["signed android artifact must have exactly one signer"]
    leaves = {leaves[0] for leaves in schemes.values()}
    if any(ANDROID_DEBUG_CERTIFICATE_MARKER in leaf for leaf in leaves):
        errors.append("signed android artifact is signed with the Android debug certificate")
    fingerprints = {hashlib.sha256(leaf).hexdigest() for leaf in leaves}
    if fingerprints != {pinned_certificate}:
        errors.append("signed android artifact signer certificate is not the pinned release certificate")
    return errors


def check_mobile_record(
    index: int,
    record: Any,
    candidate: str,
    ci_run_id: Any,
    artifacts_dir: Path,
    pins: dict[str, dict[str, str] | None],
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

    debug_job = DEBUG_CI_JOBS[platform]
    if artifact_type in DEBUG_TYPES:
        if workflow != CI_WORKFLOW or job != debug_job:
            errors.append(f"{label} provenance is not the {debug_job} CI job")
    else:
        identity = rules["identity"]
        if signing.get("identity") != identity or signing.get("verification") != "pass" or not signing.get("verifier"):
            errors.append(f"{label} signature was not verified as a {identity} signature")
        platform_pins = pins.get(platform)
        pinned_certificate = platform_pins[ANDROID_PIN_KEY] if platform == "android" and platform_pins else None
        if platform == "ios" and platform_pins is None:
            # Without the pins, any team's app under any bundle ID would do.
            errors.append(
                f"{label} cannot count until the iOS team and bundle IDs are pinned "
                "(pin first: ios.team_id and ios.bundle_id in release/release-policy.json)"
            )
        if platform == "android":
            # The record's own fingerprint proves nothing: any non-debug key
            # would match itself. The certificate must be the pinned one.
            if pinned_certificate is None:
                errors.append(
                    f"{label} cannot count until the release certificate is pinned "
                    f"(pin the release certificate first: android.{ANDROID_PIN_KEY} in release/release-policy.json)"
                )
            certificate = signing.get("certificate_sha256")
            if not isinstance(certificate, str) or not CERTIFICATE_RE.fullmatch(certificate):
                errors.append(f"{label} has no valid signing certificate SHA-256 fingerprint")
            elif pinned_certificate is not None and certificate != pinned_certificate:
                errors.append(f"{label} signing certificate is not the pinned release certificate")
        # Compare run IDs as integers so "0123" cannot dodge CI run 123.
        same_run = (
            isinstance(run_id, str)
            and RUN_ID_RE.fullmatch(run_id) is not None
            and RUN_ID_RE.fullmatch(str(ci_run_id)) is not None
            and int(run_id) == int(str(ci_run_id))
        )
        if workflow == CI_WORKFLOW or job == debug_job or same_run:
            errors.append(f"{label} provenance is the debug {rules['debug_build']} CI build")
        if file_name and digest:
            path = artifacts_dir / file_name
            if not path.is_file():
                errors.append(f"{label} file is missing from the artifact directory")
            elif sha256_file(path) != digest:
                errors.append(f"{label} file does not match its recorded digest")
            elif platform == "ios":
                errors.extend(ipa_errors(path, platform_pins))
            else:
                errors.extend(apk_errors(path, pinned_certificate))
    if len(errors) != start or digest is None:
        return None
    return platform, artifact_type, digest


def validate_mobile_artifacts(
    manifest: dict[str, Any],
    candidate: str,
    artifacts_dir: Path,
    pins: dict[str, dict[str, str] | None],
    errors: list[str],
) -> None:
    records = manifest.get("mobile_artifacts")
    if not isinstance(records, list):
        errors.append("release evidence has no mobile artifact records")
        records = []
    sound = []
    for index, record in enumerate(records):
        result = check_mobile_record(
            index, record, candidate, manifest.get("ci_run_id"), artifacts_dir, pins, errors
        )
        if result is not None:
            sound.append(result)
    debug_digests = {digest for _, kind, digest in sound if kind in DEBUG_TYPES}
    for required in REQUIRED_MOBILE_ARTIFACTS["required"]:
        key = (required["platform"], required["artifact_type"])
        name = " ".join(key)
        declared = [r for r in records if isinstance(r, dict) and (r.get("platform"), r.get("artifact_type")) == key]
        matches = [digest for platform, kind, digest in sound if (platform, kind) == key]
        if len(declared) > 1:
            errors.append(f"release evidence has more than one {name} artifact")
        elif not matches:
            errors.append(f"release evidence has no valid {name} artifact")
        elif matches[0] in debug_digests:
            errors.append(f"{name} artifact has the same digest as a debug build")


def validate_manifest(
    root: Path,
    policy: dict[str, Any],
    manifest: dict[str, Any],
    candidate: str,
    artifacts_dir: Path | None = None,
    approvals_commit: str | None = None,
) -> list[str]:
    errors, verified = preflight(root, policy, candidate, approvals_commit)
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

    # The manifest must carry exactly what git holds at the approvals commit.
    recorded = manifest.get("approvals")
    if not isinstance(recorded, dict):
        errors.append("release evidence has no approvals record")
    else:
        if recorded.get("commit") != approvals_commit:
            errors.append("release evidence approvals are not from the verified approvals commit")
        if set(recorded) != {"commit", *REQUIRED_APPROVALS}:
            errors.append("release evidence approvals do not match the protected set")
        for name in REQUIRED_APPROVALS:
            entry = recorded.get(name)
            if not isinstance(entry, dict):
                errors.append(f"release evidence has no {name} approval")
            elif name in verified and entry != verified[name]:
                errors.append(f"release evidence {name} approval does not match the approvals commit")

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
        validate_mobile_artifacts(manifest, candidate, artifacts_dir, signing_pins(policy), errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--policy", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--expected-commit")
    parser.add_argument(
        "--approvals-commit",
        help="the later commit on the protected branch that holds the candidate's approvals",
    )
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
        if args.preflight:
            errors = validate_preflight(root, policy, candidate, args.approvals_commit)
        else:
            evidence_path = (args.evidence or root / "dist/release-evidence.json").resolve()
            env_dir = os.environ.get("MOBILE_ARTIFACTS_DIR")
            artifacts_dir = (args.artifacts_dir or (Path(env_dir) if env_dir else evidence_path.parent)).resolve()
            errors = validate_manifest(
                root, policy, load_json(evidence_path), candidate, artifacts_dir, args.approvals_commit
            )
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
