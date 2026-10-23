#!/usr/bin/env python3
"""Tests for the Serbian Cyrillic to Latin ARB transliteration (card T44C).

Also fails when mobile/lib/l10n/app_sr_Latn.arb is not exactly the
transliteration of app_sr.arb, so only the Cyrillic file needs a review.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("l10n-sr-latn.py")
spec = importlib.util.spec_from_file_location("l10n_sr_latn", MODULE_PATH)
assert spec and spec.loader
latn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(latn)


def expect_error(message: str) -> None:
    try:
        latn.transliterate_message(message)
    except ValueError:
        return
    raise AssertionError(f"expected {message!r} to be rejected")


def test_letters() -> None:
    cyrillic = "абвгдђежзијклљмнњопрстћуфхцчџш"
    latin = "abvgdđežzijklljmnnjoprstćufhcčdžš"
    assert latn.transliterate_text(cyrillic) == latin
    assert latn.transliterate_text(cyrillic.upper()) == latin.upper()
    assert latn.transliterate_text("Ђорђе Ћирић Чачак Жабаљ Шабац") == "Đorđe Ćirić Čačak Žabalj Šabac"


def test_digraph_case() -> None:
    cases = {
        "Љубав": "Ljubav",
        "ЉУБАВ": "LJUBAV",
        "Његов": "Njegov",
        "ЊЕГОВ": "NJEGOV",
        "Џеп": "Džep",
        "ЏЕП": "DŽEP",
        "МОЉ": "MOLJ",
        "Љ": "Lj",
        "Љ.": "Lj.",
        "ПОЉЕ И Њ": "POLJE I Nj",
        "Њ-Ж": "Nj-Ž",
        "УЏ.": "UDŽ.",
    }
    for cyrillic, expected in cases.items():
        actual = latn.transliterate_text(cyrillic)
        assert actual == expected, (cyrillic, actual, expected)


def test_non_cyrillic_is_kept() -> None:
    text = "Veritra · https://chat.example.org (acct_…) 12–72 „QR“ 👍"
    assert latn.transliterate_text(text) == text


def test_messages_keep_their_syntax() -> None:
    cases = {
        "Копирано: {label}.": "Kopirano: {label}.",
        "{count}": "{count}",
        "Порука од {sender}, {time}: {text}": "Poruka od {sender}, {time}: {text}",
        "{count, plural, one{{count} дан} few{{count} дана} other{{count} дана}}":
            "{count, plural, one{{count} dan} few{{count} dana} other{{count} dana}}",
        "{count, plural, =0{Ништа} one{Један {count}} other{Још {count}}}":
            "{count, plural, =0{Ništa} one{Jedan {count}} other{Još {count}}}",
        "{state, select, pending{на чекању} other{{state}}}":
            "{state, select, pending{na čekanju} other{{state}}}",
        "Пре {n, plural, one{# дан} other{# дана}} — ЏЕП":
            "Pre {n, plural, one{# dan} other{# dana}} — DŽEP",
        "{when, date, yMd} и даље": "{when, date, yMd} i dalje",
    }
    for cyrillic, expected in cases.items():
        actual = latn.transliterate_message(cyrillic)
        assert actual == expected, (cyrillic, actual, expected)


def test_placeholder_names_and_keywords_are_never_transliterated() -> None:
    # Cyrillic inside the syntax would be a bug in app_sr.arb, but it must
    # still come through untouched rather than silently "fixed".
    message = "{број, plural, one{{број} ж} other{ж}}"
    assert latn.transliterate_message(message) == "{број, plural, one{{број} ž} other{ž}}"


def test_malformed_messages_are_rejected() -> None:
    for bad in (
        "{count",
        "text }",
        "{count, plural, one{дан}",
        "{count, plural, one{дан} other}",
        "{count, plural, {дан}}",
        "{count, plural}",
    ):
        expect_error(bad)


def test_arb_conversion() -> None:
    source = {
        "@@locale": "sr",
        "greeting": "Здраво, {name}!",
        "@greeting": {"description": "Поздрав", "placeholders": {"name": {"type": "String"}}},
    }
    result = latn.transliterate_arb(source)
    assert list(result) == ["@@locale", "@@x-generated", "greeting", "@greeting"]
    assert result["@@locale"] == "sr_Latn"
    assert result["greeting"] == "Zdravo, {name}!"
    # Metadata is left alone, even when it holds Cyrillic.
    assert result["@greeting"] == source["@greeting"]

    for bad in ({"@@locale": "en"}, {"greeting": "x"}, {"@@locale": "sr", "count": 1}):
        try:
            latn.transliterate_arb(bad)
        except ValueError:
            continue
        raise AssertionError(f"expected {bad!r} to be rejected")


def test_cli_check() -> None:
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "app_sr.arb"
        target = Path(directory) / "app_sr_Latn.arb"
        source.write_text(json.dumps({"@@locale": "sr", "hello": "Ћао"}), encoding="utf-8")

        def run(*args: str) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [sys.executable, str(MODULE_PATH), "--source", str(source), "--target", str(target), *args],
                capture_output=True,
                text=True,
                check=False,
            )

        assert run("--check").returncode == 1, "a missing target must fail the check"
        assert run().returncode == 0
        assert json.loads(target.read_text(encoding="utf-8"))["hello"] == "Ćao"
        assert run("--check").returncode == 0
        target.write_text(target.read_text(encoding="utf-8").replace("Ćao", "Cao"), encoding="utf-8")
        assert run("--check").returncode == 1, "a hand edit must fail the check"


def test_repository_latin_file_is_up_to_date() -> None:
    expected = latn.render(latn.SOURCE.read_text(encoding="utf-8"))
    actual = latn.TARGET.read_text(encoding="utf-8")
    assert actual == expected, (
        f"{latn.TARGET} is not the transliteration of {latn.SOURCE}. "
        "Run python3 scripts/l10n-sr-latn.py and commit the result."
    )


if __name__ == "__main__":
    test_letters()
    test_digraph_case()
    test_non_cyrillic_is_kept()
    test_messages_keep_their_syntax()
    test_placeholder_names_and_keywords_are_never_transliterated()
    test_malformed_messages_are_rejected()
    test_arb_conversion()
    test_cli_check()
    test_repository_latin_file_is_up_to_date()
    print("Serbian Latin transliteration tests passed")
