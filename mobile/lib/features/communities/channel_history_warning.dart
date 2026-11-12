import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// Asks an admin to confirm a change of a channel's history setting. Turning
/// full history on carries the stronger warning the owner chose
/// (2026-11-12): posts in a `full` channel are signed so that later members
/// can check them, so they can be proven to be their author's.
Future<bool> confirmChannelHistory(BuildContext context,
    {required bool full}) async {
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.channelHistoryTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: full
              ? [
                  Text(l10n.channelHistoryOnConfirm),
                  const SizedBox(height: 12),
                  Text(l10n.channelHistoryProofConfirm),
                ]
              : [Text(l10n.channelHistoryOffConfirm)],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child:
              Text(full ? l10n.channelHistoryProofAccept : l10n.commonContinue),
        ),
      ],
    ),
  );
  return confirmed == true;
}
