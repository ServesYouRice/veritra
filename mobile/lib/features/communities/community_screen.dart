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
                children: const <Widget>[
                  SizedBox(height: 120),
                  EmptyState(
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
                  for (final community in state.communities)
                    _CommunityCard(
                      state: state,
                      community: community,
                      onCreateChannel: () => _createChannel(context, community),
                    ),
                  if (channelConversations.isNotEmpty) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                      child: Text(
                        'Channels you are in',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Card(
                      child: Column(
                        children: <Widget>[
                          for (final conversation in channelConversations)
                            ListTile(
                              leading: const Icon(Icons.tag),
                              title: Text(conversation.title ?? 'Channel'),
                              subtitle: const Text('Community channel'),
                              trailing:
                                  const Icon(Icons.chevron_right_outlined),
                              onTap: () {
                                state.selectConversation(conversation.id);
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => ChatScreen(state: state),
                                  ),
                                );
                              },
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
  });

  final AppState state;
  final Community community;
  final VoidCallback onCreateChannel;

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
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  Icons.groups_outlined,
                  color: theme.colorScheme.onPrimaryContainer,
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
            for (final channel in channels)
              ListTile(
                dense: true,
                leading: const SizedBox(width: 40, child: Icon(Icons.tag)),
                title: Text(channel.name),
              ),
          ],
        ),
      ),
    );
  }
}
