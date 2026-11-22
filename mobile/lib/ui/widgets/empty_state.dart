import 'package:flutter/material.dart';

import '../tokens.dart';
import 'veritra_mark.dart';

/// Shared empty state with a brand mark above an icon and heading.
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
              VeritraMark(
                size: 96,
                color: scheme.onSurface.withValues(alpha: 0.13),
                strokeWidth: 20,
              ),
              const SizedBox(height: BoneSpacing.lg),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ExcludeSemantics(
                    child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: BoneSpacing.sm),
                  Flexible(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
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
