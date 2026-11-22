import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/errors.dart';
import '../../core/models.dart';
import '../../core/profile_service.dart';
import '../../ui/avatar.dart';
import '../../ui/format.dart';
import '../../ui/motion.dart';
import '../../ui/photo_avatar.dart';
import '../../ui/reauthenticate.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/bar_action.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/listenable_selector.dart';
import '../../ui/widgets/status_pill.dart';
import '../search/search_screen.dart';
import '../settings/invite_screen.dart';
import '../../ui/widgets/constrained_body.dart';
import 'chat_desktop.dart' show isDesktopPlatform;
import 'chat_preview.dart';
import 'chat_screen.dart';
import 'conversation_details_screen.dart';
import 'copied_history_screen.dart';
import 'mute_sheet.dart';
import 'message_request_screen.dart';
import 'new_conversation_sheet.dart';
import '../../l10n/l10n.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({
    required this.state,
    this.embedded = false,
    this.archived = false,
    this.onQuickSwitch,
    super.key,
  });

  final AppState state;

  /// The page of archived chats, opened from the chat list with a Back button
  /// (U28). The same rows, minus requests, in their own route.
  final bool archived;

  /// When embedded in the wide-layout workspace the list is one pane of a
  /// master-detail view: tapping a row updates the detail pane instead of
  /// pushing a full-screen route.
  final bool embedded;

  /// Optional quick-switcher callback for the embedded desktop pane.
  final VoidCallback? onQuickSwitch;

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final ValueNotifier<int> _draftTick = ValueNotifier<int>(0);

  AppState get state => widget.state;
  bool get archived => widget.archived;
  bool get embedded => widget.embedded;

  @override
  void dispose() {
    _draftTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilds only when a row could change (T49C-1): the list is often
    // hidden under an open conversation, and a notification about anything
    // else used to rebuild every visible row.
    return ListenableSelector<List<Object?>>(
      listenable: state,
      select: () => _chatListSelection(state, embedded: embedded),
      equals: listEquals,
      builder: (context, _, __) =>
          _PreviewLoader(state: state, child: _build(context)),
    );
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hairline = BoneColors.hairline(theme.brightness);
    final conversations = _visibleConversations(state);
    // Strangers wait behind one Requests row above the chats (B8, U28); they
    // never show in Archived.
    final requests = archived
        ? const <Conversation>[]
        : conversations.where(state.isMessageRequest).toList(growable: false);
    final positions = {for (final (i, c) in conversations.indexed) c.id: i};
    final chats = conversations
        .where((c) =>
            !state.isMessageRequest(c) && state.isArchived(c.id) == archived)
        .toList()
      ..sort((a, b) {
        final ap = state.conversationPrefs[a.id]?.pinnedAt,
            bp = state.conversationPrefs[b.id]?.pinnedAt;
        if (ap == null && bp == null)
          return positions[a.id]!.compareTo(positions[b.id]!);
        if (ap == null) return 1;
        if (bp == null) return -1;
        final c = bp.compareTo(ap);
        if (c != 0) return c;
        return positions[a.id]!.compareTo(positions[b.id]!);
      });
    final requestRows = requests.isEmpty ? 0 : 1;
    final listBody = RefreshIndicator(
      onRefresh: state.refreshConversations,
      child: chats.isEmpty && requests.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: <Widget>[
                const SizedBox(height: 120),
                // An empty list can mean "still loading"; showing the empty
                // state too early reads as "your data is gone".
                if (!state.conversationsLoaded)
                  const Center(child: CircularProgressIndicator())
                else if (archived)
                  EmptyState(
                    icon: Icons.archive_outlined,
                    title: context.l10n.chatListArchivedEmptyTitle,
                    message: context.l10n.chatListArchivedEmptyMessage,
                  )
                else
                  EmptyState(
                    icon: Icons.chat_bubble_outline,
                    title: context.l10n.chatListEmptyTitle,
                    message: context.l10n.chatListEmptyMessage,
                    action: _emptyActions(context),
                  ),
              ],
            )
          // No separators: rows are held apart by spacing and the active row
          // by a tinted ground, which is what removes the most recognisably
          // default surface in the app (`docs/design.md` §3).
          : ListView.builder(
              // Keeps the scroll offset when another destination replaces
              // the list and it comes back (T49C-4). Per account, so a
              // different account's list starts at the top.
              key: PageStorageKey<String>(
                '${archived ? 'chat-list-archived' : 'chat-list'}'
                ':${state.session?.accountId}',
              ),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                BoneSpacing.sm,
                BoneSpacing.sm,
                BoneSpacing.sm,
                BoneSpacing.lg,
              ),
              itemCount: requestRows + chats.length,
              itemBuilder: (context, index) {
                if (index < requestRows) {
                  return _RequestsTile(
                    count: requests.length,
                    onTap: () => Navigator.of(context).push(
                      sharedAxisRoute<void>(
                        (_) => _RequestsScreen(
                          state: state,
                          embedded: embedded,
                        ),
                      ),
                    ),
                  );
                }
                final conversation = chats[index - requestRows];
                return _ConversationTile(
                  conversation: conversation,
                  profiles: state.profiles,
                  pinned: state.isChatPinned(conversation.id),
                  muted: state.isMuted(conversation.id),
                  selected: embedded &&
                      state.selectedConversationId == conversation.id,
                  // The hero flight only exists on the pushed layout. In
                  // the embedded workspace this row and the open
                  // conversation share a route, and two widgets with one
                  // hero tag is an assertion, not a nicer animation.
                  hero: !embedded,
                  previews: state,
                  draftTick: _draftTick,
                  swipeOpensActions: true,
                  onActions: (anchor) => _showRowActions(
                    context,
                    conversation,
                    anchor: anchor,
                  ),
                  onTap: () async {
                    state.selectAndPrepare(conversation.id);
                    if (embedded) {
                      // The archive is its own page: leave it so the pane
                      // beside the list shows the chat that was picked.
                      if (archived) Navigator.of(context).pop();
                      _draftTick.value++;
                      return;
                    }
                    await Navigator.of(context).push(
                      sharedAxisRoute<void>(
                        (_) => ChatScreen(
                          state: state,
                          conversationId: conversation.id,
                        ),
                      ),
                    );
                    if (mounted) _draftTick.value++;
                  },
                );
              },
            ),
    );
    return Scaffold(
      backgroundColor: embedded ? Colors.transparent : null,
      appBar: AppBar(
        backgroundColor: embedded ? Colors.transparent : null,
        // A display-sized title is most of what stops the screen reading as
        // stock Material (`docs/design.md` §8). The bar stays fixed rather
        // than collapsing on scroll — a collapsing sliver would also have to
        // carry the RefreshIndicator, which is more machinery than the effect
        // is worth here.
        toolbarHeight: 64,
        titleSpacing: BoneSpacing.gutter,
        // One line that ellipsizes, so the title never runs over the words
        // in the bar (U11).
        title: Text(
          archived ? context.l10n.w8ArchivedChats : context.l10n.navChats,
          style: theme.textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          // New chat lives in the bar (U28) so nothing floats over a row. It
          // is the one filled control here: Bone rations its accent to the
          // primary action, active nav, unread count and focus ring. The
          // embedded list sits in a 340 dp pane, so it keeps icons only.
          if (!archived)
            BarAction(
                label: context.l10n.chatListNewChat,
                filled: true,
                wordsFromWidth:
                    embedded ? double.infinity : BarAction.minWordsWidth,
                onPressed: () => _startChat(context),
                icon: Icons.add_comment_outlined),
          if (!archived)
            BarAction(
                label: context.l10n.w8ArchivedChats,
                wordsFromWidth:
                    embedded ? double.infinity : BarAction.minWordsWidth,
                onPressed: () => Navigator.of(context).push(
                    sharedAxisRoute<void>((_) => ChatListScreen(
                        state: state, embedded: embedded, archived: true))),
                icon: Icons.archive_outlined),
          if (!archived && state.historyOnlyConversations.isNotEmpty)
            BarAction(
                label: context.l10n.k2HistoryOnlyTitle,
                wordsFromWidth:
                    embedded ? double.infinity : BarAction.minWordsWidth,
                onPressed: () => Navigator.of(context).push(
                    sharedAxisRoute<void>(
                        (_) => CopiedHistoryListScreen(state: state))),
                icon: Icons.history),
          if (!archived)
            IconButton(
              tooltip: context.l10n.chatListSearch,
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
      body: Column(
        children: <Widget>[
          if (embedded && !archived && widget.onQuickSwitch != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                BoneSpacing.md,
                BoneSpacing.xs,
                BoneSpacing.md,
                BoneSpacing.xs,
              ),
              child: InkWell(
                key: const Key('chat-list-quick-switch'),
                onTap: widget.onQuickSwitch,
                borderRadius: BorderRadius.circular(BoneRadii.sm),
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(
                    horizontal: BoneSpacing.md,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(BoneRadii.sm),
                    border: Border.all(color: hairline),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.search,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: BoneSpacing.sm),
                      Expanded(
                        child: Text(
                          context.l10n.quickSwitcherTitle,
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
            child: embedded ? listBody : ConstrainedBody(child: listBody),
          ),
        ],
      ),
    );
  }

  /// The new-chat sheet, then the chat it started (U27): selected in the
  /// workspace, pushed on a phone.
  Future<void> _startChat(BuildContext context) async {
    final started = await showNewConversationSheet(context, state);
    if (started == null || !context.mounted) return;
    state.selectAndPrepare(started.id);
    if (embedded) return;
    await Navigator.of(context).push(
      sharedAxisRoute<void>(
        (_) => ChatScreen(state: state, conversationId: started.id),
      ),
    );
  }

  /// "Start a chat" and, for an admin, "Invite someone" (U28). Server invites
  /// are minted by an owner or admin only, so no one else sees the button.
  Widget _emptyActions(BuildContext context) {
    final l10n = context.l10n;
    final role = state.session?.role;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: BoneSpacing.sm,
      runSpacing: BoneSpacing.sm,
      children: <Widget>[
        FilledButton.icon(
          onPressed: () => _startChat(context),
          icon: const Icon(Icons.add_comment_outlined),
          label: Text(l10n.chatListStartChat),
        ),
        if (role == 'owner' || role == 'admin')
          OutlinedButton.icon(
            onPressed: () async {
              if (await promptReauthenticate(context, state) &&
                  context.mounted) {
                await Navigator.of(context).push(
                  sharedAxisRoute<void>((_) => InviteScreen(state: state)),
                );
              }
            },
            icon: const Icon(Icons.person_add_alt_outlined),
            label: Text(l10n.chatListInviteSomeone),
          ),
      ],
    );
  }

  /// Long-press or right-click on a row. Offers only what the app already
  /// does elsewhere for a conversation; nothing here needs message content.
  Future<void> _showRowActions(
    BuildContext context,
    Conversation conversation, {
    Offset? anchor,
  }) async {
    final l10n = context.l10n;
    final muted = state.isMuted(conversation.id);
    final isArchived = state.isArchived(conversation.id);
    final isPinned = state.isChatPinned(conversation.id);
    final String? action;
    if (anchor != null && isDesktopPlatform) {
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox?;
      final rect = overlay == null
          ? RelativeRect.fromLTRB(anchor.dx, anchor.dy, anchor.dx, anchor.dy)
          : RelativeRect.fromRect(
              Rect.fromLTWH(anchor.dx, anchor.dy, 1, 1),
              Offset.zero & overlay.size,
            );
      action = await showMenu<String>(
        context: context,
        position: rect,
        items: <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: 'archive',
            child: Row(
              children: <Widget>[
                const Icon(Icons.archive_outlined, size: 18),
                const SizedBox(width: BoneSpacing.md),
                Text(isArchived ? l10n.w8Unarchive : l10n.w8Archive),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: 'pin',
            child: Row(
              children: <Widget>[
                const Icon(Icons.push_pin_outlined, size: 18),
                const SizedBox(width: BoneSpacing.md),
                Text(isPinned ? l10n.w8UnpinChat : l10n.w8PinChat),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: 'mute',
            child: Row(
              children: <Widget>[
                Icon(
                  muted
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_off_outlined,
                  size: 18,
                ),
                const SizedBox(width: BoneSpacing.md),
                Text(muted ? l10n.chatListUnmute : l10n.chatListMute),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: 'details',
            child: Row(
              children: <Widget>[
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: BoneSpacing.md),
                Text(l10n.chatListDetails),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem<String>(
            enabled: false,
            child: Text(
              l10n.w8ChatActionsLocalNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      );
    } else {
      action = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                  leading: const Icon(Icons.archive_outlined),
                  title: Text(isArchived ? l10n.w8Unarchive : l10n.w8Archive),
                  onTap: () => Navigator.of(sheetContext).pop('archive')),
              ListTile(
                  leading: const Icon(Icons.push_pin_outlined),
                  title: Text(isPinned ? l10n.w8UnpinChat : l10n.w8PinChat),
                  onTap: () => Navigator.of(sheetContext).pop('pin')),
              ListTile(
                leading: Icon(
                  muted
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_off_outlined,
                ),
                title: Text(
                  muted ? l10n.chatListUnmute : l10n.chatListMute,
                ),
                onTap: () => Navigator.of(sheetContext).pop('mute'),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(l10n.chatListDetails),
                onTap: () => Navigator.of(sheetContext).pop('details'),
              ),
              // U19: said once here, not on each action.
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  BoneSpacing.gutter,
                  BoneSpacing.xs,
                  BoneSpacing.gutter,
                  BoneSpacing.md,
                ),
                child: Text(
                  l10n.w8ChatActionsLocalNote,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (!context.mounted || action == null) {
      return;
    }
    if (action == 'archive' || action == 'pin') {
      try {
        if (action == 'archive') {
          await state.setConversationArchived(
              conversation.id, !state.isArchived(conversation.id));
        } else {
          await state.setChatPinned(
              conversation.id, !state.isChatPinned(conversation.id));
        }
      } catch (error) {
        if (context.mounted)
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(describeError(error, context.l10n))));
      }
      return;
    }
    if (action == 'details') {
      await Navigator.of(context).push(
        sharedAxisRoute<void>(
          (_) => ConversationDetailsScreen(
            state: state,
            conversationId: conversation.id,
          ),
        ),
      );
      return;
    }
    var duration = MuteDuration.off;
    if (!muted) {
      final chosen = await chooseMuteDuration(context);
      if (chosen == null || !context.mounted) return;
      duration = chosen;
    }
    final ok = await state.setConversationMute(conversation.id, duration);
    if (!ok && context.mounted) {
      final error = state.errorFor(Ops.mute);
      if (error != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
      }
    }
  }
}

/// The conversations the list may show. No rows until the request state is
/// read, so no stranger's chat shows as a normal one and none flashes into
/// Requests (B8). A community's shared group is opened per channel, from
/// Communities.
List<Conversation> _visibleConversations(AppState state) {
  final loaded = state.requestStateLoaded;
  return state.conversations
      .where(
        (c) =>
            !c.isCommunityShared &&
            (loaded
                ? state.requestBucket(c) != RequestBucket.hidden
                : state.requestBucket(c) == RequestBucket.chat),
      )
      .toList(growable: false);
}

/// A request opens its own screen, never the conversation: nothing is
/// loaded, read or acknowledged until the user accepts. True once accepted.
Future<bool> _openRequest(
  BuildContext context,
  AppState state,
  Conversation request, {
  required bool embedded,
}) async {
  final accepted = await Navigator.of(context).push<bool>(
    sharedAxisRoute<bool>(
      (_) => MessageRequestScreen(state: state, conversation: request),
    ),
  );
  if (accepted != true || !context.mounted) {
    return false;
  }
  state.selectAndPrepare(request.id);
  if (embedded) {
    return true;
  }
  await Navigator.of(context).push(
    sharedAxisRoute<void>(
      (_) => ChatScreen(state: state, conversationId: request.id),
    ),
  );
  return true;
}

/// The one row at the top of the chat list that holds every message request
/// (U28). Strangers stay behind it until the person opens it.
class _RequestsTile extends StatelessWidget {
  const _RequestsTile({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(BoneRadii.md),
          child: InkWell(
            key: const Key('requests-row'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(BoneRadii.md),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: BoneSpacing.rowHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: BoneSpacing.sm,
                  vertical: BoneSpacing.sm,
                ),
                child: Row(
                  children: <Widget>[
                    ExcludeSemantics(
                      child: CircleAvatar(
                        radius: 22,
                        backgroundColor: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurfaceVariant,
                        child: const Icon(Icons.mark_chat_unread_outlined),
                      ),
                    ),
                    const SizedBox(width: BoneSpacing.md),
                    Expanded(
                      child: Text(
                        context.l10n.requestsSection(count),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
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

/// The page behind the Requests row: each stranger as a row that opens its own
/// request screen (B8). It closes itself once the last request is gone.
class _RequestsScreen extends StatelessWidget {
  const _RequestsScreen({required this.state, required this.embedded});

  final AppState state;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final requests = _visibleConversations(state)
            .where(state.isMessageRequest)
            .toList(growable: false);
        if (requests.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted &&
                (ModalRoute.of(context)?.isCurrent ?? false)) {
              Navigator.of(context).pop();
            }
          });
        }
        return Scaffold(
          appBar: LargeTitleBar(
            title: context.l10n.requestsSection(requests.length),
          ),
          body: ListView.builder(
            padding: const EdgeInsets.all(BoneSpacing.sm),
            itemCount: requests.length,
            itemBuilder: (context, index) {
              final request = requests[index];
              return _ConversationTile(
                conversation: request,
                profiles: state.profiles,
                // A stranger's chosen name is not shown until the request is
                // accepted; their photo is.
                showProfileName: false,
                muted: false,
                selected: false,
                hero: false,
                onActions: (_) {},
                onTap: () async {
                  final accepted = await _openRequest(
                    context,
                    state,
                    request,
                    embedded: embedded,
                  );
                  // The pane beside the list shows the accepted chat.
                  if (accepted && embedded && context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
              );
            },
          ),
        );
      },
    );
  }
}

/// Everything [ChatListScreen] reads from [AppState] (T49C-1); the list
/// rebuilds only when this changes. Lists and models compare by identity:
/// AppState replaces them instead of editing them in place. A new read from
/// the state in the list or its rows must be added here, or the row stays
/// stale.
List<Object?> _chatListSelection(AppState state, {required bool embedded}) {
  final conversations = state.conversations;
  return <Object?>[
    conversations,
    state.conversationsLoaded,
    state.session?.accountId,
    embedded ? state.selectedConversationId : null,
    for (final conversation in conversations) state.isMuted(conversation.id),
    state.requestStateLoaded,
    state.conversationPrefs,
    state.session?.role,
    for (final conversation in conversations) state.requestBucket(conversation),
    state.historyOnlyConversations.isNotEmpty,
    state.profiles?.revision,
    // Each row follows its own last message (see [_RowSubtitle]); the switch
    // is here so the list reads the messages again when it is turned on.
    state.showChatPreviews,
  ];
}

/// Reads the last message of chats not opened this session from the local
/// store (U12), now and whenever the list changes. The read is idempotent:
/// [AppState.loadChatPreviews] skips what it already holds.
class _PreviewLoader extends StatefulWidget {
  const _PreviewLoader({required this.state, required this.child});

  final AppState state;
  final Widget child;

  @override
  State<_PreviewLoader> createState() => _PreviewLoaderState();
}

class _PreviewLoaderState extends State<_PreviewLoader> {
  /// Whether this list holds one chat-view guard. Message previews put chat
  /// text on the list, so the screen guard covers it while they show (U12).
  bool _guarding = false;

  /// The list rebuilds this widget whenever `showChatPreviews` changes (it is
  /// part of the list's selection), so [didUpdateWidget] keeps the guard in
  /// step with the setting.
  void _syncGuard() {
    final want = widget.state.showChatPreviews;
    if (want == _guarding) return;
    _guarding = want;
    want ? widget.state.enterChatView() : widget.state.leaveChatView();
  }

  @override
  void initState() {
    super.initState();
    _syncGuard();
    scheduleMicrotask(widget.state.loadChatPreviews);
  }

  @override
  void didUpdateWidget(_PreviewLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncGuard();
    scheduleMicrotask(widget.state.loadChatPreviews);
  }

  @override
  void dispose() {
    if (_guarding) widget.state.leaveChatView();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.onTap,
    required this.onActions,
    this.profiles,
    this.showProfileName = true,
    this.previews,
    this.draftTick,
    this.pinned = false,
    this.muted = false,
    this.selected = false,
    this.hero = false,
    this.swipeOpensActions = false,
  });

  final Conversation conversation;
  final ProfileService? profiles;
  final bool showProfileName;

  /// U36: a swipe in either direction opens the same menu as a long press.
  /// The row never leaves the list; the menu's own choices change it.
  final bool swipeOpensActions;

  /// Where this row reads the last message from (U12), or null for a row that
  /// never quotes one, such as a request.
  final AppState? previews;
  final Listenable? draftTick;
  final VoidCallback onTap;

  /// Opens the row's mute/details menu. Passes cursor position on desktop
  /// secondary-click so it can anchor a context menu, or null for sheets.
  final ValueChanged<Offset?> onActions;
  final bool pinned;
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
    final l10n = context.l10n;
    final title = conversationTitle(l10n, conversation,
        profiles: showProfileName ? profiles : null);
    // MergeSemantics folds the title, activity time, and unread badge into a
    // single tappable node so a screen reader announces the row once.
    final row = MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(BoneRadii.md),
          child: InkWell(
            onTap: onTap,
            onLongPress: () => onActions(null),
            onSecondaryTapDown: (details) => onActions(details.globalPosition),
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
                      profiles: profiles,
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
                              if (pinned) ...<Widget>[
                                const SizedBox(width: BoneSpacing.xs + 2),
                                Semantics(
                                  label: l10n.chatListPinned,
                                  child: Icon(
                                    Icons.push_pin_outlined,
                                    size: 14,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                              if (muted) ...<Widget>[
                                const SizedBox(width: BoneSpacing.xs + 2),
                                Semantics(
                                  label: l10n.chatListMuted,
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
                                child: _RowSubtitle(
                                  conversation: conversation,
                                  previews: previews,
                                  draftTick: draftTick,
                                ),
                              ),
                              if (retention != null &&
                                  retention > 0) ...<Widget>[
                                const SizedBox(width: BoneSpacing.sm),
                                // Compact on screen, spoken in full: `1d`
                                // should not be read out as "one dee".
                                // Flexible so the pill and the preview
                                // share a narrow 112dp slot at 200% text
                                // instead of overflowing it.
                                Flexible(
                                  child: StatusPill(
                                    icon: Icons.timer_outlined,
                                    label: retentionChipLabel(l10n, retention),
                                    uppercase: false,
                                    semanticsLabel:
                                        l10n.chatListDisappearingAfter(
                                      retentionLabel(l10n, retention),
                                    ),
                                  ),
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
                              formatListTime(context, activityAt),
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
                            _unreadIndicator(l10n, unread),
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
    if (!swipeOpensActions) return row;
    // Swipe either way opens the actions; the row stays (confirmDismiss is
    // false), so nothing is removed by a swipe.
    return Dismissible(
      key: ValueKey<String>('chat-row-${conversation.id}'),
      confirmDismiss: (_) async {
        onActions(null);
        return false;
      },
      background: const SizedBox.shrink(),
      child: row,
    );
  }
}

/// The line under a row's title: unsent draft (when previews are enabled),
/// "sender: first words" of the last message, or the kind line when there is
/// none to quote (U12).
///
/// It selects its own text, so a new message rebuilds this one line and not the
/// list around it (T49C-1), and a change of sender name, block or members is
/// picked up because the text is what is compared.
class _RowSubtitle extends StatelessWidget {
  const _RowSubtitle({
    required this.conversation,
    required this.previews,
    this.draftTick,
  });

  final Conversation conversation;
  final AppState? previews;
  final Listenable? draftTick;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    Widget line(String text, {bool isDraft = false}) => Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: isDraft
              ? style?.copyWith(
                  color: theme.colorScheme.primary,
                  fontStyle: FontStyle.italic,
                )
              : style,
        );
    final state = previews;
    if (state == null) return line(conversationRowSubtitle(l10n, conversation));
    final listenable = draftTick == null
        ? state
        : Listenable.merge(<Listenable>[state, draftTick!]);
    return ListenableSelector<(String?, bool)>(
      listenable: listenable,
      select: () {
        if (state.showChatPreviews) {
          final draft = state.composerDrafts.textFor(conversation.id).trim();
          if (draft.isNotEmpty) {
            return (l10n.chatListDraftPrefix(draft), true);
          }
        }
        return (
          chatPreviewLine(
            l10n,
            state,
            conversation,
            state.chatPreviewFor(conversation.id),
          ),
          false,
        );
      },
      builder: (context, selected, _) => line(
        selected.$1 ?? conversationRowSubtitle(l10n, conversation),
        isDraft: selected.$2,
      ),
    );
  }
}

/// A dot for a single unread message, a count for more.
///
/// The old badge always rendered a number, which gave one message the same
/// weight as thirty. The spoken label is identical either way, so dropping
/// the number changed nothing for a screen reader.
Widget _unreadIndicator(AppLocalizations l10n, int count) {
  final spoken = l10n.chatListUnreadSpoken(count);
  if (count == 1) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: StatusDot(semanticsLabel: spoken),
    );
  }
  return StatusPill(
    label: count > 99
        ? l10n.chatListUnreadOverflow
        : l10n.chatListUnreadCount(count),
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

String conversationTitle(
  AppLocalizations l10n,
  Conversation conversation, {
  ProfileService? profiles,
}) {
  // W11: a name shared by the person or the group comes first. It is never
  // an identity: the account ID stays what a verification names.
  final peer = conversation.peerAccountId;
  final shared = conversation.isDm && peer != null
      ? profiles?.account(peer)?.name
      : conversation.isGroup
          ? profiles?.conversation(conversation.id)?.name
          : null;
  if (shared != null) return shared;
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
    return l10n.newConversationDirect;
  }
  if (conversation.isChannel) {
    return l10n.searchTypeChannel;
  }
  return l10n.conversationGroupChat;
}

String conversationSubtitle(
  AppLocalizations l10n,
  Conversation conversation,
) {
  final retention = conversation.retentionSeconds;
  final parts = <String>[
    if (conversation.isDm) l10n.newConversationDirect,
    if (conversation.isGroup) l10n.conversationPrivateGroup,
    if (conversation.isChannel) l10n.communityChannelSubtitle,
    l10n.conversationEncrypted,
    if (retention != null && retention > 0)
      l10n.conversationDisappearing(retentionLabel(l10n, retention)),
  ];
  return parts.join(' · ');
}

/// Subtitle for a chat-list row.
///
/// Shorter than [conversationSubtitle], which still backs the details screen
/// where the long form belongs: the row hands retention to its own chip, and
/// a DM drops the kind entirely because the title already names the person.
String conversationRowSubtitle(
  AppLocalizations l10n,
  Conversation conversation,
) {
  final parts = <String>[
    if (conversation.isGroup) l10n.conversationPrivateGroup,
    if (conversation.isChannel) l10n.communityChannelSubtitle,
    l10n.conversationEncrypted,
  ];
  return parts.join(' · ');
}

/// Avatar for a conversation row: initials for a DM or a named group or
/// channel, otherwise the kind icon. A photo replaces it. Decorative in every
/// case — the title carries the identity.
///
/// The colour is derived from the peer's account ID where there is one, so the
/// same contact is the same colour everywhere, and from the conversation ID
/// otherwise. See `ui/avatar.dart` for the six hues.
Widget conversationAvatar(
  BuildContext context,
  Conversation conversation, {
  double radius = 24,
  bool hero = false,
  ProfileService? profiles,
}) {
  final peerId = conversation.peerAccountId;
  final colors = avatarColorsFor(context, peerId ?? conversation.id);
  final photo = conversation.isDm && peerId != null
      ? profiles?.account(peerId)?.photoPng
      : conversation.isGroup
          ? profiles?.conversation(conversation.id)?.photoPng
          : null;
  // Initials always show on the default avatar (U39): a person's from their
  // username, a named group's or channel's from its name.
  final initials = conversation.isDm && peerId != null
      ? accountInitials(peerId, conversation.peerUsername)
      : nameInitials(conversation.isGroup
          ? profiles?.conversation(conversation.id)?.name ?? conversation.title
          : conversation.title);
  final initial = ExcludeSemantics(
    child: Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.fill,
        shape: BoxShape.circle,
        border: Border.all(color: colors.ring),
      ),
      child: initials != null
          ? Text(
              initials,
              style: TextStyle(
                // Never under 12: the top-bar avatar is small (radius 17).
                fontSize: radius * 0.62 < 12 ? 12 : radius * 0.62,
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
  final avatar = photo == null
      ? initial
      : PhotoAvatar(png: photo, radius: radius, fallback: initial);
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

String retentionLabel(AppLocalizations l10n, int seconds) {
  if (seconds >= 86400 && seconds % 86400 == 0) {
    return l10n.durationDays(seconds ~/ 86400);
  }
  if (seconds >= 3600 && seconds % 3600 == 0) {
    return l10n.durationHours(seconds ~/ 3600);
  }
  final minutes = (seconds / 60).ceil();
  return l10n.durationMinutes(minutes < 1 ? 1 : minutes);
}

/// Compact form of [retentionLabel] for the row chip: `30m`, `24h`, `7d`.
String retentionChipLabel(AppLocalizations l10n, int seconds) {
  if (seconds >= 86400 && seconds % 86400 == 0) {
    return l10n.durationChipDays(seconds ~/ 86400);
  }
  if (seconds >= 3600 && seconds % 3600 == 0) {
    return l10n.durationChipHours(seconds ~/ 3600);
  }
  final minutes = (seconds / 60).ceil();
  return l10n.durationChipMinutes(minutes < 1 ? 1 : minutes);
}
