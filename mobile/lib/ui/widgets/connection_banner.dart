import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../format.dart';

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
    if (state.connectionStatus == ConnectionStatus.online) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final offline = state.connectionStatus == ConnectionStatus.offline;
    final scheme = theme.colorScheme;
    final background =
        offline ? scheme.errorContainer : scheme.surfaceContainerHighest;
    final foreground =
        offline ? scheme.onErrorContainer : scheme.onSurfaceVariant;
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: <Widget>[
              if (offline)
                Icon(Icons.cloud_off_outlined, size: 18, color: foreground)
              else
                SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: foreground,
                  ),
                ),
              const SizedBox(width: 12),
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
