import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/typing_state.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';

/// "X is typing…" above the composer (W5). Shows nothing when nobody is
/// typing, and nothing in a conversation with more than [typingMaxMembers]
/// members. The line reserves no height while hidden.
class TypingLine extends StatelessWidget {
  const TypingLine({
    required this.state,
    required this.conversationId,
    super.key,
  });

  final AppState state;
  final String conversationId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[state.typing, state.receipts]),
      builder: (context, _) {
        final roster = state.membersFor(conversationId);
        final members = roster.isNotEmpty
            ? roster.length
            : state.receipts.receiptsFor(conversationId).length + 1;
        if (members > typingMaxMembers) return const SizedBox.shrink();
        final own = state.session?.accountId;
        final typers = state.typing
            .typersIn(conversationId)
            .where((id) => id != own && !state.isBlocked(id))
            .toList(growable: false);
        if (typers.isEmpty) return const SizedBox.shrink();
        String name(String id) => accountLabel(
              id,
              roster.where((m) => m.accountId == id).firstOrNull?.username,
            );
        final l10n = context.l10n;
        final text = switch (typers.length) {
          1 => l10n.chatTypingOne(name(typers[0])),
          2 => l10n.chatTypingTwo(name(typers[0]), name(typers[1])),
          _ => l10n.chatTypingMany,
        };
        return Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              BoneSpacing.gutter,
              BoneSpacing.xs,
              BoneSpacing.gutter,
              0,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
              ),
            ),
          ),
        );
      },
    );
  }
}
