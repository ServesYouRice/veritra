import 'package:flutter/material.dart';

import '../tokens.dart';
import '../../l10n/l10n.dart';

/// Always-visible notice for demo builds (decision D11). Demo builds run the
/// real end-to-end encryption before its independent review, so they must
/// never look like a release build.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key});

  /// The English label, for tests and logs. The banner itself reads it from
  /// the app's strings (`demoBannerLabel`), which must stay equal to this.
  static const label = 'Demo build · unreviewed encryption';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final states = theme.extension<VeritraStateColors>() ??
        (theme.brightness == Brightness.dark
            ? VeritraStateColors.dark
            : VeritraStateColors.light);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final notice = l10n.demoBannerNotice(l10n.demoBannerLabel);
    return Semantics(
      container: true,
      label: notice,
      excludeSemantics: true,
      child: Material(
        color: scheme.surfaceContainerHigh,
        child: SafeArea(
          bottom: false,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: states.warning)),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: BoneSpacing.gutter,
              vertical: BoneSpacing.xs,
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.science_outlined, size: 16, color: states.warning),
                const SizedBox(width: BoneSpacing.sm),
                Expanded(
                  child: Text(
                    notice,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
