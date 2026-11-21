import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../l10n/l10n.dart';
import '../tokens.dart';
import 'listenable_selector.dart';

/// C1 (owner decision 2026-11-21): a join request waits for this account as
/// an owner or admin. It says only "New join request": the event that raises
/// it names no one and no group or community, and the request list on the
/// group's or community's page says the rest. Draws nothing otherwise.
class JoinRequestNoticeBanner extends StatelessWidget {
  const JoinRequestNoticeBanner({required this.state, super.key});

  final AppState state;

  static bool active(AppState state) => state.joinRequestNotice;

  @override
  Widget build(BuildContext context) {
    return ListenableSelector<bool>(
      listenable: state,
      select: () => state.joinRequestNotice,
      builder: (context, show, _) {
        if (!show) return const SizedBox.shrink();
        final l10n = context.l10n;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        return Material(
          key: const ValueKey<String>('join-request-notice'),
          color: scheme.secondaryContainer,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: BoneSpacing.gutter,
              vertical: BoneSpacing.sm,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.person_add_alt_outlined,
                  size: 18,
                  color: scheme.onSecondaryContainer,
                ),
                const SizedBox(width: BoneSpacing.md),
                Expanded(
                  child: Text(
                    l10n.joinRequestNoticeText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey<String>('join-request-notice-dismiss'),
                  onPressed: state.dismissJoinRequestNotice,
                  child: Text(l10n.joinRequestNoticeDismiss),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
