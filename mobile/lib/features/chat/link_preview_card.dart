import 'package:flutter/material.dart';

import '../../crypto/link_preview.dart';

/// A link preview inside a message bubble (B2). It only displays what the
/// sender's app put in the encrypted message: no network access, no fetch,
/// and no tap target. The host line is the real host of the link, taken from
/// the URL, so the card text cannot hide where the link goes.
class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard({required this.preview, this.color, super.key});

  final LinkPreview preview;

  /// Text colour of the surrounding bubble.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final thumbnail = preview.thumbnail;
    final title = preview.title;
    final description = preview.description;
    return Container(
      key: const Key('link-preview-card'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (thumbnail != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  thumbnail.png,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  excludeFromSemantics: true,
                  errorBuilder: (context, error, stack) =>
                      const SizedBox(width: 56, height: 56),
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  preview.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                  ),
                ),
                if (title != null)
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (description != null)
                  Text(
                    description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: color),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
