import 'package:flutter/material.dart';

/// Design tokens for the **K2 · Bone** direction.
///
/// Bone spends no accent hue. In dark mode a warm near-white carries every
/// accent slot over a plum ground; in light mode that inverts, so the paper
/// becomes warm and the accent becomes deep plum. The ground is therefore the
/// whole identity, which leaves the colour wheel free for meaning — see
/// [VeritraStateColors].
///
/// Palettes and their measured contrast ratios live in
/// `design/directions.md`. Every pair here was checked against WCAG 2.1 AA
/// before being written down; re-run that check if any value changes.
class BoneColors {
  const BoneColors._();

  // --- Dark: plum ground, bone accent -------------------------------------
  static const Color darkCanvas = Color(0xff16111f);
  static const Color darkSurface = Color(0xff211a2d);
  static const Color darkRaised = Color(0xff2b233a);
  static const Color darkText = Color(0xfff3effa);
  static const Color darkMuted = Color(0xffa89ea6);
  static const Color darkOutline = Color(0xff6f6675);
  static const Color darkAccent = Color(0xffede4da);
  static const Color darkOnAccent = Color(0xff1e1620);

  /// 9% white. Hairlines carry separation because this direction uses tone
  /// rather than shadow.
  static const Color darkBorder = Color(0x17ffffff);

  // --- Light: warm paper, deep plum accent --------------------------------
  static const Color lightCanvas = Color(0xfff8f6f1);
  static const Color lightSurface = Color(0xffffffff);
  static const Color lightRaised = Color(0xfff0ede6);
  static const Color lightText = Color(0xff1a1620);
  static const Color lightMuted = Color(0xff6b6169);
  static const Color lightOutline = Color(0xff8a808a);
  static const Color lightAccent = Color(0xff3a2e42);
  static const Color lightOnAccent = Color(0xffffffff);

  /// 11% of [lightText].
  static const Color lightBorder = Color(0x1c1a1620);

  // --- Error, as a Material role ------------------------------------------
  static const Color darkError = Color(0xfffb7185);
  static const Color darkOnError = Color(0xff2a0a11);
  static const Color darkErrorContainer = Color(0xff4a1220);
  static const Color darkOnErrorContainer = Color(0xffffd9df);
  static const Color lightError = Color(0xffbe123c);
  static const Color lightOnError = Color(0xffffffff);
  static const Color lightErrorContainer = Color(0xffffe4e9);
  static const Color lightOnErrorContainer = Color(0xff5c0620);
}

/// Corner radii. 12 and 20 are the direction's two structural radii; 10 and 18
/// exist for controls and bubbles respectively.
class BoneRadii {
  const BoneRadii._();

  static const double sm = 10;
  static const double md = 12;
  static const double lg = 20;
  static const double bubble = 18;

  /// Pills — status chips, unread counts, the floating nav.
  static const double pill = 999;
}

/// Spacing scale. [gutter] is the screen-edge inset every screen shares.
class BoneSpacing {
  const BoneSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double gutter = 16;

  /// Rows are 62dp tall in this direction. The tap target still has to reach
  /// 48dp on its own, which it does comfortably at this height.
  static const double rowHeight = 62;
  static const double minTapTarget = 48;
}

/// Motion. The direction is restrained, so there is one standard duration and
/// one standard curve; callers must still respect
/// `MediaQuery.disableAnimationsOf`.
class BoneDurations {
  const BoneDurations._();

  static const Duration standard = Duration(milliseconds: 180);
  static const Duration short = Duration(milliseconds: 120);
  static const Curve curve = Curves.easeOutCubic;
}

/// The type ramp from `design/redesign.md` §1.
///
/// Sizes and weights are that table's; tracking is converted from `em` to the
/// logical pixels Flutter's `letterSpacing` expects, so -0.03em at 27px is
/// -0.81. The one deviation is `title`, specified at weight 650 — a value
/// [FontWeight] cannot express — which is rounded to [FontWeight.w600].
///
/// No font is bundled. The platform faces (SF on iOS, Roboto on Android) carry
/// the ramp, which is where nearly all of the improvement comes from; adding a
/// typeface would also require a `THIRD_PARTY_NOTICES.md` entry.
class BoneType {
  const BoneType._();

  static const TextStyle display = TextStyle(
    fontSize: 27,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.81,
    height: 1.15,
  );

  static const TextStyle title = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.34,
    height: 1.3,
  );

  static const TextStyle body = TextStyle(
    fontSize: 14.5,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.15,
    height: 1.45,
  );

  static const TextStyle label = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w400,
    height: 1.35,
  );

  /// Group headers, field labels and chips. Callers must uppercase the string
  /// themselves — Flutter has no text-transform.
  static const TextStyle micro = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.1,
    height: 1.2,
  );

  /// Account IDs, invite codes, fingerprints. Not a [TextTheme] slot, so read
  /// it from here directly.
  static const TextStyle mono = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    fontFamily: 'monospace',
    fontFamilyFallback: <String>['Menlo', 'Consolas', 'Roboto Mono'],
  );
}

/// Semantic state colours.
///
/// This is what spending no accent hue buys: green can mean verified and amber
/// can mean warning without either colliding with a brand colour. Error is
/// deliberately absent — it is already a Material role, so read it from
/// `Theme.of(context).colorScheme.error` and keep one source of truth.
///
/// The light values clear AA by a small margin (4.56 and 4.57), so do not
/// render them below body size or on a lighter ground than
/// [BoneColors.lightCanvas].
@immutable
class VeritraStateColors extends ThemeExtension<VeritraStateColors> {
  const VeritraStateColors({
    required this.verified,
    required this.warning,
    required this.info,
  });

  /// Safety number matches; device authorised.
  final Color verified;

  /// Key expiring; action needed but nothing has failed yet.
  final Color warning;

  /// Neutral progress — syncing, connecting.
  final Color info;

  static const VeritraStateColors dark = VeritraStateColors(
    verified: Color(0xff4ade80),
    warning: Color(0xfffbbf24),
    info: Color(0xff7dd3fc),
  );

  static const VeritraStateColors light = VeritraStateColors(
    verified: Color(0xff15803d),
    warning: Color(0xffb45309),
    info: Color(0xff0369a1),
  );

  @override
  VeritraStateColors copyWith({
    Color? verified,
    Color? warning,
    Color? info,
  }) {
    return VeritraStateColors(
      verified: verified ?? this.verified,
      warning: warning ?? this.warning,
      info: info ?? this.info,
    );
  }

  @override
  VeritraStateColors lerp(
    ThemeExtension<VeritraStateColors>? other,
    double t,
  ) {
    if (other is! VeritraStateColors) {
      return this;
    }
    return VeritraStateColors(
      verified: Color.lerp(verified, other.verified, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
    );
  }
}
