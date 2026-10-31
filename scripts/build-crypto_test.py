#!/usr/bin/env python3
"""Offline tests for the crypto build scripts: provenance and artifact paths.

Each case copies the real build script into a scratch git repository with a
fake crate and puts stub cargo, rustc, uname, lipo, xcodebuild and Android NDK
clang commands first on PATH. No Rust build runs and nothing reaches the
network. POSIX only (the scripts are sh).
"""

from __future__ import annotations

import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
PYTHON = sys.executable
REAL_UNAME = shutil.which("uname") or "/bin/uname"

CARGO_STUB = """#!@PYTHON@
import os
import sys
from pathlib import Path

args = sys.argv[1:]
with open(os.environ["STUB_LOG"], "a", encoding="utf-8") as handle:
    handle.write("cargo cwd=" + os.getcwd() + " " + " ".join(args) + "\\n")
if args[:1] == ["metadata"]:
    print("{}")
    raise SystemExit(0)
if args[:1] != ["build"]:
    raise SystemExit("cargo stub: unexpected command " + " ".join(args))


def option(name):
    return args[args.index(name) + 1] if name in args else None


manifest = option("--manifest-path")
crate = Path(manifest).parent if manifest else Path.cwd()
# Cargo picks the output directory from --target-dir, then CARGO_TARGET_DIR,
# then <crate>/target (build.target-dir configuration is not modelled).
target_dir = Path(option("--target-dir") or os.environ.get("CARGO_TARGET_DIR") or crate / "target")
target = option("--target")
if os.environ.get("CARGO_STUB_NO_ARTIFACT") == "1":
    raise SystemExit(0)
profile = target_dir / target / "release" if target else target_dir / "release"
profile.mkdir(parents=True, exist_ok=True)
name = "libprivate_messenger_crypto.a" if target and "apple" in target else "libprivate_messenger_crypto.so"
(profile / name).write_text("fresh " + (target or "host") + "\\n", encoding="utf-8")
"""

RUSTC_STUB = """#!/bin/sh
echo "rustc cwd=$(pwd)" >> "$STUB_LOG"
case ${RUSTC_STUB:-ok} in
  fail) echo "rustc stub: failure" >&2; exit 1 ;;
  garbage) echo "not rustc output"; exit 0 ;;
esac
cat <<'EOF'
rustc 1.91.0 (f8297e351 2025-10-28)
binary: rustc
commit-hash: f8297e351a40c1439a467bbbb6879088047f50b3
commit-date: 2025-10-28
host: x86_64-unknown-linux-gnu
release: 1.91.0
LLVM version: 21.1.2
EOF
"""

UNAME_STUB = """#!/bin/sh
if [ "${1:-}" = "-s" ] && [ -n "${UNAME_STUB:-}" ]; then
  echo "$UNAME_STUB"
  exit 0
fi
exec @REAL_UNAME@ "$@"
"""

LIPO_STUB = """#!@PYTHON@
import sys
from pathlib import Path

args = sys.argv[1:]
output = Path(args[args.index("-output") + 1])
inputs = [Path(arg) for arg in args[args.index("-create") + 1 : args.index("-output")]]
for path in inputs:
    if not path.is_file():
        raise SystemExit(f"lipo stub: missing input {path}")
output.write_text("".join(path.read_text(encoding="utf-8") for path in inputs), encoding="utf-8")
"""

XCODEBUILD_STUB = """#!@PYTHON@
import sys
from pathlib import Path

args = sys.argv[1:]
libraries = [Path(args[i + 1]) for i, arg in enumerate(args) if arg == "-library"]
output = Path(args[args.index("-output") + 1])
for path in libraries:
    if not path.is_file():
        raise SystemExit(f"xcodebuild stub: missing library {path}")
output.mkdir(parents=True)
for index, path in enumerate(libraries):
    (output / f"library-{index}.a").write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
"""

FAILING_SHA256SUM = "#!/bin/sh\necho 'sha256sum stub: failure' >&2\nexit 1\n"
MALFORMED_SHA256SUM = "#!/bin/sh\necho \"not-a-hash  $1\"\n"

ANDROID_LINKERS = (
    "aarch64-linux-android23-clang",
    "armv7a-linux-androideabi23-clang",
    "x86_64-linux-android23-clang",
)


