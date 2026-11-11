import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../features/settings/k1_restore_screen.dart';
import '../../l10n/l10n.dart';
import '../tokens.dart';
import 'listenable_selector.dart';

/// The words for a history copy in [status] (K2). Shared by the banner and
/// the link screen.
String historyCopyMessage(AppLocalizations l10n, HistoryTransferStatus status) {
  return switch ((status.incoming, status.phase)) {
    (false, HistoryTransferPhase.working) => l10n.historyCopySendWorking,
    (false, HistoryTransferPhase.waiting) => l10n.historyCopySendWaiting,
    (true, HistoryTransferPhase.working) => l10n.historyCopyReceiveWorking,
    (true, HistoryTransferPhase.waiting) => l10n.historyCopyReceiveWaiting,
    (_, HistoryTransferPhase.failed) => l10n.historyCopyFailed,
    (_, HistoryTransferPhase.ended) => l10n.historyCopyEnded,
  };
}

/// One line while this device sends or receives a history copy, or after a
/// copy ended. Draws nothing when no copy is open.
class HistoryCopyBanner extends StatelessWidget {
  const HistoryCopyBanner({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableSelector<(bool?, HistoryTransferPhase?)>(
      listenable: state,
      select: () => (
        state.historyTransferStatus?.incoming,
        state.historyTransferStatus?.phase,
      ),
      builder: (context, _, __) {
        final status = state.historyTransferStatus;
        if (status == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final problem = status.phase == HistoryTransferPhase.failed ||
            status.phase == HistoryTransferPhase.ended;
        final color =
            problem ? scheme.errorContainer : scheme.surfaceContainerHighest;
        final onColor =
            problem ? scheme.onErrorContainer : scheme.onSurfaceVariant;
        return Semantics(
          liveRegion: true,
          container: true,
          child: Material(
            color: color,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: BoneSpacing.gutter,
                vertical: BoneSpacing.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    problem ? Icons.warning_amber_outlined : Icons.sync,
                    size: 18,
                    color: onColor,
                  ),
                  const SizedBox(width: BoneSpacing.md),
                  Expanded(
                    child: Text(
                      historyCopyMessage(context.l10n, status),
                      style:
                          theme.textTheme.bodySmall?.copyWith(color: onColor),
                    ),
                  ),
                  // K2: a copy from the old device that did not arrive can
                  // still come from an automatic backup (K1-4).
                  if (status.phase == HistoryTransferPhase.ended &&
                      status.incoming &&
                      state.k1RestoreSupported)
                    TextButton(
                      key: const ValueKey<String>('history-copy-restore'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => K1RestoreScreen(state: state),
                        ),
                      ),
                      child: Text(context.l10n.k1RestoreOpen),
                    ),
                  if (status.phase == HistoryTransferPhase.ended)
                    TextButton(
                      onPressed: state.dismissHistoryCopyNotice,
                      child: Text(context.l10n.passwordLeakDismiss),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
