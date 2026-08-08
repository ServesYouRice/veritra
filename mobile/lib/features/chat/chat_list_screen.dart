import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/avatar.dart';
import '../../ui/format.dart';
import '../../ui/motion.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/status_pill.dart';
import '../search/search_screen.dart';
import 'chat_screen.dart';
import 'new_conversation_sheet.dart';

class ChatListScreen extends StatelessWidget {
  const ChatListScreen({required this.state, this.embedded = false, super.key});

  final AppState state;

  /// When embedded in the wide-layout workspace the list is one pane of a
  /// master-detail view: tapping a row updates the detail pane instead of
  /// pushing a full-screen route.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final conversations = state.conversations;
    return Scaffold(
      appBar: AppBar(
        // A display-sized title is most of what stops the screen reading as
        // stock Material (`docs/design.md` §8). The bar stays fixed rather
        // than collapsing on scroll — a collapsing sliver would also have to
        // carry the RefreshIndicator, which is more machinery than the effect
        // is worth here.
        toolbarHeight: 64,
        titleSpacing: BoneSpacing.gutter,
        title: Text('Chats', style: theme.textTheme.displaySmall),
        actions: <Widget>[
          IconButton(
            tooltip: 'Search',
            onPressed: () => Navigator.of(context).push(
              sharedAxisRoute<void>(
                (_) => SearchScreen(state: state),
              ),
            ),
            icon: const Icon(Icons.search),
          ),
          const SizedBox(width: BoneSpacing.sm),
        ],
      ),
      // The one accent moment on this screen. Bone rations its accent to the
      // primary action, active nav, unread count and focus ring; everything
      // else separates by tone.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showNewConversationSheet(context, state),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: theme.colorScheme.onPrimary,
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('New chat'),
      ),
      body: RefreshIndicator(
        onRefresh: state.refreshConversations,
        child: conversations.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  const SizedBox(height: 120),
                  // An empty list can mean "still loading"; showing the empty
                  // state too early reads as "your data is gone".
                  if (!state.conversationsLoaded)
                    const Center(child: CircularProgressIndicator())
                  else
                    const EmptyState(
                      icon: Icons.chat_bubble_outline,
                      title: 'No conversations yet',
                      message: 'Start a direct message or create a group. '
                          'Everything is end-to-end encrypted.',
                    ),
                ],
              )
            // No separators: rows are held apart by spacing and the active row
            // by a tinted ground, which is what removes the most recognisably
            // default surface in the app (`docs/design.md` §3).
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  BoneSpacing.sm,
                  BoneSpacing.sm,
                  BoneSpacing.sm,
                  96,
                ),
                itemCount: conversations.length,
                itemBuilder: (context, index) {
                  final conversation = conversations[index];
                  return _ConversationTile(
                    conversation: conversation,
                    muted: state.isMuted(conversation.id),
                    selected: embedded &&
                        state.selectedConversationId == conversation.id,
                    // The hero flight only exists on the pushed layout. In
                    // the embedded workspace this row and the open
                    // conversation share a route, and two widgets with one
                    // hero tag is an assertion, not a nicer animation.
                    hero: !embedded,
                    onTap: () {
                      state.selectAndPrepare(conversation.id);
                      if (embedded) {
                        return;
                      }
                      Navigator.of(context).push(
                        sharedAxisRoute<void>(
                          (_) => ChatScreen(
                            state: state,
                            conversationId: conversation.id,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.onTap,
    this.muted = false,
    this.selected = false,
    this.hero = false,
  });

  final Conversation conversation;
  final VoidCallback onTap;
  final bool muted;
  final bool selected;
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = conversation.unreadCount;
    final hasUnread = unread > 0;
    final activityAt = conversation.lastActivityAt;
    final retention = conversation.retentionSeconds;
    final title = conversationTitle(conversation);
    // MergeSemantics folds the title, activity time, and unread badge into a
    // single tappable node so a screen reader announces the row once.
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(BoneRadii.md),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(BoneRadii.md),
            child: ConstrainedBox(
              // 62dp is the direction's row height; the constraint is a
              // minimum so the row still grows at large text scales instead
              // of clipping.
              constraints: const BoxConstraints(
                minHeight: BoneSpacing.rowHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: BoneSpacing.sm,
                  vertical: BoneSpacing.sm,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    conversationAvatar(
                      context,
                      conversation,
                      radius: 22,
                      hero: hero,
                    ),
                    const SizedBox(width: BoneSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight:
                                        hasUnread ? FontWeight.w700 : null,
                                  ),
                                ),
                              ),
                              if (muted) ...<Widget>[
                                const SizedBox(width: BoneSpacing.xs + 2),
                                Semantics(
                                  label: 'Muted',
                                  child: Icon(
                                    Icons.notifications_off_outlined,
                                    size: 15,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  conversationRowSubtitle(conversation),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                              if (retention != null &&
                                  retention > 0) ...<Widget>[
                                const SizedBox(width: BoneSpacing.sm),
                                // Compact on screen, spoken in full: `1d`
                                // should not be read out as "one dee".
                                StatusPill(
                                  label: retentionChipLabel(retention),
                                  uppercase: false,
                                  semanticsLabel: 'Disappearing after '
                                      '${retentionLabel(retention)}',
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: BoneSpacing.sm),
                    // Bounded so a long localised date, or a large text
                    // scale, truncates instead of overflowing the row. The
                    // ListTile this row replaced used to do this for free.
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 112),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: <Widget>[
                          if (activityAt != null)
                            Text(
                              formatDate(context, activityAt),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                // Unread rows lift the timestamp to full
                                // text colour rather than to the accent: the
                                // accent is already spent on the count
                                // beneath it, and two accents in one 62dp
                                // row is one too many.
                                color: hasUnread ? scheme.onSurface : null,
                                fontWeight: hasUnread ? FontWeight.w600 : null,
                              ),
                            ),
                          if (hasUnread) ...<Widget>[
                            const SizedBox(height: BoneSpacing.xs + 2),
                            _unreadIndicator(unread),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A dot for a single unread message, a count for more.
///
/// The old badge always rendered a number, which gave one message the same
/// weight as thirty. The spoken label is identical either way, so dropping
/// the number changed nothing for a screen reader.
Widget _unreadIndicator(int count) {
  final spoken = '$count unread message${count == 1 ? '' : 's'}';
  if (count == 1) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: StatusDot(semanticsLabel: spoken),
    );
  }
  return StatusPill(
    label: count > 99 ? '99+' : '$count',
    tone: StatusTone.accent,
    semanticsLabel: spoken,
  );
}

IconData conversationIcon(Conversation conversation) {
  if (conversation.isDm) {
    return Icons.person_outline;
  }
  if (conversation.isChannel) {
    return Icons.tag;
  }
  return Icons.group_outlined;
}

String conversationTitle(Conversation conversation) {
  final title = conversation.title;
  if (title != null && title.isNotEmpty) {
    return title;
  }
  if (conversation.isDm) {
    final peerId = conversation.peerAccountId;
    // Name the person, not the conversation kind. Falls back to a shortened
    // account ID rather than a generic label so two DMs are never identical.
    if (peerId != null) {
      return accountLabel(peerId, conversation.peerUsername);
    }
    return 'Direct message';
  }
  if (conversation.isChannel) {
    return 'Channel';
  }
  return 'Group chat';
}

String conversationSubtitle(Conversation conversation) {
  final retention = conversation.retentionSeconds;
  final parts = <String>[
    if (conversation.isDm) 'Direct message',
    if (conversation.isGroup) 'Private group',
    if (conversation.isChannel) 'Community channel',
    'Encrypted',
    if (retention != null && retention > 0)
      'Disappearing (${retentionLabel(retention)})',
  ];
  return parts.join(' · ');
}

/// Subtitle for a chat-list row.
///
/// Shorter than [conversationSubtitle], which still backs the details screen
/// where the long form belongs: the row hands retention to its own chip, and
/// a DM drops the kind entirely because the title already names the person.
String conversationRowSubtitle(Conversation conversation) {
  final parts = <String>[
    if (conversation.isGroup) 'Private group',
    if (conversation.isChannel) 'Community channel',
    'Encrypted',
  ];
  return parts.join(' · ');
}

/// Avatar for a conversation row: peer initials for a named DM, otherwise the
/// kind icon. Decorative in both cases — the title carries the identity.
///
/// The tint is derived from the peer's account ID where there is one, so the
/// same contact is the same colour everywhere, and from the conversation ID
/// otherwise. See `ui/avatar.dart` for why it varies by temperature rather
/// than by hue.
Widget conversationAvatar(
  BuildContext context,
  Conversation conversation, {
  double radius = 24,
  bool hero = false,
}) {
  final peerId = conversation.peerAccountId;
  final colors = avatarColorsFor(context, peerId ?? conversation.id);
  final avatar = ExcludeSemantics(
    child: Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.fill,
        shape: BoxShape.circle,
        border: Border.all(color: colors.ring),
      ),
      child: conversation.isDm && peerId != null
          ? Text(
              accountInitials(peerId, conversation.peerUsername),
              style: TextStyle(
                fontSize: radius * 0.62,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                color: colors.glyph,
              ),
            )
          : Icon(
              conversationIcon(conversation),
              size: radius * 0.85,
              color: colors.glyph,
            ),
    ),
  );
  if (!hero) {
    return avatar;
  }
  return Hero(
    tag: conversationAvatarHeroTag(conversation.id),
    // The flight is between two circles of different diameters; without this
    // the child keeps its source size and jumps at the end.
    flightShuttleBuilder: (_, __, ___, ____, toHeroContext) =>
        toHeroContext.widget,
    child: avatar,
  );
}

String retentionLabel(int seconds) {
  if (seconds >= 86400 && seconds % 86400 == 0) {
    final days = seconds ~/ 86400;
    return days == 1 ? '1 day' : '$days days';
  }
  if (seconds >= 3600 && seconds % 3600 == 0) {
    final hours = seconds ~/ 3600;
    return hours == 1 ? '1 hour' : '$hours hours';
  }
  final minutes = (seconds / 60).ceil();
  return minutes <= 1 ? '1 minute' : '$minutes minutes';
}

/// Compact form of [retentionLabel] for the row chip: `30m`, `24h`, `7d`.
String retentionChipLabel(int seconds) {
  if (seconds >= 86400 && seconds % 86400 == 0) {
    return '${seconds ~/ 86400}d';
  }
  if (seconds >= 3600 && seconds % 3600 == 0) {
    return '${seconds ~/ 3600}h';
  }
  final minutes = (seconds / 60).ceil();
  return '${minutes < 1 ? 1 : minutes}m';
}
