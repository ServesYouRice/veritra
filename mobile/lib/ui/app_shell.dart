import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../features/auth/connect_screen.dart';
import '../features/chat/chat_list_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/communities/community_screen.dart';
import '../features/settings/settings_screen.dart';
import 'tokens.dart';
import 'widgets/connection_banner.dart';
import 'widgets/demo_banner.dart';
import 'widgets/empty_state.dart';
import 'widgets/listenable_selector.dart';
import '../l10n/l10n.dart';

bool shouldShowFloatingNavLabels({
  required double width,
  required double textScale,
}) {
  return width >= 440 && textScale < 1.1;
}

/// How the root scaffold arranges itself at a given window width.
enum ShellLayout {
  /// Phones: the floating bottom nav, and a conversation is a pushed route.
  compact,

  /// Small tablets, foldables and landscape phones: a navigation rail, but a
  /// conversation still opens full width. Two panes here would leave the
  /// thread narrower than a phone.
  rail,

  /// Tablets and desktop windows: the rail plus the chat list and the open
  /// conversation side by side.
  workspace,
}

/// Material 3 window size classes: compact below 600dp, medium below 840dp,
/// expanded from 840dp.
ShellLayout shellLayoutFor(double width) {
  if (width >= 840) return ShellLayout.workspace;
  if (width >= 600) return ShellLayout.rail;
  return ShellLayout.compact;
}

/// Root scaffold. Navigation adapts to a rail from the medium width class per
/// Material 3 guidance, and from the expanded class the chat list and the
/// selected conversation sit side by side instead of the conversation
/// covering the list.
class AppShell extends StatefulWidget {
  const AppShell({required this.state, super.key});

  final AppState state;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int index = 0;

  static const _destinations = <_Destination>[
    _Destination(
      icon: Icons.chat_bubble_outline,
      selectedIcon: Icons.chat_bubble,
      label: _chatsLabel,
    ),
    _Destination(
      icon: Icons.groups_outlined,
      selectedIcon: Icons.groups,
      label: _communitiesLabel,
    ),
    _Destination(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: _settingsLabel,
    ),
  ];

  static String _chatsLabel(AppLocalizations l10n) => l10n.navChats;
  static String _communitiesLabel(AppLocalizations l10n) => l10n.navCommunities;
  static String _settingsLabel(AppLocalizations l10n) => l10n.settingsTitle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Runs again whenever the app's locale changes.
    _useAppLocale();
  }

  @override
  void didUpdateWidget(AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _useAppLocale();
  }

  /// The errors, recovery and probe text AppState stores for the UI follow
  /// the app's locale (T44C). Push payloads stay generic: they carry no text.
  void _useAppLocale() => widget.state.l10n = context.l10n;

  @override
  Widget build(BuildContext context) {
    // The shell depends only on where the session stands. Each page listens
    // to the state for what it shows itself (T49C-1), so a notification does
    // not rebuild a page that is hidden or unaffected.
    return ListenableSelector<(SessionLifecycle, bool)>(
      listenable: widget.state,
      select: () => (widget.state.lifecycle, widget.state.connected),
      builder: (context, _, __) {
        final content = _buildContent(context);
        if (!widget.state.config.demo) return content;
        return Column(
          children: <Widget>[
            const DemoBanner(),
            Expanded(child: content),
          ],
        );
      },
    );
  }

  Widget _buildContent(BuildContext context) {
    if (widget.state.lifecycle == SessionLifecycle.initializing) {
      return const _StartupState();
    }
    if (widget.state.lifecycle == SessionLifecycle.recoveryRequired) {
      return _RecoveryState(state: widget.state);
    }
    if (!widget.state.connected) {
      return ConnectScreen(state: widget.state);
    }
    final layout = shellLayoutFor(MediaQuery.sizeOf(context).width);
    final wide = layout != ShellLayout.compact;
    // At workspace width the chat list keeps its own pane and opening a
    // conversation fills the detail pane, so selection survives navigating
    // between destinations. Narrower layouts keep pushing a full-screen route.
    final pages = <Widget>[
      layout == ShellLayout.workspace
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
                            label: Text(destination.label(context.l10n)),
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
    final showLabels = shouldShowFloatingNavLabels(
      width: MediaQuery.sizeOf(context).width,
      textScale: MediaQuery.textScalerOf(context).scale(1),
    );
    // NavigationBar supplied the selected/button semantics for free; a
    // hand-rolled bar has to say it itself or the nav stops announcing which
    // destination is current.
    return Semantics(
      label: destination.label(context.l10n),
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
            padding: const EdgeInsets.symmetric(horizontal: BoneSpacing.sm),
            // Centred by the Row, not by Container.alignment: an Align
            // expands to the bottom-bar slot's loose height, which is the
            // whole screen, and the pill swallowed the page (T43C).
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                ExcludeSemantics(
                  child: Icon(
                    selected ? destination.selectedIcon : destination.icon,
                    size: 20,
                    color: foreground,
                  ),
                ),
                if (showLabels) ...<Widget>[
                  const SizedBox(width: BoneSpacing.sm),
                  Flexible(
                    child: Text(
                      destination.label(context.l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: foreground,
                      ),
                    ),
                  ),
                ],
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
    return Row(
      children: <Widget>[
        SizedBox(
          width: 360,
          child: ChatListScreen(state: state, embedded: true),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          // The list and the open conversation listen for themselves; this
          // pane only follows the selection.
          child: ListenableSelector<String?>(
            listenable: state,
            select: () => state.selectedConversationId,
            builder: (context, selected, _) => selected == null
                ? EmptyState(
                    icon: Icons.forum_outlined,
                    title: context.l10n.shellNoConversationTitle,
                    message: context.l10n.shellNoConversationMessage,
                  )
                : ChatScreen(
                    key: ValueKey<String>(selected),
                    state: state,
                    conversationId: selected,
                    showBackButton: false,
                  ),
          ),
        ),
      ],
    );
  }
}

class _StartupState extends StatelessWidget {
  const _StartupState();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CircularProgressIndicator(),
              const SizedBox(height: BoneSpacing.lg),
              Text(context.l10n.shellRestoring),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecoveryState extends StatelessWidget {
  const _RecoveryState({required this.state});

  final AppState state;

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.shellResetTitle),
        content: Text(context.l10n.shellResetMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.shellResetConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.resetUnreadableLocalData(confirmed: true);
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
    return Scaffold(
      body: SafeArea(
        // Centred when the content fits; scrolls when it does not (a short
        // screen, large text, a long message), so no action is out of reach.
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(BoneSpacing.xl),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 2 * BoneSpacing.xl,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Icon(Icons.lock_reset_outlined, size: 48),
                      const SizedBox(height: BoneSpacing.lg),
                      Text(
                        context.l10n.shellRecoveryTitle,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: BoneSpacing.sm),
                      Text(
                        state.recoveryMessage ??
                            context.l10n.shellRecoveryFallback,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: BoneSpacing.lg),
                      FilledButton(
                        onPressed: state.busy ? null : state.tryRestoreSession,
                        child: Text(context.l10n.shellRetryRestore),
                      ),
                      if (state.canContinueWithoutRestore)
                        TextButton(
                          onPressed:
                              state.busy ? null : state.continueWithoutRestore,
                          child: Text(context.l10n.shellContinueToSignIn),
                        )
                      else if (state.canResetLocalData)
                        TextButton(
                          onPressed:
                              state.busy ? null : () => _confirmReset(context),
                          child: Text(context.l10n.shellResetDevice),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
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
  final String Function(AppLocalizations l10n) label;
}
