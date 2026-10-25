import 'package:flutter/widgets.dart';

/// The longest reaction the payload accepts, in UTF-16 code units
/// (`app_payload.dart`). Family emoji with skin tones fit with room to spare.
const int maxReactionLength = 32;

/// [input] as a reaction if it is exactly one emoji, otherwise null (W6).
///
/// Any single emoji grapheme cluster may react: one picked from the list, or
/// typed or pasted from the system keyboard (flags, skin tones and ZWJ
/// sequences count as one). Letters, digits and punctuation do not. This
/// only keeps the reaction bar tidy; the payload itself accepts any short
/// string and the wire format is unchanged.
String? asSingleEmoji(String input) {
  final text = input.trim();
  if (text.isEmpty || text.length > maxReactionLength) return null;
  if (text.characters.length != 1) return null;
  return text.runes.any(_isEmojiRune) ? text : null;
}

bool _isEmojiRune(int rune) =>
    rune == 0xA9 ||
    rune == 0xAE ||
    rune == 0x203C ||
    rune == 0x2049 ||
    rune == 0x2122 ||
    rune == 0x2139 ||
    rune == 0x20E3 ||
    rune == 0x24C2 ||
    rune == 0x3030 ||
    rune == 0x303D ||
    rune == 0x3297 ||
    rune == 0x3299 ||
    (rune >= 0x2190 && rune <= 0x21FF) ||
    (rune >= 0x2300 && rune <= 0x23FF) ||
    (rune >= 0x25A0 && rune <= 0x25FF) ||
    (rune >= 0x2600 && rune <= 0x27BF) ||
    (rune >= 0x2900 && rune <= 0x297F) ||
    (rune >= 0x2B00 && rune <= 0x2BFF) ||
    (rune >= 0x1F000 && rune <= 0x1FAFF);
