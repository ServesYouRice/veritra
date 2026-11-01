import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../features/settings/reauth_dialog.dart';
import '../../l10n/l10n.dart';
import '../format.dart';
import '../tokens.dart';
import 'listenable_selector.dart';

/// K0 notices on a signed-in device (docs/designs/K0-recovery-enrollment.md,
/// "Notices"): a recovery of this account that is waiting, with a cancel
/// that needs the password, and D79's warning that the password appears
/// leaked. Draws nothing when neither applies.
class AccountRecoveryBanner extends StatelessWidget {
  const AccountRecoveryBanner({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    // Rebuilds only when what it draws changes (T49C-1).
    return ListenableSelector<(String?, String?, DateTime?, String?)>(
      listenable: state,
      select: () {
        final pending = state.recoveryKeyStatus?.pending;
        return (
          pending?.id,
          pending?.deviceName,
          pending?.readyAt,
          state.passwordLeakWarningDay,
        );
      },
      builder: (context, _, __) {
        final pending = state.recoveryKeyStatus?.pending;
        final leakDay = state.passwordLeakWarningDay;
        if (pending == null && leakDay == null) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (pending != null) _pendingNotice(context, pending),
            if (leakDay != null) _leakNotice(context),
          ],
        );
      },
    );
  }

  Widget _frame(BuildContext context,
      {required IconData icon,
      required String message,
      required List<Widget> actions}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        color: scheme.errorContainer,
        child: Container(
          width: double.infinity,
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(icon, size: 18, color: scheme.onErrorContainer),
                  const SizedBox(width: BoneSpacing.md),
                  Expanded(
                    child: Text(
                      message,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
              Wrap(spacing: BoneSpacing.sm, children: actions),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pendingNotice(BuildContext context, PendingRecoveryRequest pending) {
    final l10n = context.l10n;
    return _frame(
      context,
      icon: Icons.warning_amber_outlined,
      message: l10n.recoveryPendingNotice(pending.deviceName,
          formatDateTime(context, pending.readyAt.toLocal())),
      actions: <Widget>[
        TextButton(
          onPressed: state.isBusy(Ops.accountRecovery)
              ? null
              : () => _confirmCancel(context, pending),
          child: Text(l10n.recoveryPendingCancel),
        ),
      ],
    );
  }

  Widget _leakNotice(BuildContext context) {
    final l10n = context.l10n;
    return _frame(
      context,
      icon: Icons.password_outlined,
      message: l10n.passwordLeakNotice,
      actions: <Widget>[
        TextButton(
          onPressed: state.dismissPasswordLeakWarning,
          child: Text(l10n.passwordLeakDismiss),
        ),
      ],
    );
  }

  Future<void> _confirmCancel(
      BuildContext context, PendingRecoveryRequest pending) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.recoveryCancelTitle),
        content: Text(l10n.recoveryCancelMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.recoveryPendingCancel),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    var result = await state.cancelAccountRecoveryRequest(pending.id);
    if (result == RecoveryActionResult.needsRecentAuth && context.mounted) {
      if (!await confirmPasswordForRecentAuth(context, state)) return;
      result = await state.cancelAccountRecoveryRequest(pending.id);
    }
    if (!context.mounted) return;
    final message = switch (result) {
      RecoveryActionResult.done => l10n.recoveryCancelled,
      RecoveryActionResult.alreadyEnded => l10n.recoveryAlreadyEnded,
      _ => state.errorFor(Ops.accountRecovery),
    };
    if (message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
