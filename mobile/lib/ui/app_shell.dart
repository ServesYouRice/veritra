import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../features/auth/connect_screen.dart';
import '../features/chat/chat_list_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/communities/community_screen.dart';
import '../features/settings/settings_screen.dart';
import 'tokens.dart';
import 'widgets/connection_banner.dart';
import 'widgets/empty_state.dart';

/// Root scaffold. Navigation adapts to a rail on wide layouts per Material 3
/// guidance, and at that width the chat list and the selected conversation
/// sit side by side instead of the conversation covering the list.
class AppShell extends StatefulWidget {
  const AppShell({required this.state, super.key});

  final AppState state;

  static const double _railBreakpoint = 720;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int index = 0;

  static const _destinations = <_Destination>[
    _Destination(
      icon: Icons.chat_bubble_outline,
      selectedIcon: Icons.chat_bubble,
      label: 'Chats',
    ),
    _Destination(
      icon: Icons.groups_outlined,
      selectedIcon: Icons.groups,
      label: 'Communities',
    ),
    _Destination(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (!widget.state.connected) {
      return ConnectScreen(state: widget.state);
    }
    final wide = MediaQuery.sizeOf(context).width >= AppShell._railBreakpoint;
    // At rail width the chat list keeps its own pane and opening a
    // conversation fills the detail pane, so selection survives navigating
    // between destinations. Narrow layouts keep pushing a full-screen route.
    final pages = <Widget>[
      wide
          ? _ChatWorkspace(state: widget.state)
          : ChatListScreen(state: widget.state),
      CommunityScreen(state: widget.state),
      SettingsScreen(state: widget.state),
    ];
    if (wide) {
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: <Widget>[
              ConnectionBanner(state: widget.state),
              Expanded(
                child: Row(
                  children: <Widget>[
                    NavigationRail(
                      selectedIndex: index,
                      onDestinationSelected: (value) =>
                          setState(() => index = value),
                      labelType: NavigationRailLabelType.all,
                      destinations: <NavigationRailDestination>[
                        for (final destination in _destinations)
                          NavigationRailDestination(
                            icon: Icon(destination.icon),
                            selectedIcon: Icon(destination.selectedIcon),
                            label: Text(destination.label),
                          ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: pages[index]),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            ConnectionBanner(state: widget.state),
            Expanded(child: pages[index]),
          ],
        ),
      ),
      bottomNavigationBar: _FloatingNav(
        selectedIndex: index,
        destinations: _destinations,
        onSelected: (value) => setState(() => index = value),
      ),
    );
  }
}

/// A pill above the bottom edge instead of a full-width `NavigationBar`
/// (`docs/design.md` §8).
///
/// It is still the `Scaffold`'s `bottomNavigationBar` rather than a `Stack`
/// overlay, so page content is inset above it rather than scrolling behind
/// it. That is deliberate: two of the three destinations own a
/// `FloatingActionButton`, and floating the nav over the page puts a centred
/// pill and a bottom-right FAB in the same strip with nothing arbitrating
/// between them on a narrow screen. The pill is where the visual change is.
class _FloatingNav extends StatelessWidget {
  const _FloatingNav({
    required this.selectedIndex,
    required this.destinations,
    required this.onSelected,
  });

  final int selectedIndex;
  final List<_Destination> destinations;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          BoneSpacing.xl,
          BoneSpacing.sm,
          BoneSpacing.xl,
          BoneSpacing.md,
        ),
        child: Container(
          padding: const EdgeInsets.all(BoneSpacing.xs),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(BoneRadii.pill),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: <Widget>[
              for (var i = 0; i < destinations.length; i++)
                Expanded(
                  child: _NavItem(
                    destination: destinations[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelected(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _Destination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected ? scheme.onPrimary : scheme.onSurfaceVariant;
    // NavigationBar supplied the selected/button semantics for free; a
    // hand-rolled bar has to say it itself or the nav stops announcing which
    // destination is current.
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? scheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(BoneRadii.pill),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(BoneRadii.pill),
          child: Container(
            constraints: const BoxConstraints(
              minHeight: BoneSpacing.minTapTarget,
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: BoneSpacing.sm),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ExcludeSemantics(
                  child: Icon(
                    selected ? destination.selectedIcon : destination.icon,
                    size: 20,
                    color: foreground,
                  ),
                ),
                const SizedBox(width: BoneSpacing.sm),
                Flexible(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Master-detail chat layout for wide windows.
class _ChatWorkspace extends StatelessWidget {
  const _ChatWorkspace({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final selected = state.selectedConversationId;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 360,
          child: ChatListScreen(state: state, embedded: true),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: selected == null
              ? const EmptyState(
                  icon: Icons.forum_outlined,
                  title: 'No conversation selected',
                  message: 'Pick a conversation from the list to read it here.',
                )
              : ChatScreen(
                  key: ValueKey<String>(selected),
                  state: state,
                  conversationId: selected,
                  showBackButton: false,
                ),
        ),
      ],
    );
  }
}

class _Destination {
  const _Destination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}
