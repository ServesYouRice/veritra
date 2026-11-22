import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../ui/avatar.dart';
import '../../ui/motion.dart';
import '../../ui/photo_avatar.dart';
import '../../ui/reauthenticate.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/quick_switcher.dart';
import '../../ui/widgets/status_pill.dart';
import '../chat/chat_screen.dart';
import '../chat/roles_screen.dart';
import '../reports/owner_reports_screen.dart';
import 'community_info_screen.dart';
import 'community_screen.dart' show createCommunityDialog;
import 'create_channel_screen.dart';
import 'edit_info_dialog.dart';
import 'membership_screens.dart';

/// Desktop 3-pane Communities workspace (Discord-style):
/// Community icon rail -> Collapsible channel sidebar -> Live channel chat.
class CommunityWorkspace extends StatefulWidget {
  const CommunityWorkspace({
    required this.state,
    this.initialCommunityId,
    this.initialConversationId,
    this.initialChannelId,
    this.onQuickSwitch,
    super.key,
  });

  final AppState state;
  final String? initialCommunityId;
  final String? initialConversationId;
  final String? initialChannelId;
  final ValueChanged<QuickSwitchTarget>? onQuickSwitch;

  @override
  State<CommunityWorkspace> createState() => _CommunityWorkspaceState();
}

class _CommunityWorkspaceState extends State<CommunityWorkspace> {
  String? _selectedCommunityId;
  String? _selectedConversationId;
  String? _selectedChannelId;
  final Set<String> _collapsedCategories = <String>{};

  @override
  void initState() {
    super.initState();
    _selectedCommunityId = widget.initialCommunityId;
    _selectedConversationId = widget.initialConversationId;
    _selectedChannelId = widget.initialChannelId;
  }

