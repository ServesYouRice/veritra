import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/receipts_state.dart';
import '../../l10n/l10n.dart';

/// Builds [builder] with the tick of one message you sent (W5), and again
/// whenever a delivery or read cursor, or your own read-receipts switch,
/// changes. The tick is null when [enabled] is false (a message from someone
/// else, or one that was deleted).
class MessageTickBuilder extends StatelessWidget {
  const MessageTickBuilder({
    required this.state,
    required this.conversationId,
    required this.createdAt,
    required this.enabled,
    required this.builder,
    super.key,
  });

  final AppState state;
  final String conversationId;
  final DateTime createdAt;
  final bool enabled;
  final Widget Function(BuildContext context, MessageTick? tick) builder;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return builder(context, null);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        state.receipts,
        state.receiptPreferences,
      ]),
      builder: (context, _) => builder(
        context,
        state.receipts.tickFor(
          conversationId,
          createdAt,
          // With your own receipts off you see delivery only, never read.
          // Until the stored choice is known it may be off, so the same.
          showRead: state.receiptPreferences.shareReadReceipts,
        ),
      ),
    );
  }
}

/// The spoken name of a tick, for the bubble's semantics label.
String messageTickLabel(AppLocalizations l10n, MessageTick tick) =>
    switch (tick) {
      MessageTick.sent => l10n.chatTickSent,
      MessageTick.delivered => l10n.chatTickDelivered,
      MessageTick.read => l10n.chatTickRead,
    };

/// The glyph of a tick. The three states differ by shape, not only by tone
/// (U29): one check for sent, two for delivered, an eye for read, so none
/// depends on telling two colours apart.
IconData messageTickGlyph(MessageTick tick) => switch (tick) {
      MessageTick.sent => Icons.done,
      MessageTick.delivered => Icons.done_all,
      MessageTick.read => Icons.visibility,
    };

/// The tick of one message: a check, two checks, or an eye. Read is also in
/// the accent (bone on plum, plum on paper), so it stands out by tone as well
/// (`docs/design.md` §K). The bubble speaks the state in its semantics label,
/// so the glyph itself is excluded.
class MessageTickIcon extends StatelessWidget {
  const MessageTickIcon({required this.tick, super.key});

  final MessageTick tick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Icon(
        messageTickGlyph(tick),
        size: 14,
        color:
            tick == MessageTick.read ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }
}
