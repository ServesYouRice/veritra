import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../l10n/l10n.dart';
import 'safety_number_screen.dart';

/// L1 (D94): one banner per account whose devices hold this chat, with why
/// and what the person can do. "Check again" reads the lists again; a
/// contact's list in conflict also offers the safety number and, after a
/// warning that says how many devices it approves, trusting the list the
/// server shows now (one of the two signed versions only;
/// [AppState.prepareContactDeviceListTrust]).
class ApprovalHoldBanners extends StatelessWidget {
  const ApprovalHoldBanners({
    required this.state,
    required this.conversationId,
    required this.memberName,
    super.key,
  });

  final AppState state;
  final String conversationId;

  /// The name chats show for a member account.
  final String Function(String accountId) memberName;

  @override
  Widget build(BuildContext context) {
    final holds = state.approvalHoldAccounts(conversationId);
    if (holds.isEmpty) return const SizedBox.shrink();
    final busy = state.approvalHoldRechecking(conversationId);
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final hold in holds)
          MaterialBanner(
            key: ValueKey<String>('l1-hold-${hold.accountId}'),
            leading: Icon(
              hold.reason == ApprovalHoldReason.conflict ||
                      hold.reason == ApprovalHoldReason.unapproved
                  ? Icons.gpp_maybe_outlined
                  : Icons.devices_other_outlined,
            ),
            content: Text(_text(context, hold)),
            actions: <Widget>[
              if (hold.reason == ApprovalHoldReason.conflict && !hold.own) ...[
                if (state.safetyNumbersAvailable)
                  TextButton(
                    onPressed: () => _compare(context),
                    child: Text(l10n.chatHoldCompare),
                  ),
                TextButton(
                  onPressed: () => _trust(context, hold.accountId),
                  child: Text(l10n.chatHoldTrust),
                ),
              ] else
                TextButton(
                  onPressed: busy
                      ? null
                      : () => unawaited(
                            state.recheckApprovalHold(conversationId),
                          ),
                  child: Text(l10n.chatHoldCheckAgain),
                ),
            ],
          ),
      ],
    );
  }

  String _text(BuildContext context, ApprovalHoldAccount hold) {
    final l10n = context.l10n;
    final name = memberName(hold.accountId);
    return switch (hold.reason) {
      ApprovalHoldReason.checking => l10n.chatHoldChecking(name),
      ApprovalHoldReason.waiting => l10n.chatHoldWaiting(name),
      ApprovalHoldReason.removed =>
        hold.own ? l10n.chatHoldOwnRemoved : l10n.chatHoldRemoved(name),
      ApprovalHoldReason.unapproved =>
        hold.own ? l10n.chatHoldOwnUnapproved : l10n.chatHoldUnapproved(name),
      ApprovalHoldReason.conflict =>
        hold.own ? l10n.chatHoldOwnConflict : l10n.chatHoldConflict(name),
    };
  }

  void _compare(BuildContext context) {
    final conversation = state.conversations
        .where((item) => item.id == conversationId)
        .firstOrNull;
    if (conversation == null) return;
    unawaited(Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SafetyNumberScreen(
          state: state,
          conversation: conversation,
        ),
      ),
    ));
  }

  Future<void> _trust(BuildContext context, String accountId) async {
    final l10n = context.l10n;
    final name = memberName(accountId);
    final messenger = ScaffoldMessenger.maybeOf(context);
    void answer(String text) => messenger
      // A new answer replaces the last one rather than queueing behind it.
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
    // The branch is read and verified first, so the warning can say what
    // trusting it approves, and the confirmation pins exactly that branch.
    final plan = await state.prepareContactDeviceListTrust(accountId);
    if (plan == null) {
      answer(l10n.chatHoldTrustRefused);
      return;
    }
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.chatHoldTrustTitle(name)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(l10n.chatHoldTrustBody(name)),
              const SizedBox(height: 12),
              Text(
                l10n.chatHoldTrustNewDevices(name, plan.newDevices),
                key: const ValueKey<String>('l1-hold-trust-new-devices'),
              ),
              // The recovery key can replace every device later, so a
              // branch that changes it is said so even with no new device.
              if (plan.recoveryKeyChanges) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.chatHoldTrustRecoveryKey(name),
                  key: const ValueKey<String>('l1-hold-trust-recovery-key'),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            key: const ValueKey<String>('l1-hold-trust-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.chatHoldTrustConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final trusted = await state.trustContactDeviceList(plan);
    answer(trusted ? l10n.chatHoldTrusted(name) : l10n.chatHoldTrustRefused);
  }
}
