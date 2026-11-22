import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../features/chat/chat_list_screen.dart'
    show conversationAvatar, conversationTitle;
import '../../l10n/l10n.dart';
import '../tokens.dart';
import 'status_pill.dart';

/// What a quick-switcher pick targets: either a direct/group conversation or a
/// channel inside a community.
class QuickSwitchTarget {
  const QuickSwitchTarget.conversation(this.conversationId)
      : communityId = null,
        channelId = null;

  const QuickSwitchTarget.channel({
    required this.communityId,
    required this.conversationId,
    this.channelId,
  });

  final String conversationId;
  final String? communityId;
  final String? channelId;

  bool get isChannel => communityId != null;
}

/// Opens the local-only Ctrl+K / Cmd+K quick switcher modal. Searches only
/// conversations and decrypted community/channel names already on this device;
/// nothing ever leaves the device.
Future<QuickSwitchTarget?> showQuickSwitcher(
  BuildContext context,
  AppState state,
) {
  return showDialog<QuickSwitchTarget>(
    context: context,
    builder: (dialogContext) => _QuickSwitcherModal(state: state),
  );
}

class _QuickSwitcherModal extends StatefulWidget {
  const _QuickSwitcherModal({required this.state});

  final AppState state;

  @override
  State<_QuickSwitcherModal> createState() => _QuickSwitcherModalState();
}

class _QuickSwitcherEntry {
  const _QuickSwitcherEntry({
    required this.title,
    required this.subtitle,
    required this.unreadCount,
    required this.target,
    this.conversation,
    this.isPrivateChannel = false,
  });

  final String title;
  final String? subtitle;
  final int unreadCount;
  final QuickSwitchTarget target;
  final Conversation? conversation;
  final bool isPrivateChannel;
}

class _QuickSwitcherModalState extends State<_QuickSwitcherModal> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<_QuickSwitcherEntry> _entries(BuildContext context) {
    final state = widget.state;
    final l10n = context.l10n;
    final filter = _query.text.trim().toLowerCase();
    final items = <_QuickSwitcherEntry>[];

    for (final conversation in state.conversations) {
      if (conversation.isCommunityShared || conversation.isChannel) continue;
      if (state.requestBucket(conversation) != RequestBucket.chat) continue;
      final title = conversationTitle(
        l10n,
        conversation,
        profiles: state.profiles,
      );
      if (filter.isNotEmpty && !title.toLowerCase().contains(filter)) continue;
      items.add(
        _QuickSwitcherEntry(
          title: title,
          subtitle: null,
          unreadCount: conversation.unreadCount,
          conversation: conversation,
          target: QuickSwitchTarget.conversation(conversation.id),
        ),
      );
    }

    for (final community in state.communities) {
      final communityName = state.communityDisplayName(community) ??
          l10n.communityPlaceholderName;
      final channels =
          state.channelsByCommunity[community.id] ?? const <Channel>[];
      for (final channel in channels) {
        final conv = state.conversations
            .where((c) => channel.isRouted
                ? c.id == channel.conversationId
                : c.channelId == channel.id)
            .firstOrNull;
        if (conv == null) continue;
        final name = state.channelDisplayName(channel) ??
            (channel.kind == 'private'
                ? l10n.channelPrivatePlaceholderName
                : l10n.channelPlaceholderName);
        final combined = '$name $communityName'.toLowerCase();
        if (filter.isNotEmpty && !combined.contains(filter)) continue;
        items.add(
          _QuickSwitcherEntry(
            title: name,
            subtitle: communityName,
            unreadCount: conv.unreadCount,
            isPrivateChannel: channel.isRouted && channel.kind == 'private',
            target: QuickSwitchTarget.channel(
              communityId: community.id,
              conversationId: conv.id,
              channelId: channel.isRouted && channel.kind != 'private'
                  ? channel.id
                  : null,
            ),
          ),
        );
      }
    }

    // Unread first, then keep original recency order.
    items.sort((a, b) {
      final aUnread = a.unreadCount > 0 ? 1 : 0;
      final bUnread = b.unreadCount > 0 ? 1 : 0;
      return bUnread.compareTo(aUnread);
    });
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final entries = _entries(context);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: BoneSpacing.lg,
        vertical: BoneSpacing.xl,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                BoneSpacing.lg,
                BoneSpacing.lg,
                BoneSpacing.lg,
                BoneSpacing.sm,
              ),
              child: TextField(
                key: const Key('quick-switcher-input'),
                controller: _query,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (entries.isNotEmpty) {
                    Navigator.of(context).pop(entries.first.target);
                  }
                },
                decoration: InputDecoration(
                  hintText: l10n.quickSwitcherHint,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l10n.searchClear,
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _query.clear();
                            setState(() {});
                          },
                        ),
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: entries.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(BoneSpacing.xl),
                      child: Text(
                        l10n.quickSwitcherEmpty,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(
                        vertical: BoneSpacing.xs,
                      ),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return ListTile(
                          leading: entry.conversation != null
                              ? conversationAvatar(
                                  context,
                                  entry.conversation!,
                                  radius: 18,
                                  profiles: widget.state.profiles,
                                )
                              : CircleAvatar(
                                  radius: 18,
                                  backgroundColor: scheme.surfaceContainerHigh,
                                  foregroundColor: scheme.onSurfaceVariant,
                                  child: Icon(
                                    entry.isPrivateChannel
                                        ? Icons.lock_outline
                                        : Icons.tag,
                                    size: 18,
                                  ),
                                ),
                          title: Text(
                            entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: entry.subtitle == null
                              ? null
                              : Text(
                                  entry.subtitle!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: entry.unreadCount > 0
                              ? StatusDot(
                                  semanticsLabel: l10n.chatListUnreadSpoken(
                                    entry.unreadCount,
                                  ),
                                )
                              : null,
                          onTap: () => Navigator.of(context).pop(entry.target),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
