#!/usr/bin/env python3
"""Writes the Latin-script Serbian strings from the Cyrillic ones (card T44C).

`mobile/lib/l10n/app_sr_Latn.arb` is a deterministic transliteration of
`mobile/lib/l10n/app_sr.arb`, so a reviewer only has to read the Cyrillic
file. Only message text changes. Placeholder names, ICU keywords (`plural`,
`select`), plural and select case keys (`one`, `few`, `other`, `=0`, ...) and
`@` metadata are copied unchanged.

Usage:
  python3 scripts/l10n-sr-latn.py          rewrite app_sr_Latn.arb
  python3 scripts/l10n-sr-latn.py --check  exit 1 if it is not up to date
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
L10N_DIR = ROOT / "mobile" / "lib" / "l10n"
SOURCE = L10N_DIR / "app_sr.arb"
TARGET = L10N_DIR / "app_sr_Latn.arb"

TARGET_LOCALE = "sr_Latn"
GENERATED_NOTE = (
    "Generated from app_sr.arb by scripts/l10n-sr-latn.py. Do not edit; "
    "change app_sr.arb and run the script again."
)

# Serbian Cyrillic to Serbian Latin (gajica), one letter at a time. The three
# letters that become two Latin letters are handled in _digraph.
_LETTERS = {
    "А": "A", "Б": "B", "В": "V", "Г": "G", "Д": "D", "Ђ": "Đ", "Е": "E",
    "Ж": "Ž", "З": "Z", "И": "I", "Ј": "J", "К": "K", "Л": "L", "Љ": "Lj",
    "М": "M", "Н": "N", "Њ": "Nj", "О": "O", "П": "P", "Р": "R", "С": "S",
    "Т": "T", "Ћ": "Ć", "У": "U", "Ф": "F", "Х": "H", "Ц": "C", "Ч": "Č",
    "Џ": "Dž", "Ш": "Š",
}
_LETTERS.update({upper.lower(): latin.lower() for upper, latin in list(_LETTERS.items())})
_DIGRAPHS = {"Љ": "LJ", "Њ": "NJ", "Џ": "DŽ"}

_CASE_KEYWORDS = {"plural", "select", "selectordinal"}


def _digraph(text: str, index: int) -> str:
    """Lj or LJ for a capital Љ (likewise Њ, Џ), from the letters around it.

    All capitals when the next letter is a capital, or when no letter follows
    and the previous letter is a capital ("ЊЕГОВ" -> "NJEGOV", "МОЉ" ->
    "MOLJ"); otherwise only the first Latin letter is a capital ("Његов" ->
    "Njegov", a lone "Љ" -> "Lj").
    """
    char = text[index]
    following = text[index + 1] if index + 1 < len(text) else ""
    if following.isalpha():
        return _DIGRAPHS[char] if following.isupper() else _LETTERS[char]
    previous = text[index - 1] if index > 0 else ""
    if previous.isalpha() and previous.isupper():
        return _DIGRAPHS[char]
    return _LETTERS[char]


def transliterate_text(text: str) -> str:
    """Transliterates plain text. Characters that are not Serbian Cyrillic,
    such as Latin words, digits and punctuation, are kept as they are."""
    out = []
    for index, char in enumerate(text):
        if char in _DIGRAPHS:
            out.append(_digraph(text, index))
        else:
            out.append(_LETTERS.get(char, char))
    return "".join(out)


def transliterate_message(message: str) -> str:
    """Transliterates the text of one ICU message, leaving its syntax alone.

    The repository's gen-l10n runs without `use-escaping`, so every `{`
    opens an argument and apostrophes are ordinary text.
    """
    out, end = _message(message, 0, nested=False)
    assert end == len(message)
    return out


def _message(source: str, index: int, *, nested: bool) -> tuple[str, int]:
    """Parses text and arguments up to the end, or up to the `}` that closes
    a plural/select case when [nested]. Returns the output and the index of
    that `}` (or the end)."""
    out = []
    start = index
    while index < len(source):
        char = source[index]
        if char == "{":
            out.append(transliterate_text(source[start:index]))
            argument, index = _argument(source, index)
            out.append(argument)
            start = index
        elif char == "}":
            if not nested:
                raise ValueError(f"unmatched '}}' at {index} in {source!r}")
            break
        else:
            index += 1
    else:
        if nested:
            raise ValueError(f"unterminated case in {source!r}")
    out.append(transliterate_text(source[start:index]))
    return "".join(out), index


def _argument(source: str, index: int) -> tuple[str, int]:
    """Copies `{name}` or `{name, type, ...}` starting at [index]. Only the
    case messages of a plural or select are transliterated. Returns the
    output and the index after the closing `}`."""
    name_end = _find_any(source, index + 1, ",}")
    if source[name_end] == "}":
        return source[index : name_end + 1], name_end + 1
    type_end = _find_any(source, name_end + 1, ",}")
    kind = source[name_end + 1 : type_end].strip()
    if kind not in _CASE_KEYWORDS:
        close = _matching_close(source, index)
        return source[index : close + 1], close + 1
    if source[type_end] == "}":
        raise ValueError(f"{kind} without cases in {source!r}")
    out = [source[index : type_end + 1]]
    position = type_end + 1
    while True:
        open_brace = _find_any(source, position, "{}")
        if source[open_brace] == "}":
            if source[position:open_brace].strip():
                raise ValueError(f"case key without a message in {source!r}")
            out.append(source[position : open_brace + 1])
            return "".join(out), open_brace + 1
        if not source[position:open_brace].strip():
            raise ValueError(f"case message without a key in {source!r}")
        # The case key and the whitespace around it, then `{`.
        out.append(source[position : open_brace + 1])
        body, close = _message(source, open_brace + 1, nested=True)
        out.append(body)
        out.append("}")
        position = close + 1


def _find_any(source: str, index: int, chars: str) -> int:
    while index < len(source):
        if source[index] in chars:
            return index
        index += 1
    raise ValueError(f"unterminated argument in {source!r}")


def _matching_close(source: str, index: int) -> int:
    depth = 0
    for position in range(index, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return position
    raise ValueError(f"unterminated argument in {source!r}")


def transliterate_arb(source: dict[str, object]) -> dict[str, object]:
    """The Latin ARB for a Cyrillic one, in the same key order."""
    if source.get("@@locale") != "sr":
        raise ValueError('the source ARB must have "@@locale": "sr"')
    result: dict[str, object] = {}
    for key, value in source.items():
        if key == "@@locale":
            result[key] = TARGET_LOCALE
            result["@@x-generated"] = GENERATED_NOTE
        elif key == "@@x-generated":
            raise ValueError("the source ARB must not carry @@x-generated")
        elif key.startswith("@"):
            result[key] = value
        elif isinstance(value, str):
            result[key] = transliterate_message(value)
        else:
            raise ValueError(f"message {key!r} is not a string")
    return result


def render(source_text: str) -> str:
    """The exact text of app_sr_Latn.arb for the text of app_sr.arb."""
    source = json.loads(source_text)
    if not isinstance(source, dict):
        raise ValueError("the source ARB must be a JSON object")
    return json.dumps(transliterate_arb(source), ensure_ascii=False, indent=2) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail if the Latin file is out of date")
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--target", type=Path, default=TARGET)
    args = parser.parse_args(argv)

    expected = render(args.source.read_text(encoding="utf-8"))
    if args.check:
        actual = args.target.read_text(encoding="utf-8") if args.target.exists() else None
        if actual != expected:
            print(
                f"{args.target} is not the transliteration of {args.source}. "
                "Run python3 scripts/l10n-sr-latn.py and commit the result.",
                file=sys.stderr,
            )
            return 1
        return 0
    with args.target.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(expected)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
