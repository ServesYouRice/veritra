#!/usr/bin/env python3
"""Regenerates mobile/lib/features/chat/emoji_data.dart (W6).

The reaction picker needs "any emoji" without a new dependency, so the list is
generated here from Perl's Unicode tables (the Emoji property and character
names; Perl 5.38 ships Unicode 15.0, under the Unicode License v3) and the
ISO 3166-1 country names in tzdata's iso3166.tab (public domain). Run it again
when Perl or tzdata moves to a newer version, then format the result:

    python3 scripts/gen-emoji-data.py
    (cd mobile && dart format lib/features/chat/emoji_data.dart)

Only single code point emoji, country flags and a short list of common ZWJ
sequences are listed. Anything else can still be typed or pasted into the
picker. Grouping is by code point range and approximates the CLDR groups.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "mobile" / "lib" / "features" / "chat" / "emoji_data.dart"
ISO = pathlib.Path("/usr/share/zoneinfo/iso3166.tab")

PERL = r'''
use charnames ':full';
binmode STDOUT, ':utf8';
for my $cp (0x80 .. 0x1FFFF) {
  my $c = chr($cp);
  next unless $c =~ /\p{Emoji}/;
  next if $c =~ /\p{Emoji_Modifier}/;
  next if $cp >= 0x1F1E6 && $cp <= 0x1F1FF;
  my $n = charnames::viacode($cp);
  next unless defined $n;
  printf "%X\t%d\t%s\n", $cp, ($c =~ /\p{Emoji_Presentation}/ ? 1 : 0), lc $n;
}
'''

# First match wins. Ranges are inclusive code points.
RULES = [
    ("smileys", [(0x1F600, 0x1F644), (0x1F648, 0x1F64A), (0x1F910, 0x1F915),
                 (0x1F917, 0x1F917), (0x1F920, 0x1F925), (0x1F927, 0x1F92F),
                 (0x1F970, 0x1F97A), (0x1FAE0, 0x1FAE8), (0x1F47B, 0x1F480),
                 (0x1F4A9, 0x1F4A9), (0x1F498, 0x1F49F), (0x2763, 0x2764),
                 (0x1F5A4, 0x1F5A4), (0x1F90D, 0x1F90E), (0x1F9E1, 0x1F9E1),
                 (0x1F4A2, 0x1F4A2), (0x1F4A4, 0x1F4A6), (0x1F4A8, 0x1F4A8),
                 (0x1F4AB, 0x1F4AD), (0x1F4AF, 0x1F4AF), (0x1F5E8, 0x1F5E8),
                 (0x1F5EF, 0x1F5EF), (0x263A, 0x263A), (0x2639, 0x2639),
                 (0x1F48B, 0x1F48C), (0x1F9D0, 0x1F9D0), (0x1F916, 0x1F916),
                 (0x1F4A5, 0x1F4A5), (0x1F573, 0x1F573)]),
    ("people", [(0x1F440, 0x1F450), (0x1F466, 0x1F478), (0x1F47C, 0x1F47C),
                (0x1F481, 0x1F487), (0x1F645, 0x1F647), (0x1F64B, 0x1F64F),
                (0x1F6B6, 0x1F6B6), (0x1F6C0, 0x1F6C0), (0x1F6CC, 0x1F6CC),
                (0x1F3C3, 0x1F3C4), (0x1F3CA, 0x1F3CC), (0x1F574, 0x1F57A),
                (0x1F590, 0x1F590), (0x1F595, 0x1F596), (0x1F91A, 0x1F91F),
                (0x1F926, 0x1F926), (0x1F930, 0x1F939), (0x1F93C, 0x1F93E),
                (0x1F9B0, 0x1F9B9), (0x1F9BB, 0x1F9BB), (0x1F9CD, 0x1F9CF),
                (0x1F9D1, 0x1F9DF), (0x1FAC0, 0x1FAC5), (0x1FAF0, 0x1FAF8),
                (0x261D, 0x261D), (0x270A, 0x270D), (0x26F9, 0x26F9),
                (0x1F90C, 0x1F90C), (0x1F90F, 0x1F90F), (0x1F9BE, 0x1F9BF),
                (0x1F9E0, 0x1F9E0), (0x1F463, 0x1F465), (0x1F5E3, 0x1F5E3),
                (0x1F46A, 0x1F46D), (0x1F6C0, 0x1F6C0), (0x1F3C7, 0x1F3C7),
                (0x1F6A3, 0x1F6A3), (0x1F6B4, 0x1F6B5), (0x1F93A, 0x1F93A),
                (0x1F6CC, 0x1F6CC)]),
    ("animals", [(0x1F400, 0x1F43F), (0x1F980, 0x1F9AF), (0x1F331, 0x1F335),
                 (0x1F337, 0x1F344), (0x1F577, 0x1F578), (0x1F54A, 0x1F54A),
                 (0x1F9A0, 0x1F9A0), (0x1FAB0, 0x1FABF), (0x1F490, 0x1F490),
                 (0x1F4AE, 0x1F4AE), (0x2618, 0x2618), (0x1F33A, 0x1F33C),
                 (0x1F30D, 0x1F320), (0x1F321, 0x1F32C), (0x2600, 0x2604),
                 (0x26C4, 0x26C8), (0x2744, 0x2744), (0x2603, 0x2603),
                 (0x1F525, 0x1F525), (0x1F4A7, 0x1F4A7), (0x1F30A, 0x1F30A),
                 (0x2B50, 0x2B50), (0x2728, 0x2728), (0x1F308, 0x1F308),
                 (0x2601, 0x2601)]),
    ("food", [(0x1F345, 0x1F37F), (0x1F32D, 0x1F32F), (0x1F330, 0x1F330),
              (0x1F336, 0x1F336), (0x1F950, 0x1F96F), (0x1F9C0, 0x1F9CB),
              (0x1FAD0, 0x1FADB), (0x1F942, 0x1F944), (0x2615, 0x2615),
              (0x1F962, 0x1F962), (0x1F9C2, 0x1F9C2)]),
    ("travel", [(0x1F3D4, 0x1F3DF), (0x1F3E0, 0x1F3F0), (0x1F680, 0x1F6C5),
                (0x1F6D0, 0x1F6D7), (0x1F6DC, 0x1F6DF), (0x1F6E0, 0x1F6FC),
                (0x26E9, 0x26EA), (0x26F0, 0x26F5), (0x26FA, 0x26FA),
                (0x26FD, 0x26FD), (0x2693, 0x2693), (0x2708, 0x2708),
                (0x1F300, 0x1F30C), (0x1F30D, 0x1F310), (0x1F3A0, 0x1F3A2),
                (0x1F6A8, 0x1F6A9), (0x1F301, 0x1F303), (0x1F5FA, 0x1F5FF),
                (0x1F3EF, 0x1F3F0), (0x26F2, 0x26F3)]),
    ("activities", [(0x1F383, 0x1F393), (0x1F3A0, 0x1F3AF), (0x1F3B0, 0x1F3BC),
                    (0x1F3BD, 0x1F3CB), (0x1F3CF, 0x1F3D3), (0x1F3F8, 0x1F3F9),
                    (0x1F93A, 0x1F945), (0x1F947, 0x1F94F), (0x1F9E9, 0x1F9E9),
                    (0x1F9FF, 0x1F9FF), (0x26BD, 0x26BE), (0x26F8, 0x26F8),
                    (0x265F, 0x265F), (0x1F9F8, 0x1F9F8), (0x1FA80, 0x1FA86),
                    (0x2660, 0x2668), (0x1F004, 0x1F004), (0x1F0CF, 0x1F0CF),
                    (0x1F3AD, 0x1F3AD), (0x1F3AE, 0x1F3AF), (0x1F3B2, 0x1F3B2),
                    (0x1F3A8, 0x1F3A8), (0x1F3EA, 0x1F3EA)]),
    ("symbols", [(0xA9, 0xAE), (0x203C, 0x2049), (0x2122, 0x2139),
                 (0x2194, 0x21AA), (0x23E9, 0x23FA), (0x24C2, 0x24C2),
                 (0x25AA, 0x25FE), (0x2640, 0x2642), (0x2648, 0x2653),
                 (0x267B, 0x267F), (0x2695, 0x2695), (0x26A0, 0x26A1),
                 (0x26A7, 0x26AB), (0x26CE, 0x26CE), (0x26D4, 0x26D4),
                 (0x2705, 0x2705), (0x2714, 0x2716), (0x271D, 0x2721),
                 (0x274C, 0x274E), (0x2753, 0x2757), (0x2795, 0x2797),
                 (0x27B0, 0x27BF), (0x2934, 0x2935), (0x2B05, 0x2B07),
                 (0x2B1B, 0x2B1C), (0x2B55, 0x2B55), (0x3030, 0x3030),
                 (0x303D, 0x303D), (0x3297, 0x3299), (0x1F170, 0x1F251),
                 (0x1F7E0, 0x1F7EB), (0x1F500, 0x1F53D), (0x1F6AB, 0x1F6B3),
                 (0x1F6B7, 0x1F6B8), (0x1F6B9, 0x1F6BC), (0x1F6BE, 0x1F6BE),
                 (0x1F6C2, 0x1F6C5), (0x1F4F3, 0x1F4F6), (0x1F51E, 0x1F51F),
                 (0x1F4DB, 0x1F4DB), (0x1F4A0, 0x1F4A0), (0x1F4B1, 0x1F4B2),
                 (0x262E, 0x2638), (0x2622, 0x2623), (0x26AA, 0x26AB),
                 (0x1F7E0, 0x1F7EB)]),
    ("flags", [(0x1F3C1, 0x1F3C1), (0x1F6A9, 0x1F6A9), (0x1F38C, 0x1F38C),
               (0x1F3F3, 0x1F3F4)]),
]

# Common ZWJ sequences and keycaps; everything else can be typed or pasted.
SEQUENCES = [
    ("people", [0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466], "family: man, woman, girl, boy"),
    ("people", [0x1F9D1, 0x200D, 0x1F4BB], "technologist"),
    ("people", [0x1F9D1, 0x200D, 0x1F91D, 0x200D, 0x1F9D1], "people holding hands"),
    ("smileys", [0x1F62E, 0x200D, 0x1F4A8], "face exhaling"),
    ("smileys", [0x1F636, 0x200D, 0x1F32B, 0xFE0F], "face in clouds"),
    ("smileys", [0x2764, 0xFE0F, 0x200D, 0x1F525], "heart on fire"),
    ("smileys", [0x2764, 0xFE0F, 0x200D, 0x1FA79], "mending heart"),
    ("animals", [0x1F43B, 0x200D, 0x2744, 0xFE0F], "polar bear"),
    ("animals", [0x1F408, 0x200D, 0x2B1B], "black cat"),
    ("flags", [0x1F3F3, 0xFE0F, 0x200D, 0x1F308], "rainbow flag"),
    ("flags", [0x1F3F3, 0xFE0F, 0x200D, 0x26A7, 0xFE0F], "transgender flag"),
    ("flags", [0x1F3F4, 0x200D, 0x2620, 0xFE0F], "pirate flag"),
    ("symbols", [0x31, 0xFE0F, 0x20E3], "keycap: 1"),
    ("symbols", [0x32, 0xFE0F, 0x20E3], "keycap: 2"),
    ("symbols", [0x33, 0xFE0F, 0x20E3], "keycap: 3"),
    ("symbols", [0x23, 0xFE0F, 0x20E3], "keycap: #"),
]

ORDER = ["smileys", "people", "animals", "food", "travel", "activities",
         "objects", "symbols", "flags"]


def group_of(cp):
    for group, ranges in RULES:
        for low, high in ranges:
            if low <= cp <= high:
                return group
    if cp >= 0x1F300:
        return "objects"
    return "symbols"


def escape(codepoints):
    return "".join("\\u{%X}" % cp for cp in codepoints)


def sources():
    perl = subprocess.run(
        ["perl", "-MUnicode::UCD", "-e",
         'print "Perl $^V, Unicode ", Unicode::UCD::UnicodeVersion()'],
        check=True, capture_output=True, text=True).stdout
    tzdata = "tzdata unknown"
    zi = pathlib.Path("/usr/share/zoneinfo/tzdata.zi")
    if zi.exists():
        first = zi.read_text(encoding="utf-8").splitlines()[0]
        tzdata = "tzdata " + first.replace("# version", "").strip()
    return perl + "; " + tzdata


def main():
    out = subprocess.run(["perl", "-e", PERL], check=True, capture_output=True,
                         text=True).stdout
    groups = {name: [] for name in ORDER}
    for line in out.splitlines():
        hexcp, presentation, name = line.split("\t")
        cp = int(hexcp, 16)
        sequence = [cp] if presentation == "1" else [cp, 0xFE0F]
        groups[group_of(cp)].append((sequence, name))
    for group, sequence, name in SEQUENCES:
        groups[group].append((sequence, name))
    flags = []
    for line in ISO.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        code, name = line.split("\t")
        pair = [0x1F1E6 + ord(letter) - ord("A") for letter in code]
        flags.append((pair, "flag: " + name.lower()))
    groups["flags"].extend(sorted(flags, key=lambda item: item[1]))

    lines = [
        "// Generated by scripts/gen-emoji-data.py. Do not edit by hand.",
        "//",
        "// The emoji the reaction picker offers (W6): Unicode names are English,",
        "// and groups approximate the CLDR groups. Any other emoji can still be",
        "// typed or pasted into the picker.",
        "//",
        "// Built from: " + sources() + ".",
        "",
        "/// One emoji and its Unicode name, lower case.",
        "class EmojiEntry {",
        "  const EmojiEntry(this.emoji, this.name);",
        "",
        "  final String emoji;",
        "  final String name;",
        "}",
        "",
        "/// Picker groups, in display order.",
        "enum EmojiGroup {",
    ]
    lines += ["  %s," % name for name in ORDER]
    lines += ["}", "", "const Map<EmojiGroup, List<EmojiEntry>> emojiCatalog ="
              " <EmojiGroup, List<EmojiEntry>>{"]
    for name in ORDER:
        lines.append("  EmojiGroup.%s: <EmojiEntry>[" % name)
        for sequence, label in groups[name]:
            lines.append("    EmojiEntry('%s', '%s')," % (escape(sequence), label.replace("'", "\\'")))
        lines.append("  ],")
    lines.append("};")
    lines.append("")
    OUT.write_text("\n".join(lines))
    total = sum(len(v) for v in groups.values())
    print("wrote %s: %d emoji" % (OUT, total), file=sys.stderr)
    for name in ORDER:
        print("  %-10s %d" % (name, len(groups[name])), file=sys.stderr)


main()
