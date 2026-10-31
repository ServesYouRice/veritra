#!/usr/bin/env python3
"""Import-graph tests for scripts/check-demo-boundary.sh (decision D11).

The token scans in the check are textual. These cases reach main_demo.dart or
the native crypto service library from mobile/lib/main.dart through files
that name none of the scanned tokens, so only the import-graph walk can catch
them. Uses the scratch fixture of check-demo-boundary_test.py. POSIX only.
"""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "check_demo_boundary_test", Path(__file__).resolve().with_name("check-demo-boundary_test.py")
)
assert _spec is not None and _spec.loader is not None
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)

MAIN = base.CLEAN["mobile/lib/main.dart"]

# name -> files to add or replace. Every case must fail.
REACHES: dict[str, dict[str, str]] = {
    "bootstrap imports the demo entry": {
        "mobile/lib/main.dart": "import 'bootstrap.dart';\n" + MAIN,
        "mobile/lib/bootstrap.dart": "import 'main_demo.dart';\n",
    },
    "two hops through a sibling folder": {
        "mobile/lib/main.dart": "import 'app/start.dart';\n" + MAIN,
        "mobile/lib/app/start.dart": "import '../wiring/locator.dart';\n",
        "mobile/lib/wiring/locator.dart": 'import "../main_demo.dart" show main;\n',
    },
    "export chain to the demo entry": {
        "mobile/lib/main.dart": "import 'services.dart';\n" + MAIN,
        "mobile/lib/services.dart": "export 'main_demo.dart' hide main;\n",
    },
    "conditional import alternative": {
        "mobile/lib/main.dart": (
            "import 'stub.dart'\n    if (dart.library.io) 'main_demo.dart';\n" + MAIN
        ),
        "mobile/lib/stub.dart": "void nothing() {}\n",
    },
    "package: URI chain": {
        "mobile/lib/main.dart": "import 'package:private_messenger/boot/run.dart';\n" + MAIN,
        "mobile/lib/boot/run.dart": "import 'package:private_messenger/main_demo.dart';\n",
    },
    "package name read from pubspec": {
        "mobile/pubspec.yaml": "name: renamed_app\n",
        "mobile/lib/main.dart": "import 'package:renamed_app/boot.dart';\n" + MAIN,
        "mobile/lib/boot.dart": "import 'package:renamed_app/main_demo.dart';\n",
    },
    "local path package": {
        "mobile/pubspec.yaml": (
            "name: private_messenger\ndependencies:\n  wiring:\n    path: ../packages/wiring\n"
        ),
        "mobile/lib/main.dart": "import 'package:wiring/wiring.dart';\n" + MAIN,
        "packages/wiring/lib/wiring.dart": "import '../../../mobile/lib/main_demo.dart';\n",
    },
    "local path package with a comment before path": {
        "mobile/pubspec.yaml": (
            "name: private_messenger\ndev_dependencies:\n  wiring:\n"
            "    # kept local\n    path: '../packages/wiring' # in-repo\n"
        ),
        "mobile/lib/main.dart": "import 'package:wiring/wiring.dart';\n" + MAIN,
        "packages/wiring/lib/wiring.dart": "import '../../../mobile/lib/main_demo.dart';\n",
    },
    "transitive path package from pubspec.lock": {
        "mobile/pubspec.lock": (
            "packages:\n  wiring:\n    dependency: transitive\n    description:\n"
            '      path: "../packages/wiring"\n      relative: true\n    source: path\n'
            'sdks:\n  dart: ">=3.4.0 <4.0.0"\n'
        ),
        "mobile/lib/main.dart": "import 'package:wiring/wiring.dart';\n" + MAIN,
        "packages/wiring/lib/wiring.dart": "import '../../../mobile/lib/main_demo.dart';\n",
    },
    "part directive names the native service library": {
        "mobile/lib/main.dart": "import 'shell.dart';\n" + MAIN,
        "mobile/lib/shell.dart": "part 'crypto/native_crypto_service.dart';\n",
    },
    "native service library reached transitively": {
        "mobile/lib/main.dart": "import 'crypto/factory.dart';\n" + MAIN,
        "mobile/lib/crypto/factory.dart": "import 'native_crypto_service.dart' as impl;\n",
    },
    "cycle before the forbidden file": {
        "mobile/lib/main.dart": "import 'a.dart';\n" + MAIN,
        "mobile/lib/a.dart": "import 'b.dart';\n",
        "mobile/lib/b.dart": "import 'a.dart';\nimport 'main_demo.dart';\n",
    },
    "directives on one line": {
        "mobile/lib/main.dart": "import 'a.dart'; import 'b.dart';\n" + MAIN,
        "mobile/lib/a.dart": "void a() {}\n",
        "mobile/lib/b.dart": "import 'main_demo.dart';\n",
    },
}
# name -> files to add or replace. Every case must pass.
HARMLESS: dict[str, dict[str, str]] = {
    # main.dart itself must not even mention main_demo (a textual check), so
    # the comments sit in an imported file.
    "commented-out import": {
        "mobile/lib/main.dart": "import 'notes.dart';\n" + MAIN,
        "mobile/lib/notes.dart": "// import 'main_demo.dart';\n/* import 'main_demo.dart'; */\nvoid n() {}\n",
    },
    "part of directive names the demo entry": {
        "mobile/lib/main.dart": "import 'piece.dart';\n" + MAIN,
        "mobile/lib/piece.dart": "part of 'main_demo.dart';\n",
    },
    "cycle without a forbidden file": {
        "mobile/lib/main.dart": "import 'a.dart';\n" + MAIN,
        "mobile/lib/a.dart": "import 'b.dart';\n",
        "mobile/lib/b.dart": "import 'a.dart';\nimport 'dart:io';\nimport 'package:flutter/material.dart';\n",
    },
    "missing import target": {"mobile/lib/main.dart": "import 'gone.dart';\n" + MAIN},
    "collection-if string literal": {
        "mobile/lib/main.dart": "import 'list.dart';\n" + MAIN,
        "mobile/lib/list.dart": "final names = [if (true) 'main_demo.dart'];\n",
    },
}