def write_executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content.replace("@PYTHON@", PYTHON).replace("@REAL_UNAME@", REAL_UNAME), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Scratch:
    """A scratch repository holding one copy of the build scripts."""

    def __init__(self, temp: Path) -> None:
        self.temp = temp
        self.root = temp / "repo"
        self.crate = self.root / "crypto/rust"
        self.bin = temp / "bin"
        self.log = temp / "stub.log"
        self.git_config = temp / "gitconfig"
        self.git_config.write_text("", encoding="utf-8")

        scripts = self.root / "scripts"
        scripts.mkdir(parents=True)
        for name in ("build-desktop-crypto.sh", "build-mobile-crypto.sh"):
            shutil.copy2(SCRIPTS / name, scripts / name)
        (scripts / "cargo-license-metadata.py").write_text(
            "import sys\nsys.stdin.read()\nprint('{}')\n", encoding="utf-8"
        )
        (self.crate / "src").mkdir(parents=True)
        (self.crate / "include").mkdir()
        (self.crate / "Cargo.toml").write_text('[package]\nname = "private-messenger-crypto"\n', encoding="utf-8")
        (self.crate / "Cargo.lock").write_text("# scratch lock\nversion = 4\n", encoding="utf-8")
        (self.crate / "src/lib.rs").write_text("// scratch crate\n", encoding="utf-8")
        (self.crate / "include/veritra_crypto.h").write_text("/* scratch header */\n", encoding="utf-8")
        (self.root / ".gitignore").write_text("crypto/rust/target/\nmobile/\n", encoding="utf-8")
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "scratch")

        write_executable(self.bin / "cargo", CARGO_STUB)
        write_executable(self.bin / "rustc", RUSTC_STUB)
        write_executable(self.bin / "uname", UNAME_STUB)
        write_executable(self.bin / "lipo", LIPO_STUB)
        write_executable(self.bin / "xcodebuild", XCODEBUILD_STUB)
        self.ndk = temp / "ndk"
        for linker in ANDROID_LINKERS:
            write_executable(self.ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin" / linker, "#!/bin/sh\nexit 0\n")

    def base_env(self) -> dict[str, str]:
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("GIT_", "CARGO_", "ANDROID_", "RUSTUP_"))
        }
        env.update(
            {
                "GIT_CONFIG_GLOBAL": str(self.git_config),
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CEILING_DIRECTORIES": str(self.temp),
                "GIT_AUTHOR_NAME": "Scratch",
                "GIT_AUTHOR_EMAIL": "scratch@example.invalid",
                "GIT_COMMITTER_NAME": "Scratch",
                "GIT_COMMITTER_EMAIL": "scratch@example.invalid",
            }
        )
        return env

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(self.root), *args],
            env=self.base_env(),
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def run(
        self,
        script: str,
        platform: str,
        extra_env: dict[str, str] | None = None,
        extra_bin: Path | None = None,
        cwd: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = self.base_env()
        path = [str(self.bin), env.get("PATH", "/usr/bin:/bin")]
        if extra_bin is not None:
            path.insert(0, str(extra_bin))
        env["PATH"] = os.pathsep.join(path)
        env["STUB_LOG"] = str(self.log)
        env["ANDROID_NDK_HOME"] = str(self.ndk)
        env.update(extra_env or {})
        self.log.write_text("", encoding="utf-8")
        return subprocess.run(
            ["sh", str(self.root / "scripts" / script), platform],
            env=env,
            cwd=str(cwd or self.root),
            capture_output=True,
            text=True,
            check=False,
        )

    def log_lines(self, prefix: str) -> list[str]:
        return [line for line in self.log.read_text(encoding="utf-8").splitlines() if line.startswith(prefix)]


# (script, platform, extra environment, build-info.txt path relative to the root)
PROVENANCE_CASES = (
    ("build-desktop-crypto.sh", "linux", {}, "mobile/linux/crypto/metadata/build-info.txt"),
    ("build-desktop-crypto.sh", "macos", {"UNAME_STUB": "Darwin"}, "mobile/macos/crypto/metadata/build-info.txt"),
    ("build-mobile-crypto.sh", "android", {}, "mobile/android/app/src/main/assets/veritra-crypto/build-info.txt"),
    ("build-mobile-crypto.sh", "ios", {}, "mobile/ios/Frameworks/veritra-crypto-metadata/build-info.txt"),
)


def with_scratch(test):
    def wrapper() -> None:
        with tempfile.TemporaryDirectory() as temp:
            test(Scratch(Path(temp)))

    wrapper.__name__ = test.__name__
    return wrapper


@with_scratch
def test_clean_build_records_checked_provenance(scratch: Scratch) -> None:
    head = scratch.git("rev-parse", "HEAD")
    lock_hash = hashlib.sha256((scratch.crate / "Cargo.lock").read_bytes()).hexdigest()
    for script, platform, env, info in PROVENANCE_CASES:
        result = scratch.run(script, platform, env)
        assert result.returncode == 0, (platform, result.stderr)
        lines = (scratch.root / info).read_text(encoding="utf-8").splitlines()
        # Existing keys keep their order; the dirty flag follows them.
        assert lines[0] == f"source_revision={head}", (platform, lines)
        assert lines[1] == f"cargo_lock_sha256={lock_hash}", (platform, lines)
        assert lines[2] == "source_tree_dirty=false", (platform, lines)
        assert lines[3].startswith("rustc 1.91.0 "), (platform, lines)
        assert "release: 1.91.0" in lines, (platform, lines)


@with_scratch
def test_dirty_crypto_sources_are_recorded(scratch: Scratch) -> None:
    info = scratch.root / "mobile/linux/crypto/metadata/build-info.txt"

    def dirty_flag() -> str:
        result = scratch.run("build-desktop-crypto.sh", "linux")
        assert result.returncode == 0, result.stderr
        return info.read_text(encoding="utf-8").splitlines()[2]

    # A change outside crypto/rust does not mark the library dirty.
    (scratch.root / "README.md").write_text("unrelated\n", encoding="utf-8")
    assert dirty_flag() == "source_tree_dirty=false"
    # Build output under the ignored target directory does not either.
    assert dirty_flag() == "source_tree_dirty=false"
    # An untracked crate file does.
    (scratch.crate / "src/extra.rs").write_text("// untracked\n", encoding="utf-8")
    assert dirty_flag() == "source_tree_dirty=true"
    (scratch.crate / "src/extra.rs").unlink()
    # So does a modified tracked file.
    (scratch.crate / "src/lib.rs").write_text("// modified\n", encoding="utf-8")
    assert dirty_flag() == "source_tree_dirty=true"

    for script, platform, env, info_path in PROVENANCE_CASES[1:]:
        result = scratch.run(script, platform, env)
        assert result.returncode == 0, (platform, result.stderr)
        lines = (scratch.root / info_path).read_text(encoding="utf-8").splitlines()
        assert lines[2] == "source_tree_dirty=true", (platform, lines)


def assert_aborts_before_build(
    scratch: Scratch,
    label: str,
    extra_env: dict[str, str] | None = None,
    extra_bin: Path | None = None,
) -> None:
    for script, platform, env, info in PROVENANCE_CASES:
        target = scratch.root / info
        if target.exists():
            target.unlink()
        result = scratch.run(script, platform, {**env, **(extra_env or {})}, extra_bin)
        assert result.returncode != 0, (label, platform, result.stdout, result.stderr)
        assert not target.exists(), (label, platform, "build-info.txt was written")
        assert not scratch.log_lines("cargo"), (label, platform, "cargo ran before provenance was checked")


@with_scratch
def test_git_failure_aborts(scratch: Scratch) -> None:
    assert_aborts_before_build(scratch, "GIT_DIR=/nonexistent", {"GIT_DIR": "/nonexistent"})
    # An exported or tarball tree has no repository at all.
    shutil.rmtree(scratch.root / ".git")
    assert_aborts_before_build(scratch, "no .git")


@with_scratch
def test_lock_hash_failure_aborts(scratch: Scratch) -> None:
    failing = scratch.temp / "failing-sha"
    write_executable(failing / "sha256sum", FAILING_SHA256SUM)
    assert_aborts_before_build(scratch, "sha256sum fails", extra_bin=failing)
    malformed = scratch.temp / "malformed-sha"
    write_executable(malformed / "sha256sum", MALFORMED_SHA256SUM)
    assert_aborts_before_build(scratch, "sha256sum malformed", extra_bin=malformed)


@with_scratch
def test_rustc_failure_aborts(scratch: Scratch) -> None:
    assert_aborts_before_build(scratch, "rustc fails", {"RUSTC_STUB": "fail"})
    assert_aborts_before_build(scratch, "rustc output malformed", {"RUSTC_STUB": "garbage"})


@with_scratch
def test_toolchain_resolves_inside_the_repository(scratch: Scratch) -> None:
    # rustup reads rust-toolchain.toml from the working directory, so cargo and
    # the recorded rustc must run inside the repository even when the caller
    # starts the script from elsewhere.
    outside = scratch.temp / "elsewhere"
    outside.mkdir()
    for script, platform, env, _ in PROVENANCE_CASES:
        scratch.log.write_text("", encoding="utf-8")
        result = scratch.run(script, platform, env, cwd=outside)
        assert result.returncode == 0, (platform, result.stderr)
        calls = scratch.log_lines("cargo") + scratch.log_lines("rustc")
        assert calls, platform
        for call in calls:
            cwd = call.split(" ", 2)[1].removeprefix("cwd=")
            assert Path(cwd).resolve().is_relative_to(scratch.root.resolve()), (platform, call)


LIBRARY_SO = "libprivate_messenger_crypto.so"
LIBRARY_A = "libprivate_messenger_crypto.a"
# (script, platform, extra environment, artifacts under <crate>/target that the
# script collects, packaged outputs relative to the root)
ARTIFACT_CASES = (
    ("build-desktop-crypto.sh", "linux", {}, (f"release/{LIBRARY_SO}",), (f"mobile/linux/crypto/{LIBRARY_SO}",)),
    (
        "build-desktop-crypto.sh",
        "macos",
        {"UNAME_STUB": "Darwin"},
        (f"aarch64-apple-darwin/release/{LIBRARY_A}", f"x86_64-apple-darwin/release/{LIBRARY_A}"),
        (f"mobile/macos/crypto/{LIBRARY_A}",),
    ),
    (
        "build-mobile-crypto.sh",
        "android",
        {},
        tuple(
            f"{target}/release/{LIBRARY_SO}"
            for target in ("aarch64-linux-android", "armv7-linux-androideabi", "x86_64-linux-android")
        ),
        tuple(f"mobile/android/app/src/main/jniLibs/{abi}/{LIBRARY_SO}" for abi in ("arm64-v8a", "armeabi-v7a", "x86_64")),
    ),
    (
        "build-mobile-crypto.sh",
        "ios",
        {},
        tuple(f"{target}/release/{LIBRARY_A}" for target in ("aarch64-apple-ios", "aarch64-apple-ios-sim", "x86_64-apple-ios")),
        tuple(f"mobile/ios/Frameworks/VeritraCrypto.xcframework/library-{index}.a" for index in (0, 1)),
    ),
)


def seed_stale_artifacts(scratch: Scratch, artifacts: tuple[str, ...]) -> None:
    for artifact in artifacts:
        path = scratch.crate / "target" / artifact
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("stale\n", encoding="utf-8")


@with_scratch
def test_artifacts_come_from_the_directory_cargo_built(scratch: Scratch) -> None:
    # Cargo honours CARGO_TARGET_DIR; the scripts must still package what this
    # build produced, never an older binary left in <crate>/target.
    alternate = scratch.temp / "alternate-target"
    for script, platform, env, artifacts, outputs in ARTIFACT_CASES:
        seed_stale_artifacts(scratch, artifacts)
        result = scratch.run(script, platform, {**env, "CARGO_TARGET_DIR": str(alternate)})
        assert result.returncode == 0, (platform, result.stderr)
        for output in outputs:
            content = (scratch.root / output).read_text(encoding="utf-8")
            assert "fresh" in content and "stale" not in content, (platform, output, content)
        builds = [line for line in scratch.log_lines("cargo") if " build " in line]
        assert builds, platform
        for line in builds:
            assert f"--target-dir {scratch.crate}/target" in line, (platform, line)


@with_scratch
def test_missing_fresh_artifact_fails(scratch: Scratch) -> None:
    # A build that leaves no fresh artifact must fail, not package a stale one.
    for script, platform, env, artifacts, outputs in ARTIFACT_CASES:
        seed_stale_artifacts(scratch, artifacts)
        result = scratch.run(script, platform, {**env, "CARGO_STUB_NO_ARTIFACT": "1"})
        assert result.returncode != 0, (platform, result.stdout)
        for output in outputs:
            path = scratch.root / output
            assert not path.exists() or "stale" not in path.read_text(encoding="utf-8"), (platform, output)


TESTS = (
    test_clean_build_records_checked_provenance,
    test_dirty_crypto_sources_are_recorded,
    test_git_failure_aborts,
    test_lock_hash_failure_aborts,
    test_rustc_failure_aborts,
    test_toolchain_resolves_inside_the_repository,
    test_artifacts_come_from_the_directory_cargo_built,
    test_missing_fresh_artifact_fails,
)


if __name__ == "__main__":
    failures = 0
    for test in TESTS:
        try:
            test()
        except AssertionError as exc:
            failures += 1
            print(f"FAIL {test.__name__}: {exc}", file=sys.stderr)
    if failures:
        raise SystemExit(1)
    print("Crypto build provenance and artifact path tests passed")
