import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../features/auth/connect_screen.dart';
import '../features/chat/chat_list_screen.dart';
import '../features/communities/community_screen.dart';
import '../features/settings/settings_screen.dart';

/// Root scaffold. A conversation is a detail route pushed from the chat
/// list, not a tab; navigation adapts to a rail on wide layouts per
/// Material 3 guidance.
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
    final pages = <Widget>[
      ChatListScreen(state: widget.state),
      CommunityScreen(state: widget.state),
      SettingsScreen(state: widget.state),
    ];
    final wide = MediaQuery.sizeOf(context).width >= AppShell._railBreakpoint;
    if (wide) {
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: <Widget>[
              NavigationRail(
                selectedIndex: index,
                onDestinationSelected: (value) => setState(() => index = value),
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
      );
    }
    return Scaffold(
      body: SafeArea(child: pages[index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: <NavigationDestination>[
          for (final destination in _destinations)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon),
              label: destination.label,
            ),
        ],
      ),
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
