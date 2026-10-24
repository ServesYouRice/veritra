import 'package:flutter/material.dart';

import '../../core/receipts_state.dart';
import '../../l10n/l10n.dart';

/// The "Read receipts" switch (W5). It belongs to the account, so every
/// linked device follows it. Off: no read receipt is shared (the server keeps
/// a private cursor for the unread count only) and none of other people's
/// read state is shown either.
class ReadReceiptsTile extends StatelessWidget {
  const ReadReceiptsTile({
    required this.preferences,
    required this.onChanged,
    super.key,
  });

  final ReceiptPreferences preferences;

  /// Tells the server; false when it could not be told.
  final Future<bool> Function(bool enabled) onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => SwitchListTile(
        secondary: const Icon(Icons.done_all),
        title: Text(l10n.settingsReadReceiptsTitle),
        subtitle: Text(l10n.settingsReadReceiptsDetail),
        value: preferences.sendReadReceipts,
        onChanged: (value) async {
          final messenger = ScaffoldMessenger.maybeOf(context);
          if (!await onChanged(value)) {
            messenger?.showSnackBar(
              SnackBar(content: Text(l10n.settingsReadReceiptsFailed)),
            );
          }
        },
      ),
    );
  }
}
