import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/format.dart';
import '../../ui/widgets/empty_state.dart';
import '../search/search_screen.dart';
import 'chat_screen.dart';
import 'new_conversation_sheet.dart';

class ChatListScreen extends StatelessWidget {
  const ChatListScreen({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final conversations = state.conversations;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Search',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SearchScreen(state: state),
              ),
            ),
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showNewConversationSheet(context, state),
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
            : ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: conversations.length,
                separatorBuilder: (_, __) =>
                    const Divider(indent: 72, height: 1),
                itemBuilder: (context, index) {
                  final conversation = conversations[index];
                  return _ConversationTile(
                    conversation: conversation,
                    onTap: () {
                      state.selectConversation(conversation.id);
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ChatScreen(
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
  const _ConversationTile({required this.conversation, required this.onTap});

  final Conversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unread = conversation.unreadCount;
    final hasUnread = unread > 0;
    final activityAt = conversation.lastActivityAt;
    final title = conversationTitle(conversation);
    // MergeSemantics folds the title, activity time, and unread badge into a
    // single tappable node so a screen reader announces the row once.
    return MergeSemantics(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        // Decorative: the tile title already names the conversation.
        leading: ExcludeSemantics(
          child: CircleAvatar(
            radius: 24,
            backgroundColor: theme.colorScheme.secondaryContainer,
            child: Icon(
              conversationIcon(conversation),
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: hasUnread ? FontWeight.w700 : null,
          ),
        ),
        subtitle: Text(
          conversationSubtitle(conversation),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            if (activityAt != null)
              Text(
                formatDate(context, activityAt),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: hasUnread
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: hasUnread ? FontWeight.w600 : null,
                ),
              ),
            if (hasUnread) ...<Widget>[
              const SizedBox(height: 4),
              _UnreadBadge(count: unread),
            ],
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = count > 99 ? '99+' : '$count';
    return Semantics(
      label: '$count unread message${count == 1 ? '' : 's'}',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minWidth: 20),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onPrimary,
                fontWeight: FontWeight.w700,
              ),
        ),
      ),
    );
  }
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
