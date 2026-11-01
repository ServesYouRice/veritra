import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../features/chat/chat_list_screen.dart' show conversationTitle;
import '../../features/settings/backup_screen.dart';
import '../../sync/sync_recovery.dart';
import '../format.dart';
import '../tokens.dart';
import 'listenable_selector.dart';
import '../../l10n/l10n.dart';

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
    // Rebuilds only when what it draws changes (T49C-1). Online it draws
    // nothing, so a completed sync moving [AppState.lastSyncedAt] is no
    // reason to rebuild; the recovery banner alone reads [AppState.busy].
    return ListenableSelector<
        (SyncRecovery?, ConnectionStatus, DateTime?, bool)>(
      listenable: state,
      select: () {
        final recovery = state.syncRecovery;
        final status = state.connectionStatus;
        if (recovery != null) return (recovery, status, null, state.busy);
        if (status == ConnectionStatus.online) {
          return (null, status, null, false);
        }
        return (null, status, state.lastSyncedAt, false);
      },
      builder: (context, _, __) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
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
    final l10n = context.l10n;
    final detail = <String>[
      if (offline) l10n.bannerQueued else l10n.bannerReconnecting,
      if (lastSynced != null)
        l10n.bannerLastSynced(formatDateTime(context, lastSynced)),
    ].join(' ');
    return Semantics(
      liveRegion: true,
      container: true,
      label: offline
          ? l10n.bannerOfflineSemantics(detail)
          : l10n.bannerConnectingSemantics(detail),
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
                      offline ? l10n.bannerOffline : l10n.bannerConnecting,
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
    final leaveTitle = _leaveTitle(context);
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
                      context.l10n.bannerPaused,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                leaveTitle != null &&
                        recovery.kind == SyncFailureKind.recordLimit
                    ? context.l10n.syncErrorRecordLimitNamed(leaveTitle)
                    : recovery.localizedMessage(context.l10n),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onErrorContainer),
              ),
              Wrap(
                spacing: BoneSpacing.sm,
                children: <Widget>[
                  // D70: the named conversation outgrew what this device
                  // can store; leaving it lets the others go on.
                  if (choices.contains(SyncRecoveryChoice.leaveConversation))
                    TextButton(
                      onPressed: state.busy
                          ? null
                          : () => _confirmLeave(context, leaveTitle),
                      child: Text(leaveTitle == null
                          ? context.l10n.detailsLeave
                          : context.l10n.bannerLeaveNamed(leaveTitle)),
                    ),
                  if (choices.contains(SyncRecoveryChoice.retry))
                    TextButton(
                      onPressed: state.busy ? null : state.retrySyncRecovery,
                      child: Text(context.l10n.bannerTryAgain),
                    ),
                  // A single-device account cannot relink; the backup
                  // screen holds the restore action and its confirmation.
                  if (choices.contains(SyncRecoveryChoice.restoreBackup))
                    TextButton(
                      onPressed: state.busy
                          ? null
                          : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => BackupScreen(state: state),
                                ),
                              ),
                      child: Text(context.l10n.bannerRestoreBackup),
                    ),
                  if (choices.contains(SyncRecoveryChoice.relink))
                    TextButton(
                      onPressed:
                          state.busy ? null : () => _confirmRelink(context),
                      child: Text(context.l10n.bannerRelink),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The title of the conversation the failure names, when this device
  /// lists it; null otherwise (a -8 from a Welcome, say), and the generic
  /// wording is used.
  String? _leaveTitle(BuildContext context) {
    final id = recovery.conversationId;
    if (id == null) return null;
    final conversation =
        state.conversations.where((c) => c.id == id).firstOrNull;
    return conversation == null
        ? null
        : conversationTitle(context.l10n, conversation);
  }

  Future<void> _confirmLeave(BuildContext context, String? title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title == null
            ? context.l10n.detailsLeaveTitle
            : context.l10n.bannerLeaveNamedTitle(title)),
        content: Text(context.l10n.detailsLeaveMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.detailsLeaveConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final left =
        await state.leaveConversationAfterSyncRecovery(confirmed: true);
    final error = state.errorFor(Ops.members);
    if (!left && error != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _confirmRelink(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bannerRelinkTitle),
        content: Text(context.l10n.bannerRelinkMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.bannerRelinkConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.relinkAfterSyncRecovery(confirmed: true);
    }
  }
}
