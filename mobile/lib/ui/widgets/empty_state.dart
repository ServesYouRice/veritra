import 'package:flutter/material.dart';

import '../tokens.dart';
import 'veritra_mark.dart';

/// Shared empty/placeholder state: mark, title, supporting copy, and an
/// optional call to action.
///
/// The interior changed with `docs/design.md` §7: the filled
/// `CircleAvatar` became the concept-06 chain-link mark as low-opacity line
/// art, with the screen's own icon kept as a small glyph over it. An empty
/// screen is one of the few places the brand gets to appear at all in a
/// direction this restrained, and a tinted circle was spending the space on
/// nothing.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(BoneSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ExcludeSemantics(
                child: SizedBox.square(
                  dimension: 96,
                  child: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      VeritraMark(
                        size: 96,
                        color: scheme.onSurface.withValues(alpha: 0.13),
                        // Thinner than the brand stroke: at 13% opacity the
                        // full-weight mark reads as a smudge rather than as
                        // line art.
                        strokeWidth: 20,
                      ),
                      Icon(
                        icon,
                        size: 26,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: BoneSpacing.lg),
              Text(
                title,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: BoneSpacing.sm),
              Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              if (action != null) ...<Widget>[
                const SizedBox(height: BoneSpacing.xl),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
