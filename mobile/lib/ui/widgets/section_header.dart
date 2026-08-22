import 'package:flutter/material.dart';

import '../tokens.dart';

/// The one section header in the app.
///
/// `docs/design.md` §9 found this pattern written twice — `_SectionHeader`
/// in settings and `_Header` in conversation details — with different type and
/// different colour, which is why grouped screens never quite matched.
///
/// It renders the `micro` step of the ramp: 11/700 with wide tracking, in the
/// muted colour, uppercased here because Flutter has no text-transform. That
/// is what makes a group header read as designed rather than as a leftover
/// `Text`. `Semantics(header: true)` is preserved from both originals, so a
/// screen reader can still jump between sections.
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.title, {
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      BoneSpacing.xs,
      BoneSpacing.lg,
      BoneSpacing.xs,
      BoneSpacing.sm,
    ),
    super.key,
  });

  final String title;

  /// An action aligned to the end of the header row — "Add", "See all".
  /// Excluded from the header semantics so it stays its own tappable node.
  final Widget? trailing;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
