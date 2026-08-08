import 'package:flutter/material.dart';

import '../tokens.dart';

/// What a pill is saying.
///
/// [neutral] and [accent] are structural — a label, or the one rationed
/// accent moment. The other four are the semantic state palette, which is the
/// whole payoff of a direction that spends no accent hue: green can mean
/// verified because green is not the brand.
enum StatusTone { neutral, accent, verified, warning, error, info }

/// The one pill in the app.
///
/// `docs/design.md` §9 counted three hand-rolled versions of this —
/// `_StateChip` on device link, `_UnreadBadge` on the chat list and
/// `_DaySeparator` in a conversation — each a `Container` with a 999 radius
/// and its own colour logic. This replaces all of them.
///
/// **Contrast.** The four state tones fill solid and put the ground colour on
/// top, rather than tinting a neutral pill. That is not a style preference:
/// measured against `docs/design.md`, a tinted pill lands at 3.58–4.25
/// in light mode and a neutral pill with coloured text at 4.29 for verified
/// and warning — both fail AA. Solid fill measures 5.02–6.29 in light and
/// 6.88–11.11 in dark. If you restyle this widget, re-run those numbers.
class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.label,
    this.tone = StatusTone.neutral,
    this.icon,
    this.uppercase = true,
    this.semanticsLabel,
    super.key,
  });

  final String label;
  final StatusTone tone;
  final IconData? icon;

  /// The `micro` ramp step is specified uppercase and Flutter has no
  /// text-transform, so the pill does it. Pass false where the exact casing
  /// of the string is the point.
  final bool uppercase;

  /// What a screen reader announces instead of [label]. Worth setting
  /// whenever the visible text is compressed — `1d` should be heard as
  /// "disappearing after 1 day".
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    // Falls back rather than asserting: several widget tests pump a bare
    // MaterialApp with no theme, where the extension is absent.
    final states = theme.extension<VeritraStateColors>() ??
        (isDark ? VeritraStateColors.dark : VeritraStateColors.light);

    // The ground the direction is built on, in both brightnesses: what a
    // solid state fill puts its text in.
    final onState = isDark ? BoneColors.darkCanvas : Colors.white;
    final (background, foreground, border) = switch (tone) {
      StatusTone.neutral => (
          scheme.surfaceContainerHigh,
          scheme.onSurfaceVariant,
          scheme.outlineVariant,
        ),
      StatusTone.accent => (scheme.primary, scheme.onPrimary, scheme.primary),
      StatusTone.verified => (states.verified, onState, states.verified),
      StatusTone.warning => (states.warning, onState, states.warning),
      StatusTone.info => (states.info, onState, states.info),
      StatusTone.error => (scheme.error, onState, scheme.error),
    };

    return Semantics(
      label: semanticsLabel ?? label,
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: icon == null ? 8 : 6,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(BoneRadii.pill),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 12, color: foreground),
              const SizedBox(width: 4),
            ],
            Text(
              uppercase ? label.toUpperCase() : label,
              style: theme.textTheme.labelSmall?.copyWith(color: foreground),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pill's degenerate case: presence without a number.
///
/// A count of one rendered as `1` gives a single message the same weight as
/// thirty, which is what the chat list used to do.
class StatusDot extends StatelessWidget {
  const StatusDot({
    this.tone = StatusTone.accent,
    this.size = 8,
    this.semanticsLabel,
    super.key,
  });

  final StatusTone tone;
  final double size;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final states = theme.extension<VeritraStateColors>() ??
        (isDark ? VeritraStateColors.dark : VeritraStateColors.light);
    final color = switch (tone) {
      StatusTone.neutral => scheme.onSurfaceVariant,
      StatusTone.accent => scheme.primary,
      StatusTone.verified => states.verified,
      StatusTone.warning => states.warning,
      StatusTone.info => states.info,
      StatusTone.error => scheme.error,
    };
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (semanticsLabel == null) {
      return ExcludeSemantics(child: dot);
    }
    return Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: dot,
    );
  }
}
