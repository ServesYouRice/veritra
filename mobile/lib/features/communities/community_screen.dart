import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../ui/avatar.dart';
import '../../ui/motion.dart';
import '../../ui/tokens.dart';
import '../../ui/validation.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/tile_group.dart';
import '../chat/chat_screen.dart';
import '../../ui/widgets/refresh_action.dart';

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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: LargeTitleBar(
        title: context.l10n.navCommunities,
        actions: <Widget>[RefreshAction(onRefresh: state.refreshCommunities)],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.busy ? null : () => _createCommunity(context),
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        icon: const Icon(Icons.group_add_outlined),
        label: Text(context.l10n.communityNew),
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
                    EmptyState(
                      icon: Icons.groups_outlined,
                      title: context.l10n.communityEmptyTitle,
                      message: context.l10n.communityEmptyMessage,
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
                    SectionHeader(context.l10n.communityOtherChannels),
                    TileGroup(
                      children: <Widget>[
                        for (final conversation in _orphanChannels(state))
                          ListTile(
                            leading: const Icon(Icons.tag),
                            title: Text(
                              conversation.title ??
                                  context.l10n.searchTypeChannel,
                            ),
                            subtitle:
                                Text(context.l10n.communityChannelSubtitle),
                            onTap: () => _openChannel(context, conversation.id),
                          ),
                      ],
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
      sharedAxisRoute<void>(
        (_) => ChatScreen(
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
      title: context.l10n.communityNew,
      label: context.l10n.communityName,
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
      title: context.l10n.communityNewChannelIn(community.name),
      label: context.l10n.communityChannelName,
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
        builder: (dialogContext) => ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            // Checked here so the reason sits under the field; an empty name
            // used to close the dialog and do nothing.
            final error = displayNameError(value.text, l10n: context.l10n);
            // An untouched field reads as a prompt, not an error; Create
            // still stays disabled until the name is valid.
            final shown = value.text.isEmpty ? null : error;
            void submit() {
              if (error == null) Navigator.of(dialogContext).pop(true);
            }

            return AlertDialog(
              title: Text(title),
              content: TextField(
                controller: controller,
                autofocus: true,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.words,
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  labelText: label,
                  errorText: shown,
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(context.l10n.commonCancel),
                ),
                FilledButton(
                  onPressed: error == null ? submit : null,
                  child: Text(context.l10n.commonCreate),
                ),
              ],
            );
          },
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
    final channels =
        state.channelsByCommunity[community.id] ?? const <Channel>[];
    final colors = avatarColorsFor(context, community.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: BoneSpacing.md),
      child: TileGroup(
        children: <Widget>[
          ListTile(
            // Decorative: the community name is already the tile title.
            leading: ExcludeSemantics(
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.fill,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.ring),
                ),
                child: Icon(
                  Icons.groups_outlined,
                  size: 18,
                  color: colors.glyph,
                ),
              ),
            ),
            title: Text(community.name),
            subtitle: Text(
              channels.isEmpty
                  ? context.l10n.communityNoChannels
                  : context.l10n.communityChannelCount(channels.length),
            ),
            trailing: IconButton(
              tooltip: context.l10n.communityNewChannel,
              onPressed: state.busy ? null : onCreateChannel,
              icon: const Icon(Icons.add),
            ),
          ),
          if (channels.isEmpty)
            ListTile(
              dense: true,
              leading: const SizedBox(width: 40, child: Icon(Icons.tag)),
              title: Text(context.l10n.communityNoChannels),
              subtitle: Text(context.l10n.communityNoChannelsHint),
            ),
          for (final channel in channels)
            _ChannelTile(
              channel: channel,
              conversationId: _conversationIdFor(channel.id),
              onOpen: onOpenChannel,
            ),
        ],
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
      subtitle: id == null ? Text(context.l10n.communityNotMember) : null,
      onTap: id == null ? null : () => onOpen(id),
    );
  }
}
