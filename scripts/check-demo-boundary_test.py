#!/usr/bin/env python3
"""Fixture tests for scripts/check-demo-boundary.sh (decision D11).

Each case copies the real script into a scratch root with a minimal
mobile/lib that passes, adds one way of reaching the native crypto service or
the demo transport from outside the allowed files, and expects the check to
fail. POSIX only (the check is sh).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().with_name("check-demo-boundary.sh")

CLEAN = {
    "mobile/lib/main.dart": "void main() => run(cryptoService: UnavailableCryptoService());\n",
    "mobile/lib/main_demo.dart": (
        "import 'crypto/native_crypto_service.dart';\n"
        "import 'core/transport_policy.dart';\n"
        "const demo = bool.fromEnvironment('VERITRA_DEMO');\n"
        "final service = NativeCryptoService(bindings: bindings);\n"
        "final transport = TransportPolicy.demo;\n"
    ),
    "mobile/lib/crypto/native_crypto_service.dart": (
        "class NativeCryptoService {\n  NativeCryptoService({required this.bindings});\n}\n"
        "String messageKey(String a, String b) => a + b;\n"
    ),
    "mobile/lib/core/transport_policy.dart": (
        "class TransportPolicy {\n"
        "  const TransportPolicy({this.allowLoopbackHttp = false});\n"
        "  static const TransportPolicy demo = TransportPolicy(allowLoopbackHttp: true);\n"
        "  final bool allowLoopbackHttp;\n"
        "}\n"
    ),
    "mobile/lib/features/connect.dart": (
        "import '../core/transport_policy.dart';\n"
        "String hint(TransportPolicy t) => t.allowLoopbackHttp\n    ? 'loopback'\n    : 'https';\n"
        "const production = TransportPolicy.production;\n"
    ),
    ".github/workflows/release.yml": "jobs:\n  build:\n    steps:\n      - run: flutter build apk --release\n",
}

# name -> files to add or replace (relative to the scratch root)
BYPASSES: dict[str, dict[str, str]] = {
    "constructor call": {"mobile/lib/features/a.dart": "final s = NativeCryptoService(bindings: b);\n"},
    "whitespace before the parenthesis": {"mobile/lib/features/a.dart": "final s = NativeCryptoService (bindings: b);\n"},
    "constructor tear-off": {"mobile/lib/features/a.dart": "final make = NativeCryptoService.new;\n"},
    "named constructor": {"mobile/lib/features/a.dart": "final s = NativeCryptoService.create();\n"},
    "static accessor": {"mobile/lib/features/a.dart": "final s = NativeCryptoService.instance;\n"},
    "type annotation": {"mobile/lib/features/a.dart": "NativeCryptoService? service;\n"},
    "typedef alias": {"mobile/lib/features/a.dart": "typedef Service = NativeCryptoService;\n"},
    "package import": {
        "mobile/lib/features/a.dart": "import 'package:private_messenger/crypto/native_crypto_service.dart';\n"
    },
    "relative import of a top-level function": {
        "mobile/lib/features/a.dart": "import '../crypto/native_crypto_service.dart' show messageKey;\n"
    },
    "sibling import": {"mobile/lib/crypto/other.dart": "import 'native_crypto_service.dart';\n"},
    "export": {"mobile/lib/crypto.dart": "export 'crypto/native_crypto_service.dart';\n"},
    "conditional import": {
        "mobile/lib/features/a.dart": "import 'stub.dart'\n    if (dart.library.io) 'native_crypto_service.dart';\n"
    },
    "nested main_demo.dart": {"mobile/lib/features/main_demo.dart": "final s = NativeCryptoService(bindings: b);\n"},
    "nested crypto/native_crypto_service.dart": {
        "mobile/lib/features/crypto/native_crypto_service.dart": "final t = TransportPolicy.demo;\n"
    },
    "nested core/transport_policy.dart": {
        "mobile/lib/features/core/transport_policy.dart": "final s = NativeCryptoService(bindings: b);\n"
    },
    "demo transport": {"mobile/lib/features/a.dart": "final t = TransportPolicy.demo;\n"},
    "demo transport with whitespace": {"mobile/lib/features/a.dart": "final t = TransportPolicy . demo;\n"},
    "demo transport built by hand": {
        "mobile/lib/features/a.dart": "const t = TransportPolicy(allowLoopbackHttp: true);\n"
    },
    "demo transport inside the native service file": {
        "mobile/lib/crypto/native_crypto_service.dart": CLEAN["mobile/lib/crypto/native_crypto_service.dart"]
        + "final t = TransportPolicy.demo;\n"
    },
    "native service inside the transport policy file": {
        "mobile/lib/core/transport_policy.dart": CLEAN["mobile/lib/core/transport_policy.dart"]
        + "final s = NativeCryptoService(bindings: b);\n"
    },
    "main.dart imports the demo": {
        "mobile/lib/main.dart": CLEAN["mobile/lib/main.dart"] + "import 'main_demo.dart';\n"
    },
    "main.dart drops the unavailable service": {"mobile/lib/main.dart": "void main() {}\n"},
    "release workflow builds the demo": {
        ".github/workflows/release.yml": "jobs:\n  build:\n    steps:\n      - run: flutter build apk -t lib/main_demo.dart\n"
    },
}


def scratch(temp: Path, overrides: dict[str, str]) -> Path:
    root = temp / "root"
    (root / "scripts").mkdir(parents=True)
    shutil.copy2(SCRIPT, root / "scripts" / SCRIPT.name)
    for relative, content in {**CLEAN, **overrides}.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    return root


def run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["sh", str(root / "scripts" / SCRIPT.name)], capture_output=True, text=True, check=False
    )


def test_clean_fixture_passes() -> None:
    with tempfile.TemporaryDirectory() as temp:
        result = run(scratch(Path(temp), {}))
        assert result.returncode == 0, result.stderr


def test_each_bypass_fails() -> list[str]:
    passed = []
    for name, overrides in BYPASSES.items():
        with tempfile.TemporaryDirectory() as temp:
            result = run(scratch(Path(temp), overrides))
            if result.returncode == 0:
                passed.append(name)
    return passed


def test_symlinked_demo_entry_fails() -> bool:
    with tempfile.TemporaryDirectory() as temp:
        root = scratch(Path(temp), {})
        os.symlink("../main_demo.dart", root / "mobile/lib/features/entry.dart")
        return run(root).returncode != 0


def test_missing_lib_fails() -> bool:
    with tempfile.TemporaryDirectory() as temp:
        root = scratch(Path(temp), {})
        shutil.rmtree(root / "mobile/lib")
        return run(root).returncode != 0


def test_real_tree_passes() -> None:
    result = subprocess.run(["sh", str(SCRIPT)], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr


if __name__ == "__main__":
    test_clean_fixture_passes()
    test_real_tree_passes()
    undetected = test_each_bypass_fails()
    if not test_symlinked_demo_entry_fails():
        undetected.append("symlink to main_demo.dart")
    if not test_missing_lib_fails():
        undetected.append("missing mobile/lib")
    if undetected:
        print("demo boundary bypasses not detected:", file=sys.stderr)
        for name in undetected:
            print(f"  {name}", file=sys.stderr)
        raise SystemExit(1)
    print("Demo boundary fixture tests passed")
    # CI and scripts/test.sh run only this file; the import-graph cases live
    # in their own file and load this one as a module, so no recursion.
    import importlib.util

    _graph = importlib.util.spec_from_file_location(
        "check_demo_boundary_imports_test", SCRIPT.with_name("check-demo-boundary-imports_test.py")
    )
    assert _graph is not None and _graph.loader is not None
    _module = importlib.util.module_from_spec(_graph)
    _graph.loader.exec_module(_module)
    _module.main()
