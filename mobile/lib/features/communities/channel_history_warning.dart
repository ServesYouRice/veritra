import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// Asks an admin to confirm a change of a channel's history setting. Turning
/// full history on carries the stronger warning the owner chose
/// (2026-11-12): posts in a `full` channel are signed so that later members
/// can check them, so they can be proven to be their author's.
Future<bool> confirmChannelHistory(
  BuildContext context, {
  required bool full,
}) async {
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.channelHistoryTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          // Three short points, each one a fact C7 states: who can read
          // what (decision 9), and that posts in a full channel are signed
          // and so not deniable (owner answer 2026-11-12).
          children: <Widget>[
            for (final point in full
                ? <String>[
                    l10n.channelHistoryOnConfirm,
                    l10n.channelHistoryOnEarlier,
                    l10n.channelHistoryProofConfirm,
                  ]
                : <String>[
                    l10n.channelHistoryOffConfirm,
                    l10n.channelHistoryOffKept,
                    l10n.channelHistoryOffAgain,
                  ])
              _Point(point),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            full ? l10n.channelHistoryProofAccept : l10n.commonContinue,
          ),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// One bullet of the confirmation.
class _Point extends StatelessWidget {
  const _Point(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const ExcludeSemantics(child: Text('\u2022 ')),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
