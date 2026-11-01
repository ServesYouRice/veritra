#!/usr/bin/env python3
"""Scratch-repository tests for scripts/release-image.sh.

Each case clones a bare 'origin' into a scratch repository holding a copy of
the real release script, with stub go, gofmt, docker and trivy first on PATH
and stub check/audit scripts, so nothing is built, scanned, pushed or fetched
from the network. POSIX only (the script is bash).
"""

from __future__ import annotations

import posix_shell

import io
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().with_name("release-image.sh")
IMAGE = "ghcr.io/example/veritra"

LOGGING_STUB = '#!/bin/sh\necho "@NAME@ $*" >> "$STUB_LOG"\n'
DOCKER_STUB = """#!/bin/sh
echo "docker $*" >> "$STUB_LOG"
if [ "$1" = build ]; then
  cat > "$STUB_CONTEXT"
fi
"""
# The check step runs a per-case hook, which is how a case changes the
# repository while the checks are running.
CHECK_STUB = """#!/bin/sh
echo "checks VERITRA_VERIFY_GO_IMAGE_DIGEST=${VERITRA_VERIFY_GO_IMAGE_DIGEST:-}" >> "$STUB_LOG"
if [ -n "${RELEASE_TEST_HOOK:-}" ]; then
  sh "$RELEASE_TEST_HOOK"
fi
"""


