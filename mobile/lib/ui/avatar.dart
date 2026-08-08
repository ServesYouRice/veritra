import 'package:flutter/material.dart';

/// Deterministic avatar tinting for **K2 · Bone**.
///
/// `docs/design.md` §3 asks for avatars tinted from a hash of the account
/// ID, so a list has visual anchors instead of one repeated container colour.
/// It describes that for the coloured directions, where the tint can come off
/// a hue wheel. Bone cannot do that: it spends **no** accent hue precisely so
/// that green, amber, red and blue stay free to mean verified, warning, error
/// and info (`docs/design.md` §K, and `VeritraStateColors`). A rainbow
/// of avatars would spend all four.
///
/// So the tint varies across the five bone *temperatures* that direction
/// already defines — Chalk, Bone, Greige, Ash, Steel — rather than across
/// hues. Side by side they read as five distinct materials; none of them
/// reads as a state colour.
///
/// The bucket is computed locally from the seed. No server data is involved,
/// and the colour leaks nothing about the seed beyond one of five buckets
/// over the whole ID space.
@immutable
class BoneTint {
  const BoneTint({
    required this.name,
    required this.dark,
    required this.light,
  });

  /// The temperature's name in `docs/design.md` §K. Carried so the
  /// table there and this list can be diffed by eye.
  final String name;

  /// Near-white, for the plum ground.
  final Color dark;

  /// Deep tone of the same temperature, for warm paper.
  final Color light;

  Color resolve(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// The five temperatures, in the order `docs/design.md` §K lists them.
/// Reordering this list re-colours every existing avatar, so don't.
const List<BoneTint> boneTints = <BoneTint>[
  BoneTint(name: 'Chalk', dark: Color(0xfff4f4f6), light: Color(0xff332f3a)),
  BoneTint(name: 'Bone', dark: Color(0xffede4da), light: Color(0xff3a2e42)),
  BoneTint(name: 'Greige', dark: Color(0xffdcd3c6), light: Color(0xff403528)),
  BoneTint(name: 'Ash', dark: Color(0xffe4ddea), light: Color(0xff372c43)),
  BoneTint(name: 'Steel', dark: Color(0xffd8e0e8), light: Color(0xff2c333b)),
];

BoneTint boneTintFor(String seed) =>
    boneTints[_bucketOf(seed, boneTints.length)];

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
/// The fill is the tint at low alpha rather than solid: a column of solid
/// near-white circles would blow out the plum ground the direction is built
/// on — the same argument that keeps Bone's sent bubbles on tone. The glyph
/// carries the tint at full strength, which is both where the temperature
/// difference is actually legible and where the contrast is (≈14:1 for
/// initials on the resulting fill, in both brightnesses).
AvatarColors avatarColorsFor(BuildContext context, String seed) {
  final brightness = Theme.of(context).brightness;
  final isDark = brightness == Brightness.dark;
  final tint = boneTintFor(seed).resolve(brightness);
  return AvatarColors(
    fill: tint.withValues(alpha: isDark ? 0.18 : 0.12),
    ring: tint.withValues(alpha: isDark ? 0.32 : 0.24),
    glyph: tint,
  );
}
