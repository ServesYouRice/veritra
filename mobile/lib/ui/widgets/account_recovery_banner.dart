import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../features/settings/reauth_dialog.dart';
import '../../l10n/l10n.dart';
import '../format.dart';
import '../tokens.dart';
import 'listenable_selector.dart';

/// K0 notice on a signed-in device (docs/designs/K0-recovery-enrollment.md,
/// "Notices"): a recovery of this account that is waiting. It is its own
/// card (U17) and is never folded into the notice stack, because it may be an
/// attack: red, with a filled "This is not me" button that opens the same
/// cancel dialog as before, and no dismiss. Draws nothing when no recovery is
/// waiting.
class RecoveryAttemptCard extends StatelessWidget {
  const RecoveryAttemptCard({required this.state, super.key});

  final AppState state;

  static bool active(AppState state) =>
      state.recoveryKeyStatus?.pending != null;

  @override
  Widget build(BuildContext context) {
    // Rebuilds only when what it draws changes (T49C-1).
    return ListenableSelector<(String?, String?, DateTime?)>(
      listenable: state,
      select: () {
        final pending = state.recoveryKeyStatus?.pending;
        return (pending?.id, pending?.deviceName, pending?.readyAt);
      },
      builder: (context, _, __) {
        final pending = state.recoveryKeyStatus?.pending;
        if (pending == null) return const SizedBox.shrink();
        return _card(context, pending);
      },
    );
  }

  Widget _card(BuildContext context, PendingRecoveryRequest pending) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const ValueKey<String>('recovery-attempt-card'),
        width: double.infinity,
        margin: const EdgeInsets.symmetric(
          horizontal: BoneSpacing.gutter,
          vertical: BoneSpacing.sm,
        ),
        padding: const EdgeInsets.all(BoneSpacing.md),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(BoneRadii.md),
          border: Border.all(color: scheme.error),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.warning_amber_outlined,
                    size: 22, color: scheme.onErrorContainer),
                const SizedBox(width: BoneSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        l10n.recoveryPendingTitle,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.onErrorContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: BoneSpacing.xs),
                      Text(
                        l10n.recoveryPendingNotice(pending.deviceName,
                            formatDateTime(context, pending.readyAt.toLocal())),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onErrorContainer),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: BoneSpacing.md),
            // The same action as before: confirm, then cancel the recovery,
            // asking for the password when the sign-in is not recent.
            FilledButton(
              key: const ValueKey<String>('recovery-attempt-not-me'),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
                minimumSize: const Size(
                    BoneSpacing.minTapTarget, BoneSpacing.minTapTarget),
              ),
              onPressed: state.isBusy(Ops.accountRecovery)
                  ? null
                  : () => _confirmCancel(context, pending),
              child: Text(l10n.recoveryPendingNotMe),
            ),
          ],
        ),
      ),
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

/// Shared frame of the two account notices below. Both can mean someone else
/// is at the account, so they keep the error tone (U17).
Widget _accountNoticeFrame(BuildContext context,
    {required IconData icon,
    required String message,
    required List<Widget> actions}) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final foreground = scheme.onErrorContainer;
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
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: BoneSpacing.md),
                Expanded(
                  child: Text(
                    message,
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: foreground),
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

/// D79's warning that the password appears leaked. Draws nothing when there
/// is no warning.
class PasswordLeakBanner extends StatelessWidget {
  const PasswordLeakBanner({required this.state, super.key});

  final AppState state;

  static bool active(AppState state) => state.passwordLeakWarningDay != null;

  @override
  Widget build(BuildContext context) {
    return ListenableSelector<bool>(
      listenable: state,
      select: () => active(state),
      builder: (context, show, _) {
        if (!show) return const SizedBox.shrink();
        final l10n = context.l10n;
        return _accountNoticeFrame(
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
      },
    );
  }
}

/// A passkey was added to or removed from this account. Draws nothing when
/// there is no notice.
class PasskeyNoticeBanner extends StatelessWidget {
  const PasskeyNoticeBanner({required this.state, super.key});

  final AppState state;

  static bool active(AppState state) => state.passkeyNotice != null;

  @override
  Widget build(BuildContext context) {
    return ListenableSelector<PasskeyNotice?>(
      listenable: state,
      select: () => state.passkeyNotice,
      builder: (context, notice, _) {
        if (notice == null) return const SizedBox.shrink();
        final l10n = context.l10n;
        return _accountNoticeFrame(
          context,
          icon: Icons.fingerprint,
          message: notice == PasskeyNotice.added
              ? l10n.passkeyNoticeAdded
              : l10n.passkeyNoticeRemoved,
          actions: <Widget>[
            TextButton(
              onPressed: state.dismissPasskeyNotice,
              child: Text(l10n.passkeyNoticeDismiss),
            ),
          ],
        );
      },
    );
  }
}