def run_case(overrides: dict[str, str], symlinks: dict[str, str] | None = None) -> int:
    with tempfile.TemporaryDirectory() as temp:
        root = base.scratch(Path(temp), overrides)
        for link, target in (symlinks or {}).items():
            os.symlink(target, root / link)
        return base.run(root).returncode


def main() -> None:
    failures = []
    for name, overrides in REACHES.items():
        if run_case(overrides) == 0:
            failures.append(f"not detected: {name}")
    if (
        run_case(
            {
                "mobile/lib/main.dart": "import 'features/entry.dart';\n" + MAIN,
                "mobile/lib/hidden/boot.dart": "import '../main_demo.dart';\n",
            },
            # Dart resolves boot.dart's relative import against the link's
            # own folder, features/, which still lands on lib/main_demo.dart.
            {"mobile/lib/features/entry.dart": "../hidden/boot.dart"},
        )
        == 0
    ):
        failures.append("not detected: symlinked intermediate file")
    if (
        run_case(
            {
                "mobile/lib/main.dart": "import 'features/entry.dart';\n" + MAIN,
                "mobile/lib/hidden/deep/boot.dart": "import '../../main_demo.dart';\n",
            },
            # Resolved from the target's folder this lands on main_demo.dart;
            # from the link's folder it escapes mobile/lib. Both are followed.
            {"mobile/lib/features/entry.dart": "../hidden/deep/boot.dart"},
        )
        == 0
    ):
        failures.append("not detected: symlink to a deeper folder")
    for name, overrides in HARMLESS.items():
        if run_case(overrides) != 0:
            failures.append(f"false positive: {name}")
    if failures:
        print("demo boundary import-graph cases failed:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        raise SystemExit(1)
    print("Demo boundary import-graph tests passed")


if __name__ == "__main__":
    main()
