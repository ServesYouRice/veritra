import 'package:flutter/material.dart';

import '../../core/link_preview_service.dart';
import '../../l10n/l10n.dart';

String linkPreviewModeLabel(AppLocalizations l10n, LinkPreviewMode mode) {
  return switch (mode) {
    LinkPreviewMode.off => l10n.b2LinkPreviewsOff,
    LinkPreviewMode.allowListed => l10n.b2LinkPreviewsKnown,
    LinkPreviewMode.anySite => l10n.b2LinkPreviewsAll,
  };
}

/// The "Link previews" choice (B2). It is a setting of this device: only
/// the sender's app fetches a link, and only for a message it sends.
class LinkPreviewTile extends StatelessWidget {
  const LinkPreviewTile({
    required this.mode,
    required this.onChanged,
    super.key,
  });

  final LinkPreviewMode mode;
  final ValueChanged<LinkPreviewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      leading: const Icon(Icons.link),
      title: Text(l10n.b2LinkPreviews),
      subtitle: Text(l10n.b2LinkPreviewsDetail),
      trailing: PopupMenuButton<LinkPreviewMode>(
        key: const Key('link-preview-mode'),
        initialValue: mode,
        onSelected: onChanged,
        itemBuilder: (context) => <PopupMenuEntry<LinkPreviewMode>>[
          for (final option in LinkPreviewMode.values)
            PopupMenuItem<LinkPreviewMode>(
              value: option,
              child: Text(linkPreviewModeLabel(l10n, option)),
            ),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(linkPreviewModeLabel(l10n, mode)),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}