  @override
  void didUpdateWidget(CommunityWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialCommunityId != oldWidget.initialCommunityId &&
        widget.initialCommunityId != null) {
      _selectedCommunityId = widget.initialCommunityId;
    }
    if (widget.initialConversationId != oldWidget.initialConversationId &&
        widget.initialConversationId != null) {
      _selectedConversationId = widget.initialConversationId;
      _selectedChannelId = widget.initialChannelId;
    }
  }

  AppState get state => widget.state;

  String? _conversationIdFor(Channel channel) => state.conversations
      .where((c) => channel.isRouted
          ? c.id == channel.conversationId
          : c.channelId == channel.id)
      .firstOrNull
      ?.id;

  int _channelUnread(Channel channel) {
    final conv = state.conversations
        .where((c) => channel.isRouted
            ? c.id == channel.conversationId
            : c.channelId == channel.id)
        .firstOrNull;
    if (conv == null) return 0;
    // Shared-group open channels share one conversation unread counter.
    return conv.unreadCount;
  }

  int _communityUnread(Community community) {
    final channels =
        state.channelsByCommunity[community.id] ?? const <Channel>[];
    final seen = <String>{};
    var total = 0;
    for (final channel in channels) {
      final conv = state.conversations
          .where((c) => channel.isRouted
              ? c.id == channel.conversationId
              : c.channelId == channel.id)
          .firstOrNull;
      if (conv != null && seen.add(conv.id)) {
        total += conv.unreadCount;
      }
    }
    return total;
  }

  void _selectChannel(Community community, Channel channel) {
    final convId = _conversationIdFor(channel);
    if (convId == null) return;
    final routedChannelId =
        channel.isRouted && channel.kind != 'private' ? channel.id : null;
    state.selectChannel(convId, routedChannelId);
    state.selectAndPrepare(convId);
    setState(() {
      _selectedCommunityId = community.id;
      _selectedConversationId = convId;
      _selectedChannelId = routedChannelId;
    });
  }

  Future<void> _createCommunity(BuildContext context) async {
    final name = await createCommunityDialog(context);
    if (name == null || name.isEmpty || !context.mounted) return;
    final community = await state.createCommunity(name);
    if (!context.mounted) return;
    if (community != null) {
      setState(() => _selectedCommunityId = community.id);
    } else if (state.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.error!)),
      );
    }
  }

  void _join(BuildContext context) => Navigator.of(context).push(
        sharedAxisRoute<void>((_) => JoinByLinkScreen(state: state)),
      );

  Future<void> _createChannel(BuildContext context, Community community) async {
    if (community.sharedConversationId == null) {
      final name = await createCommunityDialog(
        context,
        title: context.l10n.communityNewChannelIn(
          state.communityDisplayName(community) ??
              context.l10n.communityPlaceholderName,
        ),
        label: context.l10n.communityChannelName,
      );
      if (name != null && name.isNotEmpty) {
        await state.createChannel(community.id, name);
        if (!context.mounted) return;
        final skipped = state.lastChannelSkippedMembers;
        if (state.error != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.error!)),
          );
        } else if (skipped > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.l10n.channelMembersSkipped(skipped)),
            ),
          );
        }
      }
      return;
    }
    await CreateChannelScreen.open(context, state, community);
  }

  Future<void> _editInfo(
    BuildContext context,
    Community community, {
    Channel? channel,
  }) =>
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => EditInfoDialog(
          state: state,
          community: community,
          channel: channel,
        ),
      );

  Future<void> _openQuickSwitcher(BuildContext context) async {
    final target = await showQuickSwitcher(context, state);
    if (target == null || !mounted) return;
    if (widget.onQuickSwitch != null) {
      widget.onQuickSwitch!(target);
      return;
    }
    if (target.isChannel) {
      state.selectChannel(target.conversationId, target.channelId);
      state.selectAndPrepare(target.conversationId);
      setState(() {
        _selectedCommunityId = target.communityId;
        _selectedConversationId = target.conversationId;
        _selectedChannelId = target.channelId;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hairline = BoneColors.hairline(theme.brightness);
    final communities = state.communities;

    if (communities.isEmpty) {
      return Scaffold(
        body: !state.communitiesLoaded
            ? const Center(child: CircularProgressIndicator())
            : EmptyState(
                icon: Icons.groups_outlined,
                title: l10n.communityEmptyTitle,
                message: l10n.communityEmptyMessage,
                action: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: BoneSpacing.md,
                  runSpacing: BoneSpacing.sm,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed:
                          state.busy ? null : () => _createCommunity(context),
                      icon: const Icon(Icons.group_add_outlined),
                      label: Text(l10n.communityNew),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _join(context),
                      icon: const Icon(Icons.link),
                      label: Text(l10n.joinTitle),
                    ),
                  ],
                ),
              ),
      );
    }

    final activeCommunity =
        communities.where((c) => c.id == _selectedCommunityId).firstOrNull ??
            communities.first;
    final channels =
        state.channelsByCommunity[activeCommunity.id] ?? const <Channel>[];

    // Auto-select the first openable channel if none is selected in this community.
    String? activeConvId = _selectedConversationId;
    String? activeChannelId = _selectedChannelId;
    final belongsToCommunity = activeConvId != null &&
        channels.any((ch) {
          final id = _conversationIdFor(ch);
          if (id != activeConvId) return false;
          if (ch.isRouted && ch.kind != 'private') {
            return activeChannelId == ch.id;
          }
          return activeChannelId == null;
        });
    if (!belongsToCommunity) {
      activeConvId = null;
      activeChannelId = null;
    }

    return Row(
      children: <Widget>[
        // Pane 1: Community switcher rail on darkest canvas tone.
        Material(
          color: scheme.surface,
          child: SizedBox(
            width: 68,
            child: Column(
              children: <Widget>[
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      vertical: BoneSpacing.md,
                    ),
                    children: <Widget>[
                      for (final community in communities)
                        _CommunityRailIcon(
                          community: community,
                          name: state.communityDisplayName(community) ??
                              l10n.communityPlaceholderName,
                          iconPng: state.communityIcon(community)?.png,
                          selected: community.id == activeCommunity.id,
                          unread: _communityUnread(community),
                          onTap: () => setState(() {
                            _selectedCommunityId = community.id;
                          }),
                        ),
                    ],
                  ),
                ),
                Divider(height: 1, color: hairline, indent: 14, endIndent: 14),
                const SizedBox(height: BoneSpacing.sm),
                IconButton(
                  key: const Key('workspace-new-community'),
                  tooltip: l10n.communityNew,
                  onPressed:
                      state.busy ? null : () => _createCommunity(context),
                  icon: const Icon(Icons.add),
                ),
                IconButton(
                  key: const Key('workspace-join-community'),
                  tooltip: l10n.joinTitle,
                  onPressed: () => _join(context),
                  icon: const Icon(Icons.link),
                ),
                const SizedBox(height: BoneSpacing.sm),
              ],
            ),
          ),
        ),
        VerticalDivider(width: 1, color: hairline),
        // Pane 2: Channel sidebar on elevated surface tone.
        Material(
          color: scheme.surfaceContainerLow,
          child: SizedBox(
            width: 260,
            child: _ChannelSidebar(
              state: state,
              community: activeCommunity,
              channels: channels,
              activeConversationId: activeConvId,
              activeChannelId: activeChannelId,
              collapsedCategories: _collapsedCategories,
              conversationIdFor: _conversationIdFor,
              channelUnread: _channelUnread,
              onToggleCategory: (id) => setState(() {
                if (!_collapsedCategories.add(id)) {
                  _collapsedCategories.remove(id);
                }
              }),
              onSelectChannel: (channel) =>
                  _selectChannel(activeCommunity, channel),
              onCreateChannel: () => _createChannel(context, activeCommunity),
              onEditCommunity: () => _editInfo(context, activeCommunity),
              onEditChannel: (channel) =>
                  _editInfo(context, activeCommunity, channel: channel),
              onOpenDetails: () => Navigator.of(context).push(
                sharedAxisRoute<void>(
                  (_) => CommunityDetailsScreen(
                    state: state,
                    community: activeCommunity,
                  ),
                ),
              ),
              onQuickSwitch: () => _openQuickSwitcher(context),
            ),
          ),
        ),
        VerticalDivider(width: 1, color: hairline),
        // Pane 3: Live channel thread.
        Expanded(
          child: activeConvId == null
              ? EmptyState(
                  icon: Icons.tag,
                  title: l10n.communitySelectPromptTitle,
                  message: l10n.communitySelectPromptMessage,
                )
              : ChatScreen(
                  key: ValueKey<String>(
                    'community-chat-$activeConvId-${activeChannelId ?? ''}',
                  ),
                  state: state,
                  conversationId: activeConvId,
                  showBackButton: false,
                ),
        ),
      ],
    );
  }
}

