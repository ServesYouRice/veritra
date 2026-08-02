import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/widgets/empty_state.dart';
import '../chat/chat_screen.dart';

/// Communities: create a community, add channels, and open channel
/// conversations. Communities and channels are listed from the server
/// (`GET /communities`), plus every community_channel conversation the
/// account is a member of.
class CommunityScreen extends StatelessWidget {
  const CommunityScreen({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final channelConversations =
        state.conversations.where((c) => c.isChannel).toList();
    final hasContent =
        state.communities.isNotEmpty || channelConversations.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Communities')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.busy ? null : () => _createCommunity(context),
        icon: const Icon(Icons.group_add_outlined),
        label: const Text('New community'),
      ),
      body: RefreshIndicator(
        onRefresh: state.refreshCommunities,
        child: !hasContent
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  const SizedBox(height: 120),
                  // First-load vs. genuinely empty: a spinner until the initial
                  // fetch resolves, then the empty state.
                  if (!state.communitiesLoaded)
                    const Center(child: CircularProgressIndicator())
                  else
                    const EmptyState(
                      icon: Icons.groups_outlined,
                      title: 'No communities yet',
                      message: 'Create a community to organize people around '
                          'shared channels — private by default, encrypted '
                          'everywhere.',
                    ),
                ],
              )
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                children: <Widget>[
                  // Channels are navigable inside their community card, which
                  // is the only place they appear; the old duplicate
                  // "Channels you are in" section listed the same rows again
                  // with different behaviour.
                  for (final community in state.communities)
                    _CommunityCard(
                      state: state,
                      community: community,
                      onCreateChannel: () => _createChannel(context, community),
                      onOpenChannel: (conversationId) =>
                          _openChannel(context, conversationId),
                    ),
                  if (_orphanChannels(state).isNotEmpty) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                      child: Semantics(
                        header: true,
                        child: Text(
                          'Other channels you are in',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ),
                    Card(
                      child: Column(
                        children: <Widget>[
                          for (final conversation in _orphanChannels(state))
                            ListTile(
                              leading: const Icon(Icons.tag),
                              title: Text(conversation.title ?? 'Channel'),
                              subtitle: const Text('Community channel'),
                              trailing:
                                  const Icon(Icons.chevron_right_outlined),
                              onTap: () =>
                                  _openChannel(context, conversation.id),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  void _openChannel(BuildContext context, String conversationId) {
    state.selectAndPrepare(conversationId);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          state: state,
          conversationId: conversationId,
        ),
      ),
    );
  }

  /// Channel conversations whose community is not in the listed set — for
  /// example a channel in a community the account can no longer list. Without
  /// this fallback they would be unreachable.
  static List<Conversation> _orphanChannels(AppState state) {
    final known = <String>{
      for (final channels in state.channelsByCommunity.values)
        for (final channel in channels) channel.id,
    };
    return state.conversations
        .where((conversation) =>
            conversation.isChannel &&
            (conversation.channelId == null ||
                !known.contains(conversation.channelId)))
        .toList(growable: false);
  }

  Future<void> _createCommunity(BuildContext context) async {
    final name = await _promptForName(
      context,
      title: 'New community',
      label: 'Community name',
    );
    if (name == null || name.isEmpty) {
      return;
    }
    final community = await state.createCommunity(name);
    if (!context.mounted) {
      return;
    }
    if (community == null && state.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.error!)),
      );
    }
  }

  Future<void> _createChannel(
    BuildContext context,
    Community community,
  ) async {
    final name = await _promptForName(
      context,
      title: 'New channel in ${community.name}',
      label: 'Channel name',
    );
    if (name == null || name.isEmpty) {
      return;
    }
    await state.createChannel(community.id, name);
    if (!context.mounted) {
      return;
    }
    if (state.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.error!)),
      );
    }
  }

  Future<String?> _promptForName(
    BuildContext context, {
    required String title,
    required String label,
  }) async {
    final controller = TextEditingController();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: label),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Create'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return null;
      }
      return controller.text.trim();
    } finally {
      controller.dispose();
    }
  }
}

class _CommunityCard extends StatelessWidget {
  const _CommunityCard({
    required this.state,
    required this.community,
    required this.onCreateChannel,
    required this.onOpenChannel,
  });

  final AppState state;
  final Community community;
  final VoidCallback onCreateChannel;
  final void Function(String conversationId) onOpenChannel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final channels =
        state.channelsByCommunity[community.id] ?? const <Channel>[];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ListTile(
              // Decorative: the community name is already the tile title.
              leading: ExcludeSemantics(
                child: CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.groups_outlined,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              title: Text(community.name),
              subtitle: Text(
                channels.isEmpty
                    ? 'No channels yet'
                    : '${channels.length} channel'
                        '${channels.length == 1 ? '' : 's'}',
              ),
              trailing: IconButton(
                tooltip: 'New channel',
                onPressed: state.busy ? null : onCreateChannel,
                icon: const Icon(Icons.add),
              ),
            ),
            if (channels.isEmpty)
              const ListTile(
                dense: true,
                leading: SizedBox(width: 40, child: Icon(Icons.tag)),
                title: Text('No channels yet'),
                subtitle: Text('Use + to create the first one.'),
              ),
            for (final channel in channels)
              _ChannelTile(
                channel: channel,
                conversationId: _conversationIdFor(channel.id),
                onOpen: onOpenChannel,
              ),
          ],
        ),
      ),
    );
  }

  /// The conversation backing a channel, if this account is a member of it.
  String? _conversationIdFor(String channelId) => state.conversations
      .where((conversation) => conversation.channelId == channelId)
      .firstOrNull
      ?.id;
}

/// A channel row inside its community card. Rows without a backing
/// conversation say why they cannot be opened instead of silently ignoring
/// the tap.
class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.conversationId,
    required this.onOpen,
  });

  final Channel channel;
  final String? conversationId;
  final void Function(String conversationId) onOpen;

  @override
  Widget build(BuildContext context) {
    final id = conversationId;
    return ListTile(
      dense: true,
      enabled: id != null,
      leading: const SizedBox(width: 40, child: Icon(Icons.tag)),
      title: Text(channel.name),
      subtitle: id == null ? const Text('You are not a member yet') : null,
      trailing: id == null ? null : const Icon(Icons.chevron_right_outlined),
      onTap: id == null ? null : () => onOpen(id),
    );
  }
}
