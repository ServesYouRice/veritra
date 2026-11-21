import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../l10n/l10n.dart';
import 'safety_number_screen.dart';

/// L1 (D94): one banner per account whose devices hold this chat, with why
/// and what the person can do. "Check again" reads the lists again; a
/// contact's list in conflict also offers the safety number and, after a
/// warning, trusting the list the server shows now (one of the two signed
/// versions only; [AppState.trustContactDeviceList]).
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.chatHoldTrustTitle(name)),
        content: Text(l10n.chatHoldTrustBody(name)),
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
    final trusted = await state.trustContactDeviceList(accountId);
    messenger?.showSnackBar(SnackBar(
      content: Text(
        trusted ? l10n.chatHoldTrusted(name) : l10n.chatHoldTrustRefused,
      ),
    ));
  }
}