def write_executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Scratch:
    def __init__(self, temp: Path) -> None:
        self.temp = temp
        self.origin = temp / "origin.git"
        self.work = temp / "work"
        self.bin = temp / "bin"
        self.log = temp / "stub.log"
        self.context = temp / "context.tar"
        self.git_config = temp / "gitconfig"
        self.git_config.write_text("[init]\n\tdefaultBranch = main\n", encoding="utf-8")

        self.git(temp, "init", "-q", "--bare", "-b", "main", str(self.origin))
        self.git(temp, "clone", "-q", str(self.origin), str(self.work))
        scripts = self.work / "scripts"
        scripts.mkdir()
        shutil.copy2(SCRIPT, scripts / SCRIPT.name)
        write_executable(scripts / "check-go-toolchain.sh", CHECK_STUB)
        write_executable(scripts / "audit-rust.sh", "#!/bin/sh\nexit 0\n")
        (self.work / ".go-version").write_text("1.26.10\n", encoding="utf-8")
        (self.work / "server").mkdir()
        (self.work / "server/Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
        (self.work / "server/main.go").write_text("package main\n// first\n", encoding="utf-8", newline="\n")
        self.commit("release candidate")
        self.git(self.work, "push", "-q", "origin", "main")

        for name in ("go", "gofmt", "trivy"):
            write_executable(self.bin / name, LOGGING_STUB.replace("@NAME@", name))
        write_executable(self.bin / "docker", DOCKER_STUB)

    def env(self) -> dict[str, str]:
        env = {key: value for key, value in os.environ.items() if not key.startswith(("GIT_", "VERITRA_"))}
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

    def git(self, cwd: Path, *args: str) -> str:
        return subprocess.run(
            ["git", *args], cwd=cwd, env=self.env(), check=True, capture_output=True, text=True
        ).stdout.strip()

    def commit(self, message: str) -> str:
        self.git(self.work, "add", "-A")
        self.git(self.work, "commit", "-q", "--allow-empty", "-m", message)
        return self.git(self.work, "rev-parse", "HEAD")

    def hook(self, body: str) -> Path:
        path = self.temp / "hook.sh"
        path.write_text(f"set -e\ncd '{self.work}'\n{body}\n", encoding="utf-8")
        return path

    def run(self, hook: str | None = None, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        self.log.write_text("", encoding="utf-8")
        if self.context.exists():
            self.context.unlink()
        env = self.env()
        env.update(
            {
                "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
                "STUB_LOG": str(self.log),
                "STUB_CONTEXT": str(self.context),
                "VERITRA_IMAGE_REPO": IMAGE,
            }
        )
        if hook is not None:
            env["RELEASE_TEST_HOOK"] = str(self.hook(hook))
        env.update(extra_env or {})
        return subprocess.run(
            [posix_shell.find("bash"), str(self.work / "scripts" / SCRIPT.name), "--no-push", "--skip-smoke"],
            cwd=self.temp,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def log_lines(self, prefix: str) -> list[str]:
        return [line for line in self.log.read_text(encoding="utf-8").splitlines() if line.startswith(prefix)]

    def built_main_go(self) -> str:
        with tarfile.open(fileobj=io.BytesIO(self.context.read_bytes())) as archive:
            member = archive.extractfile("server/main.go")
            assert member is not None
            return member.read().decode("utf-8")


def with_scratch(test):
    def wrapper() -> None:
        with tempfile.TemporaryDirectory() as temp:
            test(Scratch(Path(temp)))

    wrapper.__name__ = test.__name__
    return wrapper


@with_scratch
def test_clean_release_builds_the_checked_commit(scratch: Scratch) -> None:
    commit = scratch.git(scratch.work, "rev-parse", "HEAD")
    result = scratch.run()
    assert result.returncode == 0, result.stderr
    builds = scratch.log_lines("docker build")
    assert len(builds) == 1, scratch.log.read_text(encoding="utf-8")
    assert f"--build-arg COMMIT={commit}" in builds[0], builds
    assert f"-t {IMAGE}:{commit[:12]}" in builds[0], builds
    assert scratch.built_main_go() == "package main\n// first\n"
    assert scratch.log_lines("checks VERITRA_VERIFY_GO_IMAGE_DIGEST=1"), "digest verification not requested"


def assert_refused_before_build(scratch: Scratch, result: subprocess.CompletedProcess[str], label: str) -> None:
    assert result.returncode != 0, (label, result.stdout)
    assert not scratch.log_lines("docker build"), (label, "the image was built")


@with_scratch
def test_head_moving_during_checks_aborts(scratch: Scratch) -> None:
    # A commit lands in the same worktree while the checks run.
    result = scratch.run("echo '// second' >> server/main.go\ngit commit -q -am moved")
    assert_refused_before_build(scratch, result, "new commit")
    assert "HEAD" in result.stderr, result.stderr


@with_scratch
def test_checkout_during_checks_aborts(scratch: Scratch) -> None:
    # HEAD moves back to an older commit that is itself on origin/main.
    scratch.git(scratch.work, "commit", "-q", "--allow-empty", "-m", "second")
    scratch.git(scratch.work, "push", "-q", "origin", "main")
    result = scratch.run("git checkout -q HEAD~1")
    assert_refused_before_build(scratch, result, "checkout")


@with_scratch
def test_tree_changing_during_checks_aborts(scratch: Scratch) -> None:
    result = scratch.run("echo stray > stray.txt")
    assert_refused_before_build(scratch, result, "untracked file")
    result = scratch.run("echo '// edited' >> server/main.go")
    assert_refused_before_build(scratch, result, "modified file")


@with_scratch
def test_dirty_tree_at_start_is_refused(scratch: Scratch) -> None:
    (scratch.work / "stray.txt").write_text("stray\n", encoding="utf-8")
    result = scratch.run()
    assert_refused_before_build(scratch, result, "dirty at start")
    assert not scratch.log_lines("checks"), "checks ran on a dirty tree"


def assert_refused_before_checks(scratch: Scratch, result: subprocess.CompletedProcess[str], label: str) -> None:
    assert result.returncode != 0, (label, result.stdout)
    assert not scratch.log_lines("checks"), (label, "checks ran")
    assert not scratch.log_lines("docker build"), (label, "the image was built")


@with_scratch
def test_unpublished_commit_is_refused(scratch: Scratch) -> None:
    local = scratch.commit("local only")
    result = scratch.run()
    assert_refused_before_checks(scratch, result, "unpushed commit")
    assert local in result.stderr, result.stderr
    # A pushed branch that is not the default branch is refused as well.
    scratch.git(scratch.work, "push", "-q", "origin", "HEAD:refs/heads/feature")
    assert_refused_before_checks(scratch, scratch.run(), "feature branch")


@with_scratch
def test_commit_behind_the_default_branch_is_accepted(scratch: Scratch) -> None:
    # Someone else pushed after this commit; it is still on origin/main.
    other = scratch.temp / "other"
    scratch.git(scratch.temp, "clone", "-q", str(scratch.origin), str(other))
    scratch.git(other, "commit", "-q", "--allow-empty", "-m", "later")
    scratch.git(other, "push", "-q", "origin", "main")
    result = scratch.run()
    assert result.returncode == 0, result.stderr
    assert len(scratch.log_lines("docker build")) == 1


@with_scratch
def test_stale_remote_tracking_ref_is_not_trusted(scratch: Scratch) -> None:
    # origin/main in this clone still names the commit, but the remote's main
    # was rewound past it: only a fresh fetch shows that.
    first = scratch.git(scratch.work, "rev-parse", "HEAD")
    scratch.git(scratch.work, "commit", "-q", "--allow-empty", "-m", "second")
    scratch.git(scratch.work, "push", "-q", "origin", "main")
    scratch.git(scratch.origin, "update-ref", "refs/heads/main", first)
    assert_refused_before_checks(scratch, scratch.run(), "rewound remote")


@with_scratch
def test_unreachable_origin_fails_closed(scratch: Scratch) -> None:
    scratch.git(scratch.work, "remote", "set-url", "origin", str(scratch.temp / "missing.git"))
    assert_refused_before_checks(scratch, scratch.run(), "unreachable origin")


@with_scratch
def test_replaced_history_cannot_publish_a_local_commit(scratch: Scratch) -> None:
    tip = scratch.git(scratch.work, "rev-parse", "HEAD")
    local = scratch.commit("local only")
    # Rewrite origin/main's tip locally so that it appears to descend from the
    # unpublished commit.
    scratch.git(scratch.work, "fetch", "-q", "origin")
    scratch.git(scratch.work, "replace", "--graft", tip, local)
    assert scratch.git(scratch.work, "merge-base", "--is-ancestor", local, "origin/main") == ""
    assert_refused_before_checks(scratch, scratch.run(), "replace ref")
    scratch.git(scratch.work, "replace", "-d", tip)

    grafts = scratch.work / ".git/info/grafts"
    grafts.parent.mkdir(parents=True, exist_ok=True)
    grafts.write_text(f"{tip} {local}\n", encoding="utf-8")
    assert_refused_before_checks(scratch, scratch.run(), "info/grafts")
    grafts.unlink()

    caller_grafts = scratch.temp / "grafts"
    caller_grafts.write_text(f"{tip} {local}\n", encoding="utf-8")
    result = scratch.run(extra_env={"GIT_GRAFT_FILE": str(caller_grafts)})
    assert_refused_before_checks(scratch, result, "GIT_GRAFT_FILE")


TESTS = (
    test_clean_release_builds_the_checked_commit,
    test_head_moving_during_checks_aborts,
    test_checkout_during_checks_aborts,
    test_tree_changing_during_checks_aborts,
    test_dirty_tree_at_start_is_refused,
    test_unpublished_commit_is_refused,
    test_commit_behind_the_default_branch_is_accepted,
    test_stale_remote_tracking_ref_is_not_trusted,
    test_unreachable_origin_fails_closed,
    test_replaced_history_cannot_publish_a_local_commit,
)


if __name__ == "__main__":
    failures = 0
    for test in TESTS:
        try:
            test()
        except AssertionError as exc:
            failures += 1
            print(f"FAIL {test.__name__}: {str(exc)[:300]}", file=sys.stderr)
    if failures:
        raise SystemExit(1)
    print("Release image tests passed")
