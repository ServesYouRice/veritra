import 'package:flutter/material.dart';

/// Deterministic avatar colours for **K2 · Bone**.
///
/// `docs/design.md` §3 asks for avatars tinted from a hash of the account
/// ID, so a list has visual anchors instead of one repeated container colour.
/// Bone spends **no** accent hue so that green, amber, red and blue stay free
/// to mean verified, warning, error and info (`docs/design.md` §K, and
/// `VeritraStateColors`). The avatar palette therefore sits in the gaps
/// between those state colours: six hues, computed rather than picked, with
/// the evidence in `testing/evidence/UI-audit-2026-11-14.md` (D131, U39).
///
/// The colour is a hint, never an identity: a look-alike account matches one
/// time in six. A photo replaces it, and the initials always show on it.
///
/// The bucket is computed locally from the seed. No server data is involved,
/// and the colour leaks nothing about the seed beyond one of six buckets
/// over the whole ID space.
@immutable
class AvatarHue {
  const AvatarHue({
    required this.name,
    required this.darkFill,
    required this.darkInitials,
    required this.lightFill,
    required this.lightInitials,
  });

  /// The slot's name in the evidence file, so the table there and this list
  /// can be diffed by eye.
  final String name;

  final Color darkFill;
  final Color darkInitials;
  final Color lightFill;
  final Color lightInitials;

  Color fillFor(Brightness brightness) =>
      brightness == Brightness.dark ? darkFill : lightFill;

  Color initialsFor(Brightness brightness) =>
      brightness == Brightness.dark ? darkInitials : lightInitials;
}

const Color _onLight = Color(0xff16111f);
const Color _onDark = Color(0xffffffff);

/// The six hues, in the order of the evidence table. Reordering this list, or
/// changing its length, re-colours every existing avatar, so don't.
const List<AvatarHue> avatarHues = <AvatarHue>[
  AvatarHue(
    name: 'Olive',
    darkFill: Color(0xff8d9d0a),
    darkInitials: _onLight,
    lightFill: Color(0xff90a013),
    lightInitials: _onLight,
  ),
  AvatarHue(
    name: 'Teal',
    darkFill: Color(0xff0e9a94),
    darkInitials: _onLight,
    lightFill: Color(0xff16aba4),
    lightInitials: _onLight,
  ),
  AvatarHue(
    name: 'Iris',
    darkFill: Color(0xff465dbb),
    darkInitials: _onDark,
    lightFill: Color(0xff8ca6fb),
    lightInitials: _onLight,
  ),
  AvatarHue(
    name: 'Lilac',
    darkFill: Color(0xffa878db),
    darkInitials: _onLight,
    lightFill: Color(0xff9868ca),
    lightInitials: _onLight,
  ),
  AvatarHue(
    name: 'Plum',
    darkFill: Color(0xff94457d),
    darkInitials: _onDark,
    lightFill: Color(0xffe882c8),
    lightInitials: _onLight,
  ),
  AvatarHue(
    name: 'Ochre',
    darkFill: Color(0xffa35e16),
    darkInitials: _onDark,
    lightFill: Color(0xffe2a16b),
    lightInitials: _onLight,
  ),
];

AvatarHue avatarHueFor(String seed) =>
    avatarHues[_bucketOf(seed, avatarHues.length)];

/// FNV-1a, 32-bit.
///
/// Deliberately not `String.hashCode`: Dart seeds string hashing per process,
/// so a contact would change colour between launches. This is stable forever.
int _bucketOf(String seed, int count) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < seed.length; i++) {
    hash ^= seed.codeUnitAt(i) & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash % count;
}

/// Initials of a group's or channel's name for its avatar: the first letter
/// or digit of up to two words, upper-cased. Null when the name has none, so
/// the caller falls back to the kind icon rather than a misleading mark.
String? nameInitials(String? name) {
  if (name == null) return null;
  final words = name
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((word) => word.isNotEmpty);
  final letters = <String>[
    for (final word in words.take(2)) word.characters.first.toUpperCase(),
  ];
  return letters.isEmpty ? null : letters.join();
}

/// The three colours an avatar needs, resolved for one seed and the ambient
/// brightness.
@immutable
class AvatarColors {
  const AvatarColors({
    required this.fill,
    required this.ring,
    required this.glyph,
  });

  final Color fill;
  final Color ring;
  final Color glyph;
}

/// Avatar colours for [seed].
///
/// The fill is solid and the glyph (the initials) is the colour the evidence
/// file lists for that fill, at 4.5:1 or better in both themes. The ring is
/// the fill itself: the callers draw one, and a second tone would only blur
/// the edge.
AvatarColors avatarColorsFor(BuildContext context, String seed) {
  final brightness = Theme.of(context).brightness;
  final hue = avatarHueFor(seed);
  final fill = hue.fillFor(brightness);
  return AvatarColors(
    fill: fill,
    ring: fill,
    glyph: hue.initialsFor(brightness),
  );
}
