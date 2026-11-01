"""Locate a POSIX shell for tests that run the repository's sh/bash scripts.

On Windows, bare `sh`/`bash` can resolve to WSL's launcher, which cannot read
Windows paths, so use Git for Windows' own shell explicitly.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


def _git_for_windows_bin() -> Path | None:
    candidates = [
        Path(base) / "Git" / "bin"
        for var in ("ProgramFiles", "ProgramW6432", "ProgramFiles(x86)")
        if (base := os.environ.get(var))
    ]
    git = shutil.which("git")
    if git:
        candidates.append(Path(git).resolve().parent.parent / "bin")
    for candidate in candidates:
        if (candidate / "bash.exe").is_file():
            return candidate
    return None


def find(name: str = "sh") -> str:
    """Path of the POSIX shell `name` ("sh" or "bash")."""
    if os.name == "nt":
        directory = _git_for_windows_bin()
        if directory is None:
            raise RuntimeError("Git for Windows (Git Bash) is required to run the shell scripts' tests")
        return str(directory.parent / "usr" / "bin" / f"{name}.exe")
    return shutil.which(name) or f"/bin/{name}"


def usr_bin() -> str | None:
    """Git for Windows' coreutils directory (None off Windows)."""
    if os.name != "nt":
        return None
    directory = _git_for_windows_bin()
    return None if directory is None else str(directory.parent / "usr" / "bin")


def rmtree(path: Path) -> None:
    """rmtree that also removes read-only repository objects on Windows."""

    def clear_readonly(func, target, _exc):
        os.chmod(target, 0o700)
        func(target)

    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=clear_readonly)
    else:
        shutil.rmtree(path, onerror=clear_readonly)


def write_python3_shim(directory: str | Path) -> None:
    """Write a POSIX `python3` that runs this interpreter."""
    exe = sys.executable.replace("\\", "/")
    (Path(directory) / "python3").write_text(f'#!/bin/sh\nexec "{exe}" "$@"\n', encoding="utf-8", newline="\n")


def _shim_python3() -> None:
    """Windows has no python3; the Store alias on PATH fails. Shadow it."""
    import atexit
    import tempfile

    directory = tempfile.mkdtemp(prefix="veritra-python3-")
    atexit.register(shutil.rmtree, directory, ignore_errors=True)
    write_python3_shim(directory)
    os.environ["PATH"] = directory + os.pathsep + os.environ.get("PATH", "")


if os.name == "nt":
    _shim_python3()
