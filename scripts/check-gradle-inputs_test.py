#!/usr/bin/env python3
"""Fixture tests for scripts/check-gradle-inputs.py."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import shutil
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
REAL_ANDROID = SCRIPTS.parent / "mobile/android"
spec = importlib.util.spec_from_file_location("check_gradle_inputs", SCRIPTS / "check-gradle-inputs.py")
assert spec and spec.loader
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

BASELINE = ("app/build.gradle.kts", "build.gradle.kts", "settings.gradle.kts", "gradle/wrapper/gradle-wrapper.properties")


def run(android: Path) -> tuple[int, str]:
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
        code = checker.main([str(android)])
    return code, stderr.getvalue()


@contextlib.contextmanager
def android_copy():
    """A copy of the repository's Android build inputs (which pass)."""
    with tempfile.TemporaryDirectory() as temp:
        android = Path(temp) / "android"
        for relative in BASELINE:
            target = android / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REAL_ANDROID / relative, target)
        yield android


def append(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(text)


def test_real_tree_passes() -> None:
    code, stderr = run(REAL_ANDROID)
    assert code == 0, stderr


def test_dynamic_forms_fail_in_the_app_script() -> None:
    forms = (
        'implementation("com.example:lib:1.+")',
        'implementation("com.example:lib:1.2.+")',
        'implementation("com.example:lib:1.2.3+")',
        'implementation("com.example:lib:+")',
        'implementation("com.example:lib:+@aar")',
        'implementation("com.example:lib:[1.0,2.0)")',
        'implementation("com.example:lib:(,2.0]")',
        'implementation("com.example:lib:]1.0,2.0[")',
        'implementation("com.example:lib") { version { strictly("[1.0, 2.0[") } }',
        'implementation("com.example:lib") { version { prefer("1.+") } }',
        'implementation("com.example:lib:latest.release")',
        'implementation("com.example:lib:latest.integration")',
        'implementation("com.example:lib:LATEST.RELEASE")',
        'implementation("com.example:lib:latest")',
        'implementation("com.example:lib:release")',
        'implementation("com.example:lib:snapshot")',
        'implementation("com.example:lib:1.0-SNAPSHOT")',
        'implementation("com.example:lib:1.0-snapshot")',
        "implementation('com.example:lib:1.+')",
        'implementation("""com.example:lib:1.+""")',
    )
    for form in forms:
        with android_copy() as android:
            append(android / "app/build.gradle.kts", f"\ndependencies {{\n    {form}\n}}\n")
            code, stderr = run(android)
            assert code == 1, form
            assert "app/build.gradle.kts:" in stderr.replace("\\", "/"), (form, stderr)


def test_every_build_file_is_scanned() -> None:
    cases = {
        # A non-app Groovy module.
        "feature/build.gradle": "dependencies {\n    implementation 'com.example:lib:1.+'\n}\n",
        # The root build script.
        "build.gradle.kts": 'buildscript { dependencies { classpath("com.android.tools.build:gradle:8.+") } }\n',
        # Plugin versions in settings.
        "settings.gradle.kts": 'plugins { id("com.example.plugin") version "1.+" }\n',
        "settings.gradle": "plugins { id 'com.example.plugin' version '2.0-SNAPSHOT' }\n",
        # Version catalogs.
        "gradle/libs.versions.toml": '[versions]\nkotlin = "2.+"\n',
        "gradle/other.versions.toml": '[libraries]\nlib = { module = "a:b", version = { strictly = "[1.0,2.0)" } }\n',
        "catalogs/extra.versions.toml": '[versions]\nlib = "latest.release"\n',
    }
    for relative, text in cases.items():
        with android_copy() as android:
            append(android / relative, text)
            code, stderr = run(android)
            assert code == 1, relative
            assert relative.split("/")[-1] in stderr, (relative, stderr)


def test_comments_and_code_are_not_versions() -> None:
    with android_copy() as android:
        append(
            android / "app/build.gradle.kts",
            "\n// implementation(\"com.example:lib:1.+\")\n"
            '/* implementation("com.example:lib:latest.release")\n   "1.0-SNAPSHOT" */\n'
            'val total = 1 + 2\nval joined = "a" + "b"\nval spaced = "c + d"\n'
            "val quote = '\"'\nval slash = '\\\\'\n"
            'implementation("com.example:lib:1.2.3")  // was 1.+\n',
        )
        append(android / "gradle/libs.versions.toml", '# kotlin = "1.+"\n[versions]\nkotlin = "2.3.20" # not 2.+\n')
        code, stderr = run(android)
        assert code == 0, stderr


def test_fails_closed() -> None:
    # No app build script at all: nothing to vouch for.
    with android_copy() as android:
        (android / "app/build.gradle.kts").unlink()
        assert run(android)[0] == 1
    # A Groovy app script is accepted in its place, and scanned.
    with android_copy() as android:
        (android / "app/build.gradle.kts").unlink()
        append(android / "app/build.gradle", "dependencies { implementation 'com.example:lib:1.2.3' }\n")
        assert run(android)[0] == 0
        append(android / "app/build.gradle", "dependencies { implementation 'com.example:lib:1.+' }\n")
        assert run(android)[0] == 1
    # The Android project itself is missing.
    with tempfile.TemporaryDirectory() as temp:
        assert run(Path(temp) / "android")[0] == 1
    # An unreadable file.
    with android_copy() as android:
        (android / "feature").mkdir()
        (android / "feature/build.gradle.kts").write_bytes(b"\xff\xfe\x00not utf-8")
        assert run(android)[0] == 1
    # An unterminated string or comment could hide anything after it.
    for text in ('implementation("com.example:lib:1.2.3)\n', "/* never closed\n", 'val s = """open\n'):
        with android_copy() as android:
            append(android / "app/build.gradle.kts", text)
            assert run(android)[0] == 1, text


CHECKSUM = "0" * 63 + "1"
WRAPPER_HEAD = "distributionBase=GRADLE_USER_HOME\ndistributionPath=wrapper/dists\n"
GOOD_URL = r"distributionUrl=https\://services.gradle.org/distributions/gradle-9.1.0-all.zip"


def run_wrapper(properties: str | None) -> tuple[int, str]:
    with android_copy() as android:
        path = android / "gradle/wrapper/gradle-wrapper.properties"
        if properties is None:
            path.unlink()
        else:
            path.write_text(properties, encoding="utf-8")
        return run(android)


def test_wrapper_must_be_pinned_to_services_gradle_org() -> None:
    accepted = (
        f"{WRAPPER_HEAD}{GOOD_URL}\ndistributionSha256Sum={CHECKSUM}\n",
        # Unescaped, ':' separator, other order, a continuation line.
        f"distributionSha256Sum : {CHECKSUM}\n"
        "distributionUrl: https://services.gradle.org/distributions/gradle-8.14-bin.zip\n",
        f"distributionUrl=https\\://services.gradle.org/\\\n    distributions/gradle-9.1.0-all.zip\ndistributionSha256Sum={CHECKSUM}\n",
    )
    for properties in accepted:
        code, stderr = run_wrapper(properties)
        assert code == 0, (properties, stderr)
        assert "warning" not in stderr, stderr

    rejected = {
        "plain http": f"distributionUrl=http\\://services.gradle.org/distributions/gradle-9.1.0-all.zip\ndistributionSha256Sum={CHECKSUM}\n",
        "foreign host": f"distributionUrl=https\\://mirror.example.invalid/distributions/gradle-9.1.0-all.zip\ndistributionSha256Sum={CHECKSUM}\n",
        "look-alike host": f"distributionUrl=https\\://services.gradle.org.example.invalid/distributions/gradle-9.1.0-all.zip\ndistributionSha256Sum={CHECKSUM}\n",
        "userinfo": f"distributionUrl=https\\://services.gradle.org@example.invalid/distributions/gradle-9.1.0-all.zip\ndistributionSha256Sum={CHECKSUM}\n",
        "other path": f"distributionUrl=https\\://services.gradle.org/other/gradle-9.1.0-all.zip\ndistributionSha256Sum={CHECKSUM}\n",
        "query": f"{GOOD_URL}?x=1\ndistributionSha256Sum={CHECKSUM}\n",
        "unpinned version": "distributionUrl=https\\://services.gradle.org/distributions/gradle-latest-all.zip\n",
        "no url": f"{WRAPPER_HEAD}distributionSha256Sum={CHECKSUM}\n",
        "duplicate url": f"{GOOD_URL}\n{GOOD_URL.replace('9.1.0', '9.0.0')}\ndistributionSha256Sum={CHECKSUM}\n",
        "malformed checksum (short)": f"{GOOD_URL}\ndistributionSha256Sum={CHECKSUM[1:]}\n",
        "malformed checksum (upper case)": f"{GOOD_URL}\ndistributionSha256Sum={CHECKSUM.upper()[:-1]}A\n",
        "malformed checksum (not hex)": f"{GOOD_URL}\ndistributionSha256Sum={'g' * 64}\n",
        "empty file": "",
    }
    for name, properties in rejected.items():
        code, stderr = run_wrapper(properties)
        assert code == 1, (name, stderr)
    assert run_wrapper(None)[0] == 1


def test_missing_wrapper_checksum_is_reported() -> None:
    # Not yet a failure: the repository's properties file has no checksum and
    # adding it is outside this change. It is reported on every run.
    code, stderr = run_wrapper(f"{WRAPPER_HEAD}{GOOD_URL}\n")
    assert code == 0, stderr
    assert "no distributionSha256Sum" in stderr, stderr
    assert "https://services.gradle.org/distributions/gradle-9.1.0-all.zip.sha256" in stderr, stderr


if __name__ == "__main__":
    test_real_tree_passes()
    test_dynamic_forms_fail_in_the_app_script()
    test_every_build_file_is_scanned()
    test_comments_and_code_are_not_versions()
    test_fails_closed()
    test_wrapper_must_be_pinned_to_services_gradle_org()
    test_missing_wrapper_checksum_is_reported()
    print("Gradle input fixture tests passed")
