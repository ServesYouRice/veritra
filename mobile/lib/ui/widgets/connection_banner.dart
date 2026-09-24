import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../sync/sync_recovery.dart';
import '../format.dart';
import '../tokens.dart';

/// Compact, persistent connection state for the app shell.
///
/// It reports only what the app has observed: a completed sync means online,
/// a failed one means offline. It never claims delivery state for individual
/// messages — queued envelopes report that themselves in the chat view.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final recovery = state.syncRecovery;
    if (recovery != null) {
      return _SyncRecoveryBanner(state: state, recovery: recovery);
    }
    if (state.connectionStatus == ConnectionStatus.online) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final offline = state.connectionStatus == ConnectionStatus.offline;
    final scheme = theme.colorScheme;
    final states = theme.extension<VeritraStateColors>() ??
        (theme.brightness == Brightness.dark
            ? VeritraStateColors.dark
            : VeritraStateColors.light);
    // Offline is a failure and keeps the error container. Connecting is not a
    // failure — it gets the info tone rather than a grey that reads as
    // "nothing is happening".
    final background =
        offline ? scheme.errorContainer : scheme.surfaceContainerHigh;
    final foreground = offline ? scheme.onErrorContainer : scheme.onSurface;
    final accent = offline ? scheme.onErrorContainer : states.info;
    final lastSynced = state.lastSyncedAt;
    final detail = <String>[
      if (offline)
        'Messages you send stay queued on this device.'
      else
        'Reconnecting to the server…',
      if (lastSynced != null)
        'Last synced ${formatDateTime(context, lastSynced)}.',
    ].join(' ');
    return Semantics(
      liveRegion: true,
      container: true,
      label: offline ? 'Offline. $detail' : 'Connecting to the server. $detail',
      excludeSemantics: true,
      child: Material(
        color: background,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: BoneSpacing.gutter,
            vertical: BoneSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              if (offline)
                Icon(Icons.cloud_off_outlined, size: 18, color: accent)
              else
                SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: accent,
                  ),
                ),
              const SizedBox(width: BoneSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      offline ? 'Offline' : 'Connecting…',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: foreground,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown while sync is stopped at an event it must not skip (I33). It offers
/// only the recovery choices the failure allows; relinking deletes local data
/// and asks for confirmation first.
class _SyncRecoveryBanner extends StatelessWidget {
  const _SyncRecoveryBanner({required this.state, required this.recovery});

  final AppState state;
  final SyncRecovery recovery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final choices = recovery.choices;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        color: scheme.errorContainer,
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: BoneSpacing.gutter,
            vertical: BoneSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.sync_problem_outlined,
                      size: 18, color: scheme.onErrorContainer),
                  const SizedBox(width: BoneSpacing.md),
                  Expanded(
                    child: Text(
                      'Messages paused',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                recovery.message,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onErrorContainer),
              ),
              Wrap(
                spacing: BoneSpacing.sm,
                children: <Widget>[
                  if (choices.contains(SyncRecoveryChoice.retry))
                    TextButton(
                      onPressed: state.busy ? null : state.retrySyncRecovery,
                      child: const Text('Try again'),
                    ),
                  if (choices.contains(SyncRecoveryChoice.relink))
                    TextButton(
                      onPressed:
                          state.busy ? null : () => _confirmRelink(context),
                      child: const Text('Link this device again'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRelink(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Link this device again?'),
        content: const Text(
          'This signs this device out and deletes its messages and '
          'encryption keys. Link it again from another device afterwards. '
          'Messages that are only on this device cannot be recovered.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete and sign out'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.relinkAfterSyncRecovery(confirmed: true);
    }
  }
}
