import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../l10n/l10n.dart';
import '../../ui/confirm.dart';

/// Blocks or unblocks [accountId] with the same words everywhere (U16).
///
/// Blocking asks first and says what the block does. Both directions end in
/// a snackbar with "Undo", which applies the opposite change. Returns true
/// when the change was made.
Future<bool> toggleBlock(
  BuildContext context,
  AppState state, {
  required String accountId,
  required String label,
  required bool blocked,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  if (!blocked) {
    final confirmed = await confirmAction(
      context,
      title: l10n.searchBlockAccount(label),
      message: l10n.detailsBlockDetail,
      confirmLabel: l10n.searchBlockConfirm,
      destructive: true,
    );
    if (!confirmed || !context.mounted) return false;
  }
  final ok = blocked
      ? await state.unblockAccount(accountId)
      : await state.blockAccount(accountId);
  if (!context.mounted) return ok;
  messenger.showSnackBar(
    SnackBar(
      content: Text(ok
          ? (blocked ? l10n.blockedUnblocked(label) : l10n.searchBlocked(label))
          : state.errorFor(Ops.blocks) ??
              (blocked
                  ? l10n.blockedUnblockFailed(label)
                  : l10n.searchBlockFailed)),
      action: ok
          ? SnackBarAction(
              label: l10n.commonUndo,
              onPressed: () {
                if (blocked) {
                  state.blockAccount(accountId);
                } else {
                  state.unblockAccount(accountId);
                }
              },
            )
          : null,
    ),
  );
  return ok;
}
