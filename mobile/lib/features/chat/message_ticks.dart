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
          showRead: state.receiptPreferences.sendReadReceipts,
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

/// One tick for sent, two for delivered, two in the accent for read. The
/// accent is the theme's own (bone on plum, plum on paper), so read stands
/// out by tone rather than by a new hue (`docs/design.md` §K). The bubble
/// speaks the state in its semantics label, so the glyph itself is excluded.
class MessageTickIcon extends StatelessWidget {
  const MessageTickIcon({required this.tick, super.key});

  final MessageTick tick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Icon(
        tick == MessageTick.sent ? Icons.done : Icons.done_all,
        size: 14,
        color:
            tick == MessageTick.read ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }
}