class _CommunityRailIcon extends StatelessWidget {
  const _CommunityRailIcon({
    required this.community,
    required this.name,
    required this.iconPng,
    required this.selected,
    required this.unread,
    required this.onTap,
  });

  final Community community;
  final String name;
  final Uint8List? iconPng;
  final bool selected;
  final int unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = avatarColorsFor(context, community.id);
    final initials = nameInitials(name);
    final radius = BorderRadius.circular(selected ? 14 : 22);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Tooltip(
        message: name,
        child: Semantics(
          button: true,
          selected: selected,
          label: name,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: SizedBox(
              height: 48,
              child: Row(
                children: <Widget>[
                  AnimatedContainer(
                    duration: BoneDurations.short,
                    width: 4,
                    height: selected ? 28 : (unread > 0 ? 8 : 0),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      AnimatedContainer(
                        duration: BoneDurations.short,
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: colors.fill,
                          borderRadius: radius,
                          border: selected
                              ? Border.all(color: scheme.primary, width: 2)
                              : null,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: iconPng != null
                            ? PhotoAvatar(
                                png: iconPng!,
                                radius: 22,
                                fallback: Icon(
                                  Icons.groups_outlined,
                                  size: 20,
                                  color: colors.glyph,
                                ),
                              )
                            : initials != null
                                ? Text(
                                    initials,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: colors.glyph,
                                    ),
                                  )
                                : Icon(
                                    Icons.groups_outlined,
                                    size: 20,
                                    color: colors.glyph,
                                  ),
                      ),
                      if (unread > 0 && !selected)
                        Positioned(
                          right: -2,
                          top: -2,
                          child: StatusDot(
                            size: 10,
                            semanticsLabel:
                                context.l10n.chatListUnreadSpoken(unread),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelSidebar extends StatelessWidget {
  const _ChannelSidebar({
    required this.state,
    required this.community,
    required this.channels,
    required this.activeConversationId,
    required this.activeChannelId,
    required this.collapsedCategories,
    required this.conversationIdFor,
    required this.channelUnread,
    required this.onToggleCategory,
    required this.onSelectChannel,
    required this.onCreateChannel,
    required this.onEditCommunity,
    required this.onEditChannel,
    required this.onOpenDetails,
    required this.onQuickSwitch,
  });

  final AppState state;
  final Community community;
  final List<Channel> channels;
  final String? activeConversationId;
  final String? activeChannelId;
  final Set<String> collapsedCategories;
  final String? Function(Channel channel) conversationIdFor;
  final int Function(Channel channel) channelUnread;
  final ValueChanged<String> onToggleCategory;
  final ValueChanged<Channel> onSelectChannel;
  final VoidCallback onCreateChannel;
  final VoidCallback onEditCommunity;
  final ValueChanged<Channel> onEditChannel;
  final VoidCallback onOpenDetails;
  final VoidCallback onQuickSwitch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hairline = BoneColors.hairline(theme.brightness);
    final l10n = context.l10n;
    final communityName =
        state.communityDisplayName(community) ?? l10n.communityPlaceholderName;
    final categories = state.communityCategories(community.id);
    final placed = <String?, List<Channel>>{};
    for (final channel in channels) {
      (placed[state.channelCategory(channel)] ??= <Channel>[]).add(channel);
    }
    final groups = <(String?, List<Channel>)>[
      if (placed[null] != null) (null, placed[null]!),
      for (final id in categories)
        if (placed[id] != null) (id, placed[id]!),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Community header bar.
        InkWell(
          onTap: onOpenDetails,
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: BoneSpacing.md),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: hairline)),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    communityName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                _menu(context, categories),
              ],
            ),
          ),
        ),
        // Quick switcher trigger.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            BoneSpacing.sm,
            BoneSpacing.sm,
            BoneSpacing.sm,
            BoneSpacing.xs,
          ),
          child: InkWell(
            onTap: onQuickSwitch,
            borderRadius: BorderRadius.circular(BoneRadii.sm),
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: BoneSpacing.md),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(BoneRadii.sm),
                border: Border.all(color: hairline),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.search, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: BoneSpacing.sm),
                  Expanded(
                    child: Text(
                      l10n.quickSwitcherTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: channels.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(BoneSpacing.lg),
                    child: Text(
                      l10n.communityNoChannelsHint,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: BoneSpacing.sm,
                    vertical: BoneSpacing.xs,
                  ),
                  children: <Widget>[
                    for (final (categoryId, members) in groups) ...<Widget>[
                      if (categoryId != null)
                        _categoryHeader(context, categoryId),
                      if (categoryId == null ||
                          !collapsedCategories.contains(categoryId))
                        for (final channel in members)
                          _channelRow(context, channel),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _categoryHeader(BuildContext context, String categoryId) {
    final theme = Theme.of(context);
    final collapsed = collapsedCategories.contains(categoryId);
    final name = state.categoryDisplayName(categoryId) ??
        context.l10n.communityCategoryPlaceholder;
    return InkWell(
      onTap: () => onToggleCategory(categoryId),
      borderRadius: BorderRadius.circular(BoneRadii.sm),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          BoneSpacing.xs,
          BoneSpacing.md,
          BoneSpacing.xs,
          BoneSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: BoneSpacing.xs),
            Expanded(
              child: Text(
                name.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _channelRow(BuildContext context, Channel channel) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final convId = conversationIdFor(channel);
    final routedChannelId =
        channel.isRouted && channel.kind != 'private' ? channel.id : null;
    final selected = convId != null &&
        convId == activeConversationId &&
        routedChannelId == activeChannelId;
    final unread = channelUnread(channel);
    final isPrivate = channel.isRouted && channel.kind == 'private';
    final name = state.channelDisplayName(channel) ??
        (channel.kind == 'private'
            ? l10n.channelPrivatePlaceholderName
            : l10n.channelPlaceholderName);
    final canEdit = channel.isRouted &&
        convId != null &&
        state.mayEditCommunityInfo(community.id, 'channel');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(BoneRadii.sm),
        child: InkWell(
          onTap: convId == null ? null : () => onSelectChannel(channel),
          onSecondaryTap: canEdit ? () => onEditChannel(channel) : null,
          onLongPress: canEdit ? () => onEditChannel(channel) : null,
          borderRadius: BorderRadius.circular(BoneRadii.sm),
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(
              horizontal: BoneSpacing.sm,
              vertical: BoneSpacing.xs,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  isPrivate ? Icons.lock_outline : Icons.tag,
                  size: 18,
                  color: selected || unread > 0
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                  semanticLabel: isPrivate ? l10n.channelPrivate : null,
                ),
                const SizedBox(width: BoneSpacing.sm),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: selected || unread > 0
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: convId == null
                          ? theme.disabledColor
                          : selected || unread > 0
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (unread > 0 && !selected)
                  Padding(
                    padding: const EdgeInsets.only(left: BoneSpacing.xs),
                    child: StatusDot(
                      semanticsLabel: l10n.chatListUnreadSpoken(unread),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context, List<String> categories) {
    final l10n = context.l10n;
    final canEdit = state.mayEditCommunityInfo(community.id, 'community');
    final shared = community.sharedConversationId;
    final actions = <({String key, IconData icon, String label})>[
      (
        key: 'details',
        icon: Icons.info_outline,
        label: l10n.communityToggleDetails,
      ),
      if (state.canCreateChannel(community.id))
        (key: 'channel', icon: Icons.add, label: l10n.communityNewChannel),
      if (canEdit)
        (key: 'edit', icon: Icons.edit_outlined, label: l10n.communityEditInfo),
      if (shared != null && (canEdit || categories.isNotEmpty))
        (
          key: 'info',
          icon: Icons.folder_outlined,
          label: l10n.communityInfoOpen,
        ),
      if (shared != null)
        (
          key: 'roles',
          icon: Icons.admin_panel_settings_outlined,
          label: l10n.rolesTitle,
        ),
      if (state.moderatesCommunity(community.id))
        (
          key: 'reports',
          icon: Icons.flag_outlined,
          label: l10n.c6ReportsTitle,
        ),
    ];
    return PopupMenuButton<String>(
      tooltip: l10n.communityActionsTooltip(
        state.communityDisplayName(community) ?? l10n.communityPlaceholderName,
      ),
      onSelected: (action) {
        switch (action) {
          case 'details':
            onOpenDetails();
          case 'channel':
            onCreateChannel();
          case 'edit':
            onEditCommunity();
          case 'info':
            Navigator.of(context).push(
              sharedAxisRoute<void>(
                (_) => CommunityInfoScreen(state: state, community: community),
              ),
            );
          case 'roles':
            Navigator.of(context).push(
              sharedAxisRoute<void>(
                (_) => RolesScreen(
                  state: state,
                  conversationId: community.sharedConversationId!,
                ),
              ),
            );
          case 'reports':
            Navigator.of(context).push(
              sharedAxisRoute<void>(
                (_) => OwnerReportsScreen(
                  state: state,
                  communityId: community.id,
                  reauthenticate: (ctx) => promptReauthenticate(ctx, state),
                ),
              ),
            );
        }
      },
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        for (final action in actions)
          PopupMenuItem<String>(
            value: action.key,
            child: Row(
              children: <Widget>[
                Icon(action.icon, size: 20),
                const SizedBox(width: BoneSpacing.md),
                Flexible(child: Text(action.label)),
              ],
            ),
          ),
      ],
    );
  }
}
