import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, listEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart'
    show kPrimaryButton, kSecondaryMouseButton;
import 'package:flutter/services.dart';

import '../../calls/call_controller.dart';
import '../../calls/room/room_engine.dart' show RoomCall, RoomSession;
import '../../core/app_state.dart';
import '../../core/attachments.dart';
import '../../core/composer_drafts.dart';
import '../../core/message_history.dart';
import '../../core/models.dart';
import '../../core/profile_service.dart';
import '../../crypto/app_payload.dart' show maxAppTextLength;
import '../../crypto/poll.dart' show PollView, parsePollBody;
import '../../crypto/c7_import.dart' show c7HiddenAttachmentBody;
import '../../crypto/link_preview.dart';
import '../../crypto/message_format.dart'
    show decodeDecoration, unapprovedSenderKeyPrefix;
import '../../storage/encrypted_database.dart'
    show C7FormerMark, LocalMessage, LocalMessageKind, LocalMessageState;
import '../../l10n/l10n.dart';
import '../../sync/sync_recovery.dart' show SyncRecoveryChoice;
import '../../ui/format.dart';
import '../../ui/motion.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/account_recovery_banner.dart';
import '../../ui/widgets/bar_action.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/gated_explanation.dart';
import '../../ui/widgets/listenable_selector.dart';
import '../../ui/widgets/status_pill.dart';
import '../calls/room_screen.dart';
import '../search/search_screen.dart';
import 'approval_hold_banners.dart';
import 'attachment_views.dart';
import 'chat_desktop.dart';
import 'formatted_message.dart';
import 'link_preview_card.dart';
import 'chat_list_screen.dart';
import 'composer_attachments.dart';
import 'conversation_details_screen.dart';
import 'emoji_picker.dart';
import 'message_request_screen.dart';
import 'message_ticks.dart';
import 'poll_widgets.dart';
import 'sender_colors.dart';
import '../reports/report_message_screen.dart';
import 'typing_line.dart';
import 'voice_notes.dart';
import 'voice_recorder.dart';
import '../../core/receipts_state.dart' show MessageTick;

/// Conversation detail screen. Pushed from the chat list, or the detail pane
/// of the wide layout. It listens to the app state itself, and rebuilds only
/// when something it shows changes (T49C-1).
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.state,
    required this.conversationId,
    this.showBackButton = true,
    this.initialMessageKey,
    super.key,
  });

  final AppState state;
  final String conversationId;

  /// The local key of a message to scroll to and highlight when the screen
  /// opens, for a search result (W10). Ignored when this device no longer
  /// holds it.
  final String? initialMessageKey;

  /// False when the screen is the detail pane of the wide master-detail
  /// layout, where there is no route to pop back to.
  final bool showBackButton;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // The draft and reply target live in [AppState.composerDrafts], which
  // outlives this screen: switching destinations in the wide layout, or
  // between conversations, disposes it (T49C-4).
  late final TextEditingController composer =
      TextEditingController.fromValue(_draftValue(widget.conversationId));
  final scroll = ScrollController();

  /// Files waiting to be sent from this conversation (W9, B4).
  final _attachments = ComposerAttachments();

  /// Records a voice note into [_attachments] (B1).
  late final VoiceRecorderController _voice = VoiceRecorderController(
    backend: RecordPluginBackend(),
    newFile: newVoiceNotePath,
    onAutoStop: (file) {
      if (mounted) unawaited(_addVoiceNote(file));
    },
  );

  /// The key of the message the next send replies to, if any. The message
  /// itself is read from the current history ([_replyTarget]), never kept.
  late String? _replyingTo = _drafts.replyTargetFor(widget.conversationId);

  ComposerDrafts get _drafts => widget.state.composerDrafts;

  /// True once the reader has scrolled far enough back that the newest
  /// messages are off screen.
  bool _awayFromLatest = false;

  /// Scroll distance from the newest message beyond which "Jump to latest"
  /// appears.
  static const double _awayThreshold = 480;

  /// Active pinned message index in the compact 1-row pinned bar.
  int _pinIndex = 0;

  /// Unread count captured when opening this conversation, used to place the
  /// subtle "New messages" divider before mark-read clears the server counter.
  int _initialUnreadCount = 0;

  // Jump to a search result (W10).
  final GlobalKey _jumpTarget = GlobalKey();
  late String? _jumpKey = widget.initialMessageKey;
  String? _highlightKey;
  bool _jumping = false;
  Timer? _highlightTimer;

  int _unreadCountFor(String conversationId) =>
      widget.state.conversations
          .where((item) => item.id == conversationId)
          .firstOrNull
          ?.unreadCount ??
      0;

  @override
  void initState() {
    super.initState();
    _initialUnreadCount = _unreadCountFor(widget.conversationId);
    widget.state.enterChatView();
    composer.addListener(_saveDraft);
    _lastTypedText = composer.text;
    composer.addListener(_noticeTyping);
    scroll.addListener(_maybeLoadOlder);
    scroll.addListener(_trackLatest);
    _scheduleJump();
    unawaited(widget.state.refreshApprovalHoldSummary(widget.conversationId));
  }

  void _scheduleJump() {
    if (_jumpKey == null || _jumping) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _runJump());
  }

  /// Where the message is in the reversed list, or null when it is not in
  /// what the chat shows (yet).
  int? _jumpIndex(String key) {
    final history = widget.state.historyFor(widget.conversationId);
    final shown = widget.state
        .timelineFor(widget.conversationId)
        .where((message) => !history.hides(message))
        .toList(growable: false);
    final at = shown.indexWhere((message) =>
        ConversationHistory.keyOf(
            message.senderDeviceId, message.idempotencyKey) ==
        key);
    return at < 0
        ? null
        : widget.state.pendingFor(widget.conversationId).length + at;
  }

  /// Scrolls until the message is built, then centres it. Rows have no fixed
  /// height, so this starts near the top and walks back in time a screen at
  /// a time: no row is shorter than [_minRowExtent], so the start is never
  /// past the message.
  Future<void> _runJump() async {
    final key = _jumpKey;
    if (key == null || _jumping || !mounted) return;
    final index = _jumpIndex(key);
    if (index == null) {
      // Still loading: wait for the next change. Once loading is over the
      // message is not held any more (expired, say), so stay put.
      if (!widget.state.isLoadingMessages(widget.conversationId)) {
        _jumpKey = null;
      }
      return;
    }
    _jumping = true;
    try {
      var offset = index * _minRowExtent;
      for (var step = 0; step < 400; step++) {
        if (!mounted || !scroll.hasClients) return;
        final target = _jumpTarget.currentContext;
        if (target != null) {
          await Scrollable.ensureVisible(target, alignment: 0.4);
          if (!mounted) return;
          setState(() => _highlightKey = key);
          _highlightTimer?.cancel();
          _highlightTimer = Timer(const Duration(seconds: 2), () {
            if (mounted) setState(() => _highlightKey = null);
          });
          return;
        }
        final position = scroll.position;
        final extentBefore = position.maxScrollExtent;
        if (offset > extentBefore) {
          offset = extentBefore;
        }
        scroll.jumpTo(offset);
        await WidgetsBinding.instance.endOfFrame;
        // The screen may have been left, or the list replaced, while the
        // frame was pending; the controller is then disposed or detached.
        if (!mounted || !scroll.hasClients) return;
        if (_jumpTarget.currentContext == null) {
          final after = scroll.position;
          if (offset >= after.maxScrollExtent &&
              after.maxScrollExtent == extentBefore) {
            return;
          }
          offset += after.viewportDimension * 0.8;
        }
      }
    } finally {
      _jumping = false;
      _jumpKey = null;
    }
  }

  static const double _minRowExtent = 40;

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) {
      oldWidget.state.leaveChatView();
      widget.state.enterChatView();
    }
    if (oldWidget.conversationId == widget.conversationId &&
        identical(oldWidget.state, widget.state)) {
      return;
    }
    // The same screen now shows another conversation: its own draft, never
    // the previous one's. The previous draft is already saved.
    composer.removeListener(_saveDraft);
    composer.removeListener(_noticeTyping);
    composer.value = _draftValue(widget.conversationId);
    _lastTypedText = composer.text;
    composer.addListener(_saveDraft);
    composer.addListener(_noticeTyping);
    _replyingTo = _drafts.replyTargetFor(widget.conversationId);
    _pinIndex = 0;
    _initialUnreadCount = _unreadCountFor(widget.conversationId);
    unawaited(_attachments.clear());
    unawaited(widget.state.refreshApprovalHoldSummary(widget.conversationId));
  }

  @override
  void dispose() {
    widget.state.leaveChatView();
    _highlightTimer?.cancel();
    composer.removeListener(_saveDraft);
    composer.removeListener(_noticeTyping);
    scroll.removeListener(_trackLatest);
    scroll.removeListener(_maybeLoadOlder);
    scroll.dispose();
    composer.dispose();
    unawaited(_attachments.clear());
    _attachments.dispose();
    _voice.dispose();
    super.dispose();
  }

  TextEditingValue _draftValue(String conversationId) {
    final text = widget.state.composerDrafts.textFor(conversationId);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _saveDraft() => _drafts.setText(widget.conversationId, composer.text);

  /// The text as of the last typing check, so a cursor move or a draft being
  /// restored is not taken for typing.
  String _lastTypedText = '';

  /// Tells the others you are typing (W5), once the text really changed and
  /// is not empty. [AppState.notifyTyping] throttles and gates by size.
  void _noticeTyping() {
    final text = composer.text;
    if (text == _lastTypedText) return;
    _lastTypedText = text;
    if (text.isNotEmpty) widget.state.notifyTyping(widget.conversationId);
  }

  void _setReplyTarget(String? messageKey) {
    _drafts.setReplyTarget(widget.conversationId, messageKey);
    setState(() => _replyingTo = messageKey);
  }

  /// The reply target as the history has it now, so an edit shows. A target
  /// that was deleted, or is no longer in the history, is dropped: the next
  /// send is then an ordinary message. Safe during build: the drafts are not
  /// listenable, and the caller draws no reply bar for it.
  LocalMessage? _replyTarget() {
    final key = _replyingTo;
    if (key == null) return null;
    final target = widget.state.historyFor(widget.conversationId).forKey(key);
    if (target != null && target.deletedAt == null) return target;
    _drafts.setReplyTarget(widget.conversationId, null);
    _replyingTo = null;
    return null;
  }

  /// The list is reversed, so scrolling back in time approaches maxScrollExtent.
  /// Requesting the next page slightly before the edge keeps the loader from
  /// appearing as a hard stop. [AppState.loadOlderMessages] is idempotent, so
  /// repeated scroll callbacks are harmless.
  void _maybeLoadOlder() {
    if (!scroll.hasClients || !scroll.position.hasContentDimensions) {
      return;
    }
    final remaining = scroll.position.maxScrollExtent - scroll.position.pixels;
    if (remaining < 400) {
      unawaited(widget.state.loadOlderMessages(widget.conversationId));
    }
  }

  void _trackLatest() {
    if (!scroll.hasClients) return;
    final away = scroll.position.pixels > _awayThreshold;
    if (away != _awayFromLatest) setState(() => _awayFromLatest = away);
  }

  /// Returns to the newest message. The list is reversed, so that is offset
  /// zero. Only the scroll position moves: the pages of older history already
  /// loaded stay in memory, so scrolling back up again does not refetch them.
  Future<void> _jumpToLatest() async {
    if (!scroll.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      scroll.jumpTo(0);
      return;
    }
    await scroll.animateTo(
      0,
      duration: BoneDurations.standard,
      curve: BoneDurations.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableSelector<List<Object?>>(
      listenable: widget.state,
      select: () => _chatScreenSelection(widget.state, widget.conversationId),
      equals: listEquals,
      builder: (context, _, __) {
        final theme = Theme.of(context);
        final conversation = widget.state.conversations
            .where((item) => item.id == widget.conversationId)
            .firstOrNull;
        // A request shows its own screen, whichever way it was opened (list,
        // search, the wide pane). Accepting rebuilds into the chat.
        if (conversation != null &&
            widget.state.requestBucket(conversation) != RequestBucket.chat) {
          return MessageRequestScreen(
            state: widget.state,
            conversation: conversation,
            popOnResult: widget.showBackButton,
          );
        }
        final messages = widget.state.timelineFor(widget.conversationId);
        final pending = widget.state.pendingFor(widget.conversationId);
        // K0 step 8: history only, with a notice in place of the composer.
        final readOnly = conversation != null &&
            widget.state.readOnlyWithoutPeer(conversation.id);
        final restricted = conversation != null &&
            !widget.state.mayPost(conversation.id,
                channelId: widget.state.selectedChannelFor(conversation.id));
        final replyTarget = (readOnly || restricted) ? null : _replyTarget();
        if (_jumpKey != null) _scheduleJump();
        return ChatShortcuts(
          onEscape: _onEscape,
          onSearch: _openSearch,
          child: Focus(
            autofocus: true,
            child: Scaffold(
              appBar: AppBar(
                automaticallyImplyLeading: widget.showBackButton,
                titleSpacing: widget.showBackButton ? 0 : BoneSpacing.gutter,
                title: conversation == null
                    ? Text(context.l10n.searchTypeConversation)
                    // U29: the name opens the details, so it is the one big
                    // tap target of the bar. Star and info sit in the menu.
                    : InkWell(
                        key: const Key('chat-title'),
                        borderRadius: BorderRadius.circular(BoneRadii.sm),
                        onTap: () => _openDetails(conversation.id),
                        child: Row(
                          children: <Widget>[
                            conversationAvatar(
                              context,
                              conversation,
                              profiles: widget.state.profiles,
                              radius: 17,
                              // Only the pushed layout: see conversationAvatar.
                              hero: widget.showBackButton,
                            ),
                            const SizedBox(width: BoneSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(
                                    conversationTitle(
                                        context.l10n, conversation,
                                        profiles: widget.state.profiles),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  // Every chat is encrypted, and the chat's
                                  // first line says so once (U13); the header
                                  // names only a state that is not the default.
                                  if (widget.state.isMuted(conversation.id))
                                    Text(
                                      context.l10n.chatStatusMuted,
                                      style: theme.textTheme.labelSmall,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                actions: <Widget>[
                  if (conversation != null && conversation.isDm && !readOnly)
                    ValueListenableBuilder<CallController?>(
                      valueListenable: widget.state.callController,
                      builder: (context, calls, _) => calls == null
                          ? const SizedBox.shrink()
                          : ListenableBuilder(
                              listenable: calls,
                              builder: (context, _) => Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  BarAction(
                                      key: const Key('chat-call-voice'),
                                      label: context.l10n.callStartVoice,
                                      onPressed: calls.busy
                                          ? null
                                          : () => unawaited(
                                              calls.start(conversation.id)),
                                      icon: Icons.call_outlined),
                                  BarAction(
                                      key: const Key('chat-call-video'),
                                      label: context.l10n.callStartVideo,
                                      onPressed: calls.busy
                                          ? null
                                          : () => unawaited(calls.start(
                                              conversation.id,
                                              withVideo: true)),
                                      icon: Icons.videocam_outlined),
                                ],
                              ),
                            ),
                    ),
                  if (conversation != null && !conversation.isDm && !readOnly)
                    ValueListenableBuilder<RoomSession?>(
                      valueListenable: widget.state.roomSession,
                      builder: (context, session, _) => session == null
                          ? const SizedBox.shrink()
                          : IconButton(
                              key: const Key('chat-call-group'),
                              tooltip: context.l10n.roomStart,
                              onPressed: () => unawaited(
                                  _openRoom(session, conversation.id)),
                              icon: const Icon(Icons.groups_outlined)),
                    ),
                  // Starred messages and the details page: two rarely used
                  // actions behind one menu (U29).
                  PopupMenuButton<String>(
                    key: const Key('chat-menu'),
                    onSelected: (value) {
                      if (value == 'starred') {
                        _showStarredMessages();
                      } else if (conversation != null) {
                        _openDetails(conversation.id);
                      }
                    },
                    itemBuilder: (context) => <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'starred',
                        child: Text(context.l10n.w8StarredMessages),
                      ),
                      if (conversation != null)
                        PopupMenuItem<String>(
                          value: 'details',
                          child: Text(context.l10n.chatListDetails),
                        ),
                    ],
                  ),
                ],
              ),
              body: ChatDropZone(
                enabled: conversation != null &&
                    !readOnly &&
                    !restricted &&
                    widget.state.attachmentsAvailable,
                onFiles: _addFiles,
                child: Column(
                  children: <Widget>[
                    // U37: the account notices (a recovery waiting, a leaked
                    // password, a passkey change) also show inside an open
                    // chat, unfolded as in the shell. In the wide layout the
                    // shell's own banners are already on screen, so only a
                    // pushed chat adds them.
                    if (widget.showBackButton) ...<Widget>[
                      RecoveryAttemptCard(state: widget.state),
                      PasswordLeakBanner(state: widget.state),
                      PasskeyNoticeBanner(state: widget.state),
                    ],
                    if (widget.state.pinsFor(widget.conversationId).isNotEmpty)
                      _buildPinnedBar(context),
                    Expanded(
                      child: conversation == null
                          ? EmptyState(
                              icon: Icons.forum_outlined,
                              title: context.l10n.shellNoConversationTitle,
                              message: context.l10n.chatNoConversationMessage,
                            )
                          : _messagesPane(conversation.id, messages, pending),
                    ),
                    if (readOnly)
                      const _NoPeerReadOnlyNotice()
                    else if (conversation != null &&
                        widget.state.conversationSyncPaused(conversation.id))
                      _SyncPausedNotice(
                        state: widget.state,
                        conversationId: conversation.id,
                      )
                    else if (conversation != null &&
                        widget.state.mlsConversationFailed(conversation.id))
                      _PausedConversationNotice(
                        state: widget.state,
                        conversationId: conversation.id,
                      )
                    else if (conversation != null &&
                        widget.state.sendHeldForRemoval(conversation.id))
                      const _RemovalHoldNotice(),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: BoneSpacing.maxChatWidth,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            TypingLine(
                              state: widget.state,
                              conversationId: widget.conversationId,
                            ),
                            if (!readOnly &&
                                !restricted &&
                                conversation != null &&
                                !conversation.isDm)
                              _MentionSuggestions(
                                controller: composer,
                                members:
                                    widget.state.membersFor(conversation.id),
                                ownAccountId: widget.state.session?.accountId,
                                profiles: widget.state.profiles,
                              ),
                            if (replyTarget != null)
                              _ReplyBar(
                                preview:
                                    quotedPreview(context.l10n, replyTarget),
                                onCancel: () => _setReplyTarget(null),
                              ),
                            if (!readOnly &&
                                !restricted &&
                                widget.state.attachmentsAvailable)
                              AttachmentTray(tray: _attachments),
                            if (!readOnly &&
                                !restricted &&
                                widget.state.attachmentsAvailable)
                              VoiceRecorderBar(
                                controller: _voice,
                                onStop: _stopVoiceNote,
                              ),
                            if (!readOnly)
                              _Composer(
                                enabled: conversation != null && !restricted,
                                restricted: restricted,
                                controller: composer,
                                // Scoped to the send operation: an unrelated background task
                                // no longer disables the composer.
                                // A send held for a member's removal (D68) is still
                                // pending: no second send of the same text meanwhile.
                                busy: widget.state.isBusy(Ops.send) ||
                                    widget.state.sendHeldForRemoval(
                                      widget.conversationId,
                                    ),
                                onSend: _send,
                                onEmoji: conversation != null && !restricted
                                    ? _insertEmoji
                                    : null,
                                attaching: widget.state.isBusy(Ops.attachment),
                                onAttach: !restricted &&
                                        widget.state.attachmentsAvailable
                                    ? () => pickAttachmentFiles(
                                          context,
                                          widget.state,
                                          _attachments,
                                        )
                                    : null,
                                onPasteFiles: !restricted &&
                                        widget.state.attachmentsAvailable
                                    ? _pasteFiles
                                    : null,
                                onVoice: !restricted &&
                                        widget.state.attachmentsAvailable
                                    ? _startVoiceNote
                                    : null,
                                voiceListenable: _voice,
                                onEditLast: !restricted &&
                                        widget.state.messageActionsAvailable
                                    ? _editLast
                                    : null,
                                onPoll: !restricted &&
                                        widget.state.messageActionsAvailable
                                    ? _createPoll
                                    : null,
                                tray: _attachments,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _openDetails(String conversationId) {
    Navigator.of(context).push(
      sharedAxisRoute<void>(
        (_) => ConversationDetailsScreen(
          state: widget.state,
          conversationId: conversationId,
        ),
      ),
    );
  }

  /// Esc: first drops a reply in progress, then leaves the chat when it is
  /// a pushed screen (the wide layout's detail pane has nowhere to go).
  void _onEscape() {
    if (_replyingTo != null) {
      _setReplyTarget(null);
    } else if (widget.showBackButton) {
      Navigator.of(context).maybePop();
    }
  }

  /// Ctrl+F: the search screen, scoped to this chat by default.
  void _openSearch() {
    Navigator.of(context).push(
      sharedAxisRoute<void>(
        (_) => SearchScreen(
          state: widget.state,
          conversationId: widget.conversationId,
        ),
      ),
    );
  }

  void _jumpToMessage(String messageKey) {
    setState(() => _jumpKey = messageKey);
    _scheduleJump();
  }

  Widget _buildPinnedBar(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pins = widget.state.pinsFor(widget.conversationId);
    final activeIndex = _pinIndex % pins.length;
    final activePin = pins[activeIndex];
    final history = widget.state.historyFor(widget.conversationId);
    final preview =
        quotedPreview(context.l10n, history.forKey(activePin.targetKey));

    return Material(
      key: const ValueKey('pin-bar'),
      color: scheme.surfaceContainerLow,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: BoneColors.hairline(theme.brightness)),
          ),
        ),
        child: InkWell(
          onTap: () {
            _jumpToMessage(activePin.targetKey);
            if (pins.length > 1) {
              setState(() => _pinIndex = (activeIndex + 1) % pins.length);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: BoneSpacing.gutter,
              vertical: BoneSpacing.sm,
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.push_pin_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: BoneSpacing.sm),
                Expanded(
                  child: Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (pins.length > 1) ...<Widget>[
                  const SizedBox(width: BoneSpacing.sm),
                  TextButton(
                    key: const Key('pin-bar-all'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: BoneSpacing.sm,
                      ),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _showAllPinnedMessages,
                    child: Text(
                      context.l10n
                          .chatPinnedCount(activeIndex + 1, pins.length),
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

  Future<void> _showAllPinnedMessages() async {
    final pins = widget.state.pinsFor(widget.conversationId);
    final history = widget.state.historyFor(widget.conversationId);
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            ListTile(
              title: Text(
                context.l10n.chatPinnedMessagesTitle,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final pin in pins)
              ListTile(
                leading: const Icon(Icons.push_pin_outlined, size: 18),
                title: Text(
                  quotedPreview(context.l10n, history.forKey(pin.targetKey)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(sheetContext).pop(pin.targetKey),
              ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      _jumpToMessage(selected);
    }
  }

  Future<void> _insertEmoji() async {
    final picked = await showEmojiPicker(context);
    if (picked == null || !mounted) return;
    final value = composer.value;
    final selection = value.selection;
    final text = value.text;
    final start = selection.isValid && selection.start >= 0
        ? selection.start
        : text.length;
    final end =
        selection.isValid && selection.end >= 0 ? selection.end : text.length;
    final updated = text.replaceRange(start, end, picked);
    composer.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + picked.length),
    );
  }

  Future<void> _toggleReaction(LocalMessage message, String reaction) async {
    final state = widget.state;
    final conversationId = widget.conversationId;
    if (state.readOnlyWithoutPeer(conversationId)) return;
    final ownAccountId = state.session?.accountId;
    final alreadyMine = state
        .historyFor(conversationId)
        .reactionsFor(message.key, ownAccountId: ownAccountId)
        .any((item) => item.reaction == reaction && item.mine);
    final sent = await state.react(
      conversationId,
      message.key,
      alreadyMine ? '' : reaction,
    );
    if (!sent && mounted) {
      final error = state.errorFor(Ops.send);
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
      }
    }
  }

  Future<void> _addFiles(List<XFile> files, {Set<String>? temporary}) =>
      addAttachmentFiles(context, widget.state, _attachments, files,
          temporaryPaths: temporary ?? const <String>{});

  Future<void> _startVoiceNote() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final result = await _voice.start();
    if (result == VoiceStartResult.started) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(result == VoiceStartResult.permissionDenied
            ? l10n.voiceNotePermissionDenied
            : l10n.voiceNoteRecordFailed),
      ));
  }

  Future<void> _stopVoiceNote() async {
    final file = await _voice.finish();
    if (file != null && mounted) await _addVoiceNote(file);
  }

  /// The finished recording waits on the tray; Send encrypts and uploads it
  /// like any other file.
  Future<void> _addVoiceNote(XFile file) =>
      _addFiles(<XFile>[file], temporary: <String>{file.path});

  /// Ctrl+V with files or an image on the clipboard; false means the
  /// clipboard held neither and the text paste goes ahead.
  Future<bool> _pasteFiles() async {
    final clipboard = await readClipboardFiles();
    if (clipboard.files.isEmpty || !mounted) return false;
    await _addFiles(clipboard.files, temporary: clipboard.temporary);
    return true;
  }

  /// Asks for a question and options, then sends them as a poll (B3).
  Future<void> _createPoll() async {
    final draft = await showPollComposer(context);
    if (draft == null || !mounted) return;
    await widget.state.sendPoll(widget.conversationId,
        question: draft.question,
        options: draft.options,
        multipleChoice: draft.multipleChoice);
  }

  /// Up in an empty composer edits your newest message, as in other chats.
  Future<void> _editLast() async {
    final state = widget.state;
    final history = state.historyFor(widget.conversationId);
    final ownAccountId = state.session?.accountId;
    for (final envelope in state.timelineFor(widget.conversationId)) {
      final local = history.forEnvelope(envelope);
      if (local == null ||
          local.kind != LocalMessageKind.text ||
          local.deletedAt != null ||
          local.senderAccountId != ownAccountId) {
        continue;
      }
      await _editMessage(local);
      return;
    }
  }

  /// A member's display name, as message senders are labelled. Server-
  /// supplied metadata, not a verified identity claim.
  String _memberName(String conversationId, String accountId) {
    final state = widget.state;
    final member = state
        .membersFor(conversationId)
        .where((item) => item.accountId == accountId)
        .firstOrNull;
    return state.profiles?.account(accountId)?.name ??
        accountLabel(accountId, member?.username);
  }

  bool _isDm(String conversationId) =>
      widget.state.conversations
          .where((item) => item.id == conversationId)
          .firstOrNull
          ?.isDm ??
      false;

  /// Message area for the selected conversation. Failures get an explicit
  /// error + retry instead of masquerading as "No messages yet".
  Widget _messagesPane(
    String conversationId,
    List<ReceivedMessageEnvelope> messages,
    List<MessageEnvelope> pending,
  ) {
    final loading = widget.state.isLoadingMessages(conversationId);
    final loadError = widget.state.messageLoadError(conversationId);
    // C3 (D115): a removal left this private channel's key due for renewal,
    // and no owner or admin is in the channel to renew it. Moderators never
    // do; until an admin joins, its info cannot be edited.
    final renewalStuck = widget.state.channelKeyRenewalStuck(conversationId);
    final renewalBanner = renewalStuck
        ? MaterialBanner(
            key: const ValueKey<String>('channel-key-renewal-no-admin'),
            content: Text(context.l10n.chatKeyRenewalNoAdmin),
            leading: const Icon(Icons.key_off_outlined),
            actions: const <Widget>[SizedBox.shrink()],
          )
        : null;
    // L1 (D94): which account's devices hold this chat, and what to do.
    final holdBanners = ApprovalHoldBanners(
      state: widget.state,
      conversationId: conversationId,
      memberName: (accountId) => _memberName(conversationId, accountId),
    );
    if (messages.isEmpty && pending.isEmpty) {
      final Widget empty;
      if (loading) {
        empty = const Center(child: CircularProgressIndicator());
      } else if (loadError != null) {
        empty = _MessageLoadError(
          message: loadError,
          onRetry: () => widget.state.loadMessages(conversationId),
        );
      } else {
        empty = EmptyState(
          icon: Icons.lock_outline,
          title: context.l10n.chatEmptyTitle,
          // The empty chat's own notice that it is encrypted (U13, U36).
          message: _isDm(conversationId)
              ? context.l10n.chatEmptyMessageDm
              : context.l10n.chatEmptyMessageGroup,
        );
      }
      return Column(children: <Widget>[
        if (renewalBanner != null) renewalBanner,
        holdBanners,
        Expanded(child: empty),
      ]);
    }
    final notJoined = widget.state.incompleteJoinAccounts(conversationId);
    return Column(
      children: <Widget>[
        if (renewalBanner != null) renewalBanner,
        holdBanners,
        // L1: an approved device of a member has stayed out of the group
        // for an hour (the server gave no key package, or kept it out).
        for (final accountId in notJoined)
          MaterialBanner(
            content: Text(context.l10n
                .chatDevicesNotJoined(_memberName(conversationId, accountId))),
            leading: const Icon(Icons.devices_other_outlined),
            actions: const <Widget>[SizedBox.shrink()],
          ),
        if (loadError != null)
          MaterialBanner(
            content: Text(loadError),
            leading: const Icon(Icons.error_outline),
            actions: <Widget>[
              TextButton(
                onPressed: () => widget.state.loadMessages(conversationId),
                child: Text(context.l10n.commonRetry),
              ),
            ],
          ),
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: _MessageList(
                  state: widget.state,
                  conversationId: conversationId,
                  controller: scroll,
                  messages: messages,
                  pending: pending,
                  jumpTarget: _jumpTarget,
                  jumpKey: _jumpKey ?? _highlightKey,
                  highlighted: _highlightKey != null,
                  unreadDividerCount: _initialUnreadCount,
                  onJumpToMessage: _jumpToMessage,
                  onReplyToMessage: widget.state.messageActionsAvailable &&
                          !widget.state.readOnlyWithoutPeer(conversationId) &&
                          widget.state.mayPost(
                            conversationId,
                            channelId:
                                widget.state.selectedChannelFor(conversationId),
                          )
                      ? (message) => _setReplyTarget(message.key)
                      : null,
                  onToggleReaction: widget.state.messageActionsAvailable &&
                          !widget.state.readOnlyWithoutPeer(conversationId)
                      ? _toggleReaction
                      : null,
                  onMessageActions: widget.state.messageActionsAvailable
                      ? _showMessageActions
                      : null,
                ),
              ),
              if (_awayFromLatest)
                Positioned(
                  right: BoneSpacing.gutter,
                  bottom: BoneSpacing.md,
                  child: FloatingActionButton.small(
                    // The wide layout also shows the chat list's FAB; two
                    // default hero tags on one route is an assertion.
                    heroTag: null,
                    tooltip: context.l10n.chatJumpToLatest,
                    onPressed: _jumpToLatest,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHigh,
                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                    child: const Icon(Icons.arrow_downward),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Long-press on mobile, right-click on desktop.
  /// B6: opens the group-call screen and joins the room of this chat. The
  /// engine lives only as long as the screen.
  Future<void> _openRoom(RoomSession session, String conversationId) async {
    final RoomCall call;
    try {
      call = await session.openCall(conversationId);
    } catch (_) {
      if (!mounted) return;
      // No call without frame encryption (B6, fail closed).
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.roomFailedCryptor)));
      return;
    }
    if (!mounted) {
      await call.close();
      return;
    }
    final engine = call.engine;
    final route = sharedAxisRoute<void>(
      (_) => RoomScreen(
        engine: engine,
        nameFor: session.nameFor,
        controls: call.controls,
      ),
    );
    final done = Navigator.of(context).push(route);
    unawaited(engine.join(conversationId));
    await done;
    await call.close();
  }

  Future<void> _showStarredMessages() async {
    final state = widget.state;
    final selected = await showModalBottomSheet<String>(
        context: context,
        builder: (sheetContext) => SafeArea(
                child: ListView(shrinkWrap: true, children: [
              ListTile(title: Text(context.l10n.w8StarredMessages)),
              for (final message
                  in state.historyFor(widget.conversationId).messages)
                if (state.starredMessages.contains(message.key) &&
                    message.hiddenAt == null &&
                    message.deletedAt == null)
                  ListTile(
                      leading: const Icon(Icons.star),
                      title: Text(quotedPreview(context.l10n, message)),
                      onTap: () => Navigator.pop(sheetContext, message.key)),
            ])));
    if (selected != null && mounted) {
      setState(() => _jumpKey = selected);
      _scheduleJump();
    }
  }

  /// Long-press on mobile, right-click on desktop.
  Future<void> _showMessageActions(
    LocalMessage message,
    bool mine, {
    Offset? anchor,
  }) async {
    final state = widget.state;
    final conversationId = widget.conversationId;
    final l10n = context.l10n;
    final actionable = message.deletedAt == null &&
        const [LocalMessageKind.text, LocalMessageKind.attachment]
            .contains(message.kind);
    // K0 step 8: in a read-only conversation only what stays on this device
    // (copy, forward elsewhere, star, hide) is offered.
    final sendable = !state.readOnlyWithoutPeer(conversationId);
    final mayPost = state.mayPost(conversationId,
        channelId: state.selectedChannelFor(conversationId));
    final starred = state.starredMessages.contains(message.key);
    final canDeleteKind = const [
      LocalMessageKind.text,
      LocalMessageKind.attachment,
      LocalMessageKind.unsupported,
      LocalMessageKind.poll,
    ].contains(message.kind);
    final canModDelete = !mine &&
        sendable &&
        state.mayModerateMessage(conversationId, message.senderAccountId) &&
        canDeleteKind &&
        message.deletedAt == null;

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
      PopupMenuItem<String> item(
        String value,
        IconData icon,
        String label, {
        Key? key,
      }) =>
          PopupMenuItem<String>(
            key: key,
            value: value,
            child: Row(
              children: <Widget>[
                Icon(icon, size: 18),
                const SizedBox(width: BoneSpacing.md),
                Text(label),
              ],
            ),
          );
      action = await showMenu<String>(
        context: context,
        position: rect,
        items: <PopupMenuEntry<String>>[
          if (actionable && sendable)
            PopupMenuItem<String>(
              enabled: false,
              padding: const EdgeInsets.symmetric(horizontal: BoneSpacing.sm),
              child: Builder(
                builder: (menuContext) => Wrap(
                  spacing: 2,
                  children: <Widget>[
                    for (final reaction in quickReactions)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: l10n.chatReact(reaction),
                        onPressed: () =>
                            Navigator.of(menuContext).pop('react:$reaction'),
                        icon: Text(
                          reaction,
                          style: const TextStyle(fontSize: 18),
                        ),
                      ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: l10n.chatMoreReactions,
                      onPressed: () => Navigator.of(menuContext).pop('react:'),
                      icon: const Icon(Icons.add_reaction_outlined, size: 18),
                    ),
                  ],
                ),
              ),
            ),
          if (actionable && sendable) const PopupMenuDivider(),
          if (actionable && sendable && mayPost)
            item('reply', Icons.reply, l10n.chatReply),
          if (actionable && message.kind == LocalMessageKind.text)
            item('copy', Icons.copy, l10n.chatCopyText),
          if (actionable && message.kind == LocalMessageKind.text)
            item('select', Icons.text_fields, l10n.chatSelectText),
          if (actionable)
            item('forward', Icons.forward_outlined, l10n.w8Forward),
          item(
            'star',
            starred ? Icons.star : Icons.star_outline,
            starred ? l10n.w8Unstar : l10n.w8Star,
          ),
          item('hide', Icons.hide_source, l10n.w8DeleteForMe),
          if (actionable && !mine && state.reportsAvailable)
            item('report', Icons.flag_outlined, l10n.c6ReportMessage),
          if (actionable && sendable && state.canPinMessages(conversationId))
            item('pin', Icons.push_pin_outlined, l10n.w8Pin),
          if (mine && sendable) ...<PopupMenuEntry<String>>[
            if (message.kind == LocalMessageKind.text &&
                message.deletedAt == null)
              item('edit', Icons.edit_outlined, l10n.chatEdit),
            if (canDeleteKind && message.deletedAt == null)
              item('delete', Icons.delete_outline, l10n.chatDeleteForEveryone),
          ],
          if (canModDelete)
            item(
              'delete',
              Icons.delete_outline,
              l10n.chatDeleteForEveryone,
              key: const Key('moderator-delete'),
            ),
          const PopupMenuDivider(),
          PopupMenuItem<String>(
            enabled: false,
            child: Text(
              l10n.w8MessageActionsLocalNote,
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
          child: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (actionable && sendable)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: BoneSpacing.md),
                  child: Wrap(
                    spacing: BoneSpacing.xs,
                    children: <Widget>[
                      for (final reaction in quickReactions)
                        IconButton(
                          tooltip: l10n.chatReact(reaction),
                          onPressed: () =>
                              Navigator.of(sheetContext).pop('react:$reaction'),
                          icon: Text(reaction,
                              style: const TextStyle(fontSize: 24)),
                        ),
                      IconButton(
                        tooltip: l10n.chatMoreReactions,
                        onPressed: () =>
                            Navigator.of(sheetContext).pop('react:'),
                        icon: const Icon(Icons.add_reaction_outlined),
                      ),
                    ],
                  ),
                ),
              if (actionable && sendable && mayPost)
                ListTile(
                  leading: const Icon(Icons.reply),
                  title: Text(l10n.chatReply),
                  onTap: () => Navigator.of(sheetContext).pop('reply'),
                ),
              if (actionable && message.kind == LocalMessageKind.text)
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: Text(l10n.chatCopyText),
                  onTap: () => Navigator.of(sheetContext).pop('copy'),
                ),
              if (actionable && message.kind == LocalMessageKind.text)
                ListTile(
                  leading: const Icon(Icons.text_fields),
                  title: Text(l10n.chatSelectText),
                  onTap: () => Navigator.of(sheetContext).pop('select'),
                ),
              if (actionable)
                ListTile(
                    leading: const Icon(Icons.forward_outlined),
                    title: Text(l10n.w8Forward),
                    onTap: () => Navigator.of(sheetContext).pop('forward')),
              ListTile(
                  leading: Icon(starred ? Icons.star : Icons.star_outline),
                  title: Text(starred ? l10n.w8Unstar : l10n.w8Star),
                  onTap: () => Navigator.of(sheetContext).pop('star')),
              ListTile(
                  leading: const Icon(Icons.hide_source),
                  title: Text(l10n.w8DeleteForMe),
                  onTap: () => Navigator.of(sheetContext).pop('hide')),
              // C6: report a message someone else sent. Offered only where the
              // build can report; the screen explains what is sent first.
              if (actionable && !mine && state.reportsAvailable)
                ListTile(
                    leading: const Icon(Icons.flag_outlined),
                    title: Text(l10n.c6ReportMessage),
                    onTap: () => Navigator.of(sheetContext).pop('report')),
              if (actionable &&
                  sendable &&
                  state.canPinMessages(conversationId))
                ListTile(
                    leading: const Icon(Icons.push_pin_outlined),
                    title: Text(l10n.w8Pin),
                    onTap: () => Navigator.of(sheetContext).pop('pin')),
              if (mine && sendable) ...<Widget>[
                if (message.kind == LocalMessageKind.text &&
                    message.deletedAt == null)
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: Text(l10n.chatEdit),
                    onTap: () => Navigator.of(sheetContext).pop('edit'),
                  ),
                if (canDeleteKind && message.deletedAt == null)
                  ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: Text(l10n.chatDeleteForEveryone),
                    onTap: () => Navigator.of(sheetContext).pop('delete'),
                  ),
              ],
              // C5: a moderator or above deletes a message of someone it
              // outranks under the verified role record; every app checks.
              if (canModDelete)
                ListTile(
                  key: const Key('moderator-delete'),
                  leading: const Icon(Icons.delete_outline),
                  title: Text(l10n.chatDeleteForEveryone),
                  onTap: () => Navigator.of(sheetContext).pop('delete'),
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
                  l10n.w8MessageActionsLocalNote,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          )),
        ),
      );
    }
    if (!mounted || action == null) return;
    var sent = true;
    if (action.startsWith('react:')) {
      var reaction = action.substring('react:'.length);
      if (reaction.isEmpty) {
        // The "more" button: any emoji, from the picker or typed.
        final picked = await showEmojiPicker(context);
        if (!mounted || picked == null) return;
        reaction = picked;
      }
      final ownAccountId = state.session?.accountId;
      final alreadyMine = state
          .historyFor(conversationId)
          .reactionsFor(message.key, ownAccountId: ownAccountId)
          .any((item) => item.reaction == reaction && item.mine);
      // Tapping your own reaction again takes it back.
      sent = await state.react(
          conversationId, message.key, alreadyMine ? '' : reaction);
    } else if (action == 'reply') {
      _setReplyTarget(message.key);
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.body ?? ''));
    } else if (action == 'select') {
      // U7: the bubble itself is not selectable, so a long-press anywhere on
      // it opens this menu; selecting words happens here.
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                BoneSpacing.gutter, 0, BoneSpacing.gutter, BoneSpacing.lg),
            child: FormattedMessage(
              key: const Key('select-text'),
              selectable: true,
              text: message.body ?? '',
              formatJson: message.formatJson,
              style: Theme.of(sheetContext).textTheme.bodyLarge,
            ),
          ),
        ),
      );
    } else if (action == 'star') {
      await state.toggleMessageStar(message);
    } else if (action == 'hide') {
      await _deleteForMe(message);
    } else if (action == 'report') {
      await Navigator.of(context).push<void>(sharedAxisRoute<void>(
        (_) => ReportMessageScreen(
          state: state,
          conversationId: conversationId,
          messageKey: message.key,
        ),
      ));
      return;
    } else if (action == 'forward') {
      final selected = <String>{};
      final destinations = await showDialog<List<String>>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
              builder: (context, setDialogState) => AlertDialog(
                    title: Text(context.l10n.w8Forward),
                    content: SizedBox(
                        width: 360,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              for (final c in state.conversations)
                                CheckboxListTile(
                                    value: selected.contains(c.id),
                                    title: Text(conversationTitle(
                                        context.l10n, c,
                                        profiles: state.profiles)),
                                    onChanged: (v) => setDialogState(() {
                                          if (v == true &&
                                              selected.length <
                                                  ((message.forwardHops ?? 0) >=
                                                          5
                                                      ? 1
                                                      : 5)) {
                                            selected.add(c.id);
                                          } else {
                                            selected.remove(c.id);
                                          }
                                        }))
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: Text(context.l10n.commonCancel)),
                      FilledButton(
                          onPressed: selected.isEmpty
                              ? null
                              : () => Navigator.pop(
                                  dialogContext, selected.toList()),
                          child: Text(context.l10n.w8Forward))
                    ],
                  )));
      if (destinations != null)
        sent = await state.forwardMessage(message, destinations);
    } else if (action == 'pin') {
      final existing =
          state.pinsFor(conversationId).any((p) => p.targetKey == message.key);
      final duration = await showModalBottomSheet<int>(
          context: context,
          builder: (sheetContext) => SafeArea(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (existing)
                  ListTile(
                      title: Text(context.l10n.w8Unpin),
                      onTap: () => Navigator.pop(sheetContext, 0)),
                for (final days in [1, 7, 30])
                  ListTile(
                      title: Text(context.l10n.w8PinDays(days)),
                      onTap: () => Navigator.pop(sheetContext, days * 86400)),
              ])));
      if (duration != null)
        sent = await state.pinMessage(conversationId, message.key,
            pinned: duration != 0, durationSeconds: duration);
    } else if (action == 'edit') {
      await _editMessage(message);
      return;
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.l10n.chatDeleteTitle),
          content: Text(context.l10n.chatDeleteMessage),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(context.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(context.l10n.chatDelete),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      sent = await state.deleteMessage(conversationId, message.key);
    }
    if (!sent && mounted) {
      final error = state.errorFor(Ops.send);
      if (error != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
      }
    }
  }

  Future<void> _editMessage(LocalMessage message) async {
    final text = await _editDialog(message.body ?? '');
    if (!mounted || text == null || text.trim().isEmpty) return;
    if (text == message.body) return;
    final sent = await widget.state
        .editMessage(widget.conversationId, message.key, text.trim());
    final error = widget.state.errorFor(Ops.send);
    if (!sent && mounted && error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  /// U16 (D133): "Delete for me" hides the message at once and offers Undo.
  /// When the snackbar closes any other way (its time is up, it is swiped
  /// away, or the next one replaces it) the delete is final.
  Future<void> _deleteForMe(LocalMessage message) async {
    final state = widget.state;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final hidden = await state.deleteMessageForMe(message);
    if (!hidden) return;
    // Clear the queue too, so a snackbar waiting behind the current one
    // cannot take the place of the Undo window.
    messenger.clearSnackBars();
    final controller = messenger.showSnackBar(SnackBar(
      key: const Key('delete-for-me-undo'),
      content: Text(l10n.w8DeletedForMe),
      persist: false,
      duration: AppState.deleteForMeUndoShown,
      action: SnackBarAction(
        label: l10n.commonUndo,
        onPressed: () async {
          final restored = await state.undoDeleteForMe(message);
          if (!restored) {
            messenger.showSnackBar(
                SnackBar(content: Text(l10n.w8DeleteForMeUndoFailed)));
          }
        },
      ),
    ));
    unawaited(controller.closed.then((reason) {
      if (reason != SnackBarClosedReason.action) {
        return state.finishDeleteForMe(message.key);
      }
    }));
  }

  Future<String?> _editDialog(String current) {
    final controller = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final trimmed = value.text.trim();
          final error = trimmed.isEmpty
              ? context.l10n.chatEditEmpty
              : trimmed.length > maxAppTextLength
                  ? context.l10n.validationMessageTooLong
                  : null;
          return AlertDialog(
            title: Text(context.l10n.chatEditTitle),
            content: TextField(
              controller: controller,
              autofocus: true,
              minLines: 1,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(errorText: error),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(context.l10n.commonCancel),
              ),
              FilledButton(
                onPressed: error == null
                    ? () => Navigator.of(dialogContext).pop(controller.text)
                    : null,
                child: Text(context.l10n.attachmentSave),
              ),
            ],
          );
        },
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _send() async {
    final state = widget.state;
    final conversationId = widget.conversationId;
    // Each waiting file goes first, as its own encrypted attachment.
    if (_attachments.isNotEmpty) {
      if (state.isBusy(Ops.attachment)) return;
      final sentFiles = await sendPendingAttachments(
          context, state, conversationId, _attachments);
      if (!sentFiles || !mounted) return;
    }
    final text = composer.text.trim();
    if (text.isEmpty) {
      return;
    }
    final replyingTo = _replyTarget()?.key;
    final sent = replyingTo == null
        ? await state.sendMessageTo(conversationId, text)
        : await state.replyTo(conversationId, replyingTo, text);
    if (sent) {
      // Durable acceptance, rather than HTTP delivery, is the point at which
      // the submitted draft is safe to clear. Preserve newer edits. The
      // stored draft is cleared even if this screen closed meanwhile, so the
      // sent text does not come back as a draft.
      state.composerDrafts
          .clearSent(conversationId, text: text, replyTo: replyingTo);
      if (!mounted) {
        return;
      }
      if (_replyingTo == replyingTo) {
        setState(() => _replyingTo = null);
      }
      if (composer.text.trim() == text) composer.clear();
      return;
    }
    if (!mounted) {
      return;
    }
    final error = widget.state.errorFor(Ops.send);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }
}

/// Everything the open conversation reads from [AppState] (T49C-1). The chat
/// rebuilds only when this changes, so a notification about another
/// conversation, the device list or the connection leaves it alone.
///
/// Lists and models compare by identity: AppState replaces them instead of
/// editing them in place. A new read from the state anywhere in this file's
/// build methods must be added here, or that part of the chat stays stale.
List<Object?> _chatScreenSelection(AppState state, String conversationId) {
  final history = state.historyFor(conversationId);
  final pending = state.pendingFor(conversationId);
  final session = state.session;
  return <Object?>[
    state.conversations.where((item) => item.id == conversationId).firstOrNull,
    state.conversations
        .where((item) => item.id == conversationId)
        .map(state.requestBucket)
        .firstOrNull,
    state.messagesFor(conversationId),
    // A conversation without loaded history gets a new empty one per call;
    // every history without messages draws the same.
    history.messages.isEmpty ? null : history,
    state.membersFor(conversationId),
    state.selectedChannelFor(conversationId),
    session?.accountId,
    session?.deviceId,
    state.l10n,
    state.isMuted(conversationId),
    state.mlsConversationFailed(conversationId),
    state.conversationPauseFor(conversationId)?.generation,
    state.readOnlyWithoutPeer(conversationId),
    state.sendHeldForRemoval(conversationId),
    state.channelKeyRenewalStuck(conversationId),
    ...state.approvalHoldAccounts(conversationId),
    state.approvalHoldRechecking(conversationId),
    ...state.incompleteJoinAccounts(conversationId),
    state.isBusy(Ops.send),
    state.isBusy(Ops.attachment),
    state.attachmentsAvailable,
    state.messageActionsAvailable,
    state.starredMessages,
    ...state.pinsFor(conversationId),
    state.isLoadingMessages(conversationId),
    state.messageLoadError(conversationId),
    state.hasMoreHistory(conversationId),
    state.isLoadingOlder(conversationId),
    for (final envelope in pending) ...<Object?>[
      envelope,
      state.outboxState(envelope.idempotencyKey),
      state.outboxRecord(envelope.idempotencyKey),
    ],
  ];
}

class _MessageLoadError extends StatelessWidget {
  const _MessageLoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: BoneSpacing.lg),
            Text(
              context.l10n.chatLoadFailed,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: BoneSpacing.sm),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: BoneSpacing.lg),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.commonRetry),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.state,
    required this.conversationId,
    required this.controller,
    required this.messages,
    required this.pending,
    required this.jumpTarget,
    this.jumpKey,
    this.highlighted = false,
    this.unreadDividerCount = 0,
    this.onJumpToMessage,
    this.onReplyToMessage,
    this.onToggleReaction,
    this.onMessageActions,
  });

  /// The key put on the message named by [jumpKey], so the screen can find it
  /// once it is built (W10); [highlighted] tints it.
  final GlobalKey jumpTarget;
  final String? jumpKey;
  final bool highlighted;
  final int unreadDividerCount;

  final AppState state;
  final String conversationId;
  final ScrollController controller;
  final List<ReceivedMessageEnvelope> messages;
  final List<MessageEnvelope> pending;
  final ValueChanged<String>? onJumpToMessage;
  final ValueChanged<LocalMessage>? onReplyToMessage;
  final void Function(LocalMessage message, String reaction)? onToggleReaction;
  final void Function(LocalMessage message, bool mine, {Offset? anchor})?
      onMessageActions;

  bool get _isDm =>
      state.conversations
          .where((item) => item.id == conversationId)
          .firstOrNull
          ?.isDm ??
      false;

  /// Names a sender from the loaded roster when possible, falling back to a
  /// shortened account ID. Server-supplied display metadata, not a verified
  /// identity claim.
  String _senderLabel(String accountId) {
    final member = state
        .membersFor(conversationId)
        .where((item) => item.accountId == accountId)
        .firstOrNull;
    // W11: the sender's shared display name first; the username stays what
    // identifies them (member lists show both).
    return state.profiles?.account(accountId)?.name ??
        accountLabel(accountId, member?.username);
  }

  static bool _isClusterable(
    ReceivedMessageEnvelope message,
    LocalMessage? local,
    bool? historyLine,
  ) {
    if (historyLine != null) return false;
    if (message.deletedAt != null || local?.deletedAt != null) return false;
    if (local?.c7Former != null || local?.senderRemoved == true) return false;
    final kind = local?.kind;
    if (kind == LocalMessageKind.invalid ||
        kind == LocalMessageKind.unsupported ||
        kind == LocalMessageKind.unverifiable) {
      return false;
    }
    return true;
  }

  static bool _canCluster(
    ReceivedMessageEnvelope newer,
    LocalMessage? newerLocal,
    bool? newerHistoryLine,
    ReceivedMessageEnvelope older,
    LocalMessage? olderLocal,
    bool? olderHistoryLine,
  ) {
    if (!_isClusterable(newer, newerLocal, newerHistoryLine) ||
        !_isClusterable(older, olderLocal, olderHistoryLine)) {
      return false;
    }
    final newerSender = newerLocal?.senderAccountId ?? newer.senderAccountId;
    final olderSender = olderLocal?.senderAccountId ?? older.senderAccountId;
    if (newerSender != olderSender) return false;
    return newer.createdAt.difference(older.createdAt).abs() <=
        const Duration(minutes: 2);
  }

  Widget _centered(Widget child) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: BoneSpacing.maxChatWidth),
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final history = state.historyFor(conversationId);
    final ownDeviceId = state.session?.deviceId;
    // Edit, delete and reaction envelopes change other bubbles instead of
    // drawing their own.
    // C7: a record message that changed the history setting stays, drawn
    // as a system line (decision 1); every other hidden envelope goes.
    bool? historyLine(ReceivedMessageEnvelope message) =>
        state.channelHistoryLine(
            conversationId,
            ConversationHistory.keyOf(
                message.senderDeviceId, message.idempotencyKey));
    final messages = this
        .messages
        .where((message) =>
            !history.hides(message) || historyLine(message) != null)
        .toList(growable: false);
    final hasMore = state.hasMoreHistory(conversationId);
    final loadingOlder = state.isLoadingOlder(conversationId);
    // C7 (owner answer Q1): earlier posts of a `full` channel, on demand.
    final earlier = !hasMore && state.channelHistoryEarlier(conversationId);
    // Messages arrive newest-first; the list is reversed so index 0 renders
    // at the bottom. Because older items are appended to the end of the
    // reversed list, prepending history does not move the visible messages,
    // which is what preserves the scroll position across a page load. A day
    // separator is emitted whenever the calendar day changes relative to the
    // next-older message.
    // The oldest end of the thread is either the way to older history or,
    // once there is none, the one notice that the chat is encrypted (U13).
    final showHistoryFooter = hasMore || loadingOlder || earlier;
    const footerCount = 1;
    final showUnreadBar =
        unreadDividerCount > 0 && unreadDividerCount < messages.length;
    return ListView.builder(
      controller: controller,
      reverse: true,
      // Dragging the thread puts the keyboard away so the history it hid is
      // readable; the draft stays in the composer.
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(
        horizontal: BoneSpacing.gutter,
        vertical: BoneSpacing.lg,
      ),
      itemCount: pending.length + messages.length + footerCount,
      itemBuilder: (context, index) {
        if (index == pending.length + messages.length) {
          if (!showHistoryFooter) {
            return _centered(_EncryptionNotice(isDm: _isDm));
          }
          return _centered(_HistoryFooter(
            loading: loadingOlder,
            label: hasMore ? null : context.l10n.channelHistoryEarlier,
            onLoad: hasMore
                ? () => state.loadOlderMessages(conversationId)
                : () => state.loadEarlierChannelPosts(conversationId),
          ));
        }
        if (index < pending.length) {
          final envelope = pending[pending.length - 1 - index];
          final key = envelope.idempotencyKey;
          final record = state.outboxRecord(key);
          final terminal =
              state.outboxState(key) == OutboxDeliveryState.terminal;
          final local = ownDeviceId == null
              ? null
              : history.forKey(ConversationHistory.keyOf(ownDeviceId, key));
          if (local?.kind == LocalMessageKind.action) {
            return const SizedBox.shrink();
          }
          return _centered(_PendingMessageBubble(
            text: local?.kind == LocalMessageKind.attachment
                ? _attachmentSummary(context.l10n, local!, conversationId)
                : local?.kind == LocalMessageKind.poll
                    ? parsePollBody(local!.body)?.question
                    : local?.body ?? record?.draftText,
            state: state.outboxState(key),
            failureMessage: terminal ? state.outboxFailureMessage(key) : null,
            onRetry: terminal ? null : () => state.retryEnvelope(key),
            onCopy: record?.draftText == null
                ? null
                : () => Clipboard.setData(
                      ClipboardData(text: record!.draftText!),
                    ),
            onDiscard: terminal ? () => state.discardEnvelope(key) : null,
            // L2-3: the server would not take it hidden; only this tap
            // sends it identified (owner decision 2026-11-12).
            onSendNormally: terminal && state.outboxNeedsSealedChoice(key)
                ? () => state.sendSealedNormally(key)
                : null,
          ));
        }
        final messageIndex = index - pending.length;
        final message = messages[messageIndex];
        final line = historyLine(message);
        if (line != null) {
          return _centered(_HistoryLine(
              text: line
                  ? context.l10n.channelHistoryLineFull
                  : context.l10n.channelHistoryLineFromJoin));
        }
        final local = history.forEnvelope(message);
        // A decrypted record names its authenticated sender; the envelope's
        // sender is only what the server says.
        final senderAccountId =
            local?.senderAccountId ?? message.senderAccountId;
        final mine = senderAccountId == state.session?.accountId;
        final replyTarget =
            local?.replyTo == null ? null : history.forKey(local!.replyTo!);
        final replySender = replyTarget == null
            ? null
            : replyTarget.senderAccountId == state.session?.accountId
                ? context.l10n.chatSenderYou
                : _senderLabel(replyTarget.senderAccountId);
        final older = messageIndex + 1 < messages.length
            ? messages[messageIndex + 1]
            : null;
        final newer = messageIndex > 0 ? messages[messageIndex - 1] : null;
        final showDay = older == null ||
            formatDate(context, older.createdAt) !=
                formatDate(context, message.createdAt);
        final showNewDivider =
            showUnreadBar && messageIndex == unreadDividerCount - 1;
        final olderLocal = older == null ? null : history.forEnvelope(older);
        final olderLine = older == null ? null : historyLine(older);
        final newerLocal = newer == null ? null : history.forEnvelope(newer);
        final newerLine = newer == null ? null : historyLine(newer);
        final newerShowDay = newer != null &&
            formatDate(context, message.createdAt) !=
                formatDate(context, newer.createdAt);
        final newerShowNewDivider =
            showUnreadBar && messageIndex - 1 == unreadDividerCount - 1;
        final groupedWithOlder = older != null &&
            !showDay &&
            !showNewDivider &&
            _canCluster(
              message,
              local,
              line,
              older,
              olderLocal,
              olderLine,
            );
        final groupedWithNewer = newer != null &&
            !newerShowDay &&
            !newerShowNewDivider &&
            _canCluster(
              newer,
              newerLocal,
              newerLine,
              message,
              local,
              line,
            );
        final actionable = local != null &&
            local.deletedAt == null &&
            local.hiddenAt == null &&
            const <String>[
              LocalMessageKind.text,
              LocalMessageKind.attachment,
            ].contains(local.kind);
        final isJumpTarget = jumpKey != null && local?.key == jumpKey;
        final row = _centered(Column(
          children: <Widget>[
            if (showDay)
              _DaySeparator(label: formatDate(context, message.createdAt)),
            if (showNewDivider) const _NewMessagesDivider(),
            MessageTickBuilder(
              state: state,
              conversationId: conversationId,
              createdAt: message.createdAt,
              enabled: mine &&
                  local?.state != LocalMessageState.restored &&
                  message.deletedAt == null &&
                  local?.deletedAt == null &&
                  state.ticksApply(conversationId),
              builder: (context, tick) => _MessageBubble(
                message: message,
                local: local,
                copiedHistory: local?.state == LocalMessageState.restored ||
                    (local != null && history.copiedKeys.contains(local.key)),
                formerMember: local?.c7Former != null,
                replySender: replySender,
                replyPreview: local?.replyTo == null
                    ? null
                    : quotedPreview(context.l10n, replyTarget),
                onTapReply: local?.replyTo == null || onJumpToMessage == null
                    ? null
                    : () => onJumpToMessage!(local!.replyTo!),
                reactions: local == null
                    ? const <({String reaction, int count, bool mine})>[]
                    : history.reactionsFor(local.key,
                        ownAccountId: state.session?.accountId),
                onToggleReaction: actionable && onToggleReaction != null
                    ? (reaction) => onToggleReaction!(local, reaction)
                    : null,
                onReply: actionable && onReplyToMessage != null
                    ? () => onReplyToMessage!(local)
                    : null,
                starred:
                    local != null && state.starredMessages.contains(local.key),
                onMention: (accountId) {
                  final member = state
                      .membersFor(conversationId)
                      .where((m) => m.accountId == accountId)
                      .firstOrNull;
                  showModalBottomSheet<void>(
                      context: context,
                      builder: (_) => SafeArea(
                          child: ListTile(
                              leading: const Icon(Icons.person_outline),
                              title: Text(member?.username ?? accountId),
                              subtitle: Text(accountId))));
                },
                mine: mine,
                groupedWithOlder: groupedWithOlder,
                groupedWithNewer: groupedWithNewer,
                tick: tick,
                ownAccountId: state.session?.accountId,
                pollMembers: state.membersFor(conversationId).isEmpty
                    ? null
                    : state.memberAccounts(conversationId),
                onVote: local == null ||
                        local.kind != LocalMessageKind.poll ||
                        !state.messageActionsAvailable ||
                        state.readOnlyWithoutPeer(conversationId)
                    ? null
                    : (choices) =>
                        state.votePoll(conversationId, local.key, choices),
                onClosePoll: local == null ||
                        local.kind != LocalMessageKind.poll ||
                        local.senderAccountId != state.session?.accountId ||
                        !state.messageActionsAvailable ||
                        state.readOnlyWithoutPeer(conversationId)
                    ? null
                    : () => state.closePoll(conversationId, local.key),
                onActions: onMessageActions == null ||
                        local == null ||
                        local.kind == LocalMessageKind.action ||
                        local.hiddenAt != null
                    ? null
                    : ({Offset? anchor}) =>
                        onMessageActions!(local, mine, anchor: anchor),
                // Review M2: a former member's name only when this device
                // proved the device was that account's.
                // A former member whose device was not proven keeps no colour
                // either: nothing the server named for it shows (Review M2).
                senderColorSeed: local?.c7Former == C7FormerMark.unnamed
                    ? null
                    : senderAccountId,
                senderLabel: local?.c7Former == C7FormerMark.unnamed
                    ? context.l10n.channelHistoryFormerMemberUnnamed
                    : _senderLabel(senderAccountId),
                onLoadVoiceNote: state.attachmentsAvailable
                    ? (entry, inMemory) => decryptVoiceNote(state, entry,
                        conversationId: conversationId, inMemory: inMemory)
                    : null,
                onLoadImagePreview: state.attachmentsAvailable
                    ? (entry) => state.loadAttachment(
                          entry,
                          conversationId: conversationId,
                        )
                    : null,
                onOpenAttachment: state.attachmentsAvailable
                    ? (entry) => openAttachment(
                          context,
                          state,
                          entry,
                          conversationId: conversationId,
                        )
                    : null,
                // In a DM the app bar already says who the other person is;
                // only group and channel bubbles need a per-message sender,
                // and only on the first bubble of a consecutive burst.
                showSender: !mine && !_isDm && !groupedWithOlder,
              ),
            ),
          ],
        ));
        if (!isJumpTarget) return row;
        return KeyedSubtree(
          key: jumpTarget,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: highlighted
                  ? Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.14)
                  : null,
              borderRadius: BorderRadius.circular(BoneRadii.md),
            ),
            child: row,
          ),
        );
      },
    );
  }
}

@visibleForTesting
String quotedPreview(AppLocalizations l10n, LocalMessage? target) {
  if (target == null) return l10n.chatReplyEarlier;
  // Their bodies are raw JSON or empty, never text to quote.
  if (target.kind == LocalMessageKind.unsupported && target.deletedAt == null) {
    return l10n.chatMessageUnsupported;
  }
  if ((target.kind == LocalMessageKind.invalid ||
          target.kind == LocalMessageKind.unverifiable) &&
      target.deletedAt == null) {
    return l10n.chatMessageInvalid;
  }
  if (target.deletedAt != null || target.body == null) {
    return l10n.chatReplyDeleted;
  }
  if (target.formatJson?.contains('spoiler') == true)
    return l10n.w8HiddenSpoiler;
  if (target.kind == LocalMessageKind.attachment) {
    return _attachmentSummary(l10n, target, target.conversationId);
  }
  if (target.kind == LocalMessageKind.poll) {
    return parsePollBody(target.body)?.question ?? l10n.chatReplyDeleted;
  }
  final text = target.body!.replaceAll(RegExp(r'\s+'), ' ').trim();
  // Cut by user-perceived character: a UTF-16 cut can leave half a surrogate
  // pair (text Flutter's paragraph builder rejects) or split an emoji
  // sequence.
  final characters = text.characters;
  return characters.length <= 80 ? text : '${characters.take(80)}…';
}

/// The one place a chat says it is encrypted (U13): the first line of its
/// history. Bubbles and the header carry no padlock of their own.
class _EncryptionNotice extends StatelessWidget {
  const _EncryptionNotice({required this.isDm});

  final bool isDm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(
          vertical: BoneSpacing.lg, horizontal: BoneSpacing.md),
      child: Row(
        key: const Key('chat-encryption-notice'),
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.lock_outline, size: 14, color: color),
          ),
          const SizedBox(width: BoneSpacing.sm),
          Flexible(
            child: Text(
              isDm
                  ? context.l10n.chatNoticeEncryptedDm
                  : context.l10n.chatNoticeEncryptedGroup,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Top-of-list affordance for older history: a spinner while a page is in
/// flight, and an explicit button otherwise so history is reachable without
/// relying on a scroll gesture.
class _HistoryFooter extends StatelessWidget {
  const _HistoryFooter(
      {required this.loading, required this.onLoad, this.label});

  final bool loading;
  final VoidCallback onLoad;

  /// The button's text; null: "Load older".
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BoneSpacing.lg),
      child: Center(
        child: loading
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton.icon(
                onPressed: onLoad,
                icon: const Icon(Icons.history),
                label: Text(label ?? context.l10n.chatLoadOlder),
              ),
      ),
    );
  }
}

class _PendingMessageBubble extends StatelessWidget {
  const _PendingMessageBubble({
    required this.state,
    required this.onRetry,
    this.text,
    this.failureMessage,
    this.onCopy,
    this.onDiscard,
    this.onSendNormally,
  });

  final OutboxDeliveryState state;
  final VoidCallback? onRetry;
  final String? text;
  final String? failureMessage;
  final VoidCallback? onCopy;
  final VoidCallback? onDiscard;

  /// L2-3: re-sends a message the server would not take hidden, with the
  /// sender visible to the server.
  final VoidCallback? onSendNormally;

  @override
  Widget build(BuildContext context) {
    final sending = state == OutboxDeliveryState.sending;
    final terminal = state == OutboxDeliveryState.terminal;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final warning = VeritraStateColors.of(context).warning;
    final l10n = context.l10n;
    return Semantics(
      liveRegion: true,
      label: sending
          ? l10n.chatPendingSendingSemantics
          : terminal
              ? l10n.chatPendingTerminalSemantics
              : l10n.chatPendingFailedSemantics,
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          decoration: BoxDecoration(
            // A failed send is not an emergency (U17): the bubble stays your
            // own tone, with an amber border and icon, and the words stay in
            // the normal text colour.
            color: BoneColors.ownBubble(theme.brightness),
            borderRadius: _bubbleRadius(mine: true),
            border: Border.all(
              color: sending ? BoneColors.hairline(theme.brightness) : warning,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              if (text != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: BoneSpacing.xs),
                  child: Text(
                    text!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              if (!sending && !terminal && onRetry != null)
                // U29: one line says what happened and what to do, and the
                // whole line is the button.
                TextButton.icon(
                  key: const Key('pending-not-sent-retry'),
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.onSurface,
                  ),
                  icon: Icon(Icons.error_outline, size: 18, color: warning),
                  label: Text(l10n.chatPendingNotSentRetry),
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (sending)
                      const SizedBox.square(
                        dimension: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        Icons.error_outline,
                        size: 18,
                        color: warning,
                      ),
                    const SizedBox(width: BoneSpacing.sm),
                    Text(
                      sending
                          ? l10n.chatPendingSending
                          : l10n.chatPendingTerminal,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              if (failureMessage != null) ...<Widget>[
                const SizedBox(height: BoneSpacing.xs),
                Text(
                  failureMessage!,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
              ],
              if (!sending)
                Wrap(
                  alignment: WrapAlignment.end,
                  children: <Widget>[
                    if (onSendNormally != null)
                      TextButton(
                        onPressed: onSendNormally,
                        child: Text(l10n.chatSendNormally),
                      ),
                    if (onCopy != null)
                      TextButton(
                        onPressed: onCopy,
                        child: Text(l10n.commonCopy),
                      ),
                    if (onDiscard != null)
                      TextButton(
                        onPressed: onDiscard,
                        child: Text(l10n.chatDiscard),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BoneSpacing.md),
      // The date is already the spoken form, so the pill needs no separate
      // semantics label — only the uppercasing, which StatusPill does.
      child: Center(child: StatusPill(label: label)),
    );
  }
}

class _NewMessagesDivider extends StatelessWidget {
  const _NewMessagesDivider();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lineColor = scheme.primary.withValues(alpha: 0.4);
    return Padding(
      key: const Key('chat-new-messages-divider'),
      padding: const EdgeInsets.symmetric(vertical: BoneSpacing.sm),
      child: Row(
        children: <Widget>[
          Expanded(child: Divider(color: lineColor, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BoneSpacing.md),
            child: Text(
              context.l10n.chatNewMessagesDivider,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.primary,
              ),
            ),
          ),
          Expanded(child: Divider(color: lineColor, height: 1)),
        ],
      ),
    );
  }
}

/// Corner radii for a bubble: square-ish on the tail corner, tighter inner
/// corners when clustered with adjacent bubbles from the same sender, and
/// [BoneRadii.bubble] everywhere else.
BorderRadius _bubbleRadius({
  required bool mine,
  bool groupedWithOlder = false,
  bool groupedWithNewer = false,
}) {
  final topInner = groupedWithOlder ? 6.0 : BoneRadii.bubble;
  final bottomInner = groupedWithNewer ? 6.0 : 5.0;
  return BorderRadius.only(
    topLeft: Radius.circular(mine ? BoneRadii.bubble : topInner),
    topRight: Radius.circular(mine ? topInner : BoneRadii.bubble),
    bottomLeft: Radius.circular(mine ? BoneRadii.bubble : bottomInner),
    bottomRight: Radius.circular(mine ? bottomInner : BoneRadii.bubble),
  );
}

/// Widths of the redacted bars that stand in for an undecryptable message,
/// as fractions of the bubble's content width.
///
/// **The widths are bucketed on purpose. Do not make this linear in
/// [byteLength].** A bar whose width tracked the ciphertext length exactly
/// would make the length of every message readable over the user's shoulder —
/// a real, if small, regression against a threat this app takes seriously, and
/// one that today's identical-width bubbles happen not to have. Six buckets
/// keep the rhythm of a real conversation while leaking only which of six
/// ranges a message falls in.
///
/// The thresholds are coarse by design and are byte counts of the whole
/// envelope, which carries a large constant crypto overhead; they are not
/// character counts and should not be tuned to look like them.
///
/// Capped at three lines so one long message cannot dominate the thread.
List<double> redactedBarFractions(int byteLength) {
  const thresholds = <int>[64, 128, 224, 384, 640];
  var bucket = 0;
  while (bucket < thresholds.length && byteLength > thresholds[bucket]) {
    bucket++;
  }
  const shapes = <List<double>>[
    <double>[0.30],
    <double>[0.46],
    <double>[0.64],
    <double>[0.88],
    <double>[1, 0.58],
    <double>[1, 1, 0.71],
  ];
  return shapes[bucket];
}

/// A swipe toward the start (left in LTR) opens a message's actions (U36),
/// while a swipe toward the end (right in LTR) translates the bubble with a
/// reply cue and triggers quick reply. Uses a raw [Listener] so it never
/// competes with vertical scrolling or edge navigation gestures.
class _SwipeForActions extends StatefulWidget {
  const _SwipeForActions({
    required this.onSwipe,
    this.onSwipeReply,
    required this.child,
  });

  final VoidCallback? onSwipe;
  final VoidCallback? onSwipeReply;
  final Widget child;

  /// How far the finger must travel for actions, in logical pixels.
  static const double distance = 72;

  /// How far the finger must travel to trigger quick reply.
  static const double replyDistance = 64;

  /// How far it may drift up or down on the way.
  static const double drift = 32;

  /// How long it may take.
  static const Duration within = Duration(milliseconds: 700);

  @override
  State<_SwipeForActions> createState() => _SwipeForActionsState();
}

class _SwipeForActionsState extends State<_SwipeForActions> {
  int? _pointer;
  Offset _start = Offset.zero;
  Duration _startedAt = Duration.zero;
  double _replyOffset = 0;

  @override
  Widget build(BuildContext context) {
    final isLtr = Directionality.of(context) == TextDirection.ltr;
    final towardStart = isLtr ? -1.0 : 1.0;
    final towardEnd = -towardStart;
    final scheme = Theme.of(context).colorScheme;
    final progress =
        (_replyOffset.abs() / _SwipeForActions.replyDistance).clamp(0.0, 1.0);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        // A second finger, or a non-primary button, is not a swipe.
        if (_pointer != null || event.buttons != kPrimaryButton) {
          _pointer = null;
          return;
        }
        _pointer = event.pointer;
        _start = event.position;
        _startedAt = event.timeStamp;
      },
      onPointerMove: (event) {
        if (event.pointer != _pointer || widget.onSwipeReply == null) return;
        final moved = event.position - _start;
        final alongEnd = moved.dx * towardEnd;
        if (alongEnd > 8 && moved.dy.abs() <= _SwipeForActions.drift) {
          final clamped = math.min(alongEnd * 0.65, 52.0) * towardEnd;
          if ((clamped - _replyOffset).abs() >= 1) {
            setState(() => _replyOffset = clamped);
          }
        } else if (_replyOffset != 0) {
          setState(() => _replyOffset = 0);
        }
      },
      onPointerUp: (event) {
        if (event.pointer != _pointer) return;
        _pointer = null;
        if (_replyOffset != 0) setState(() => _replyOffset = 0);
        final moved = event.position - _start;
        final verticalOk = moved.dy.abs() <= _SwipeForActions.drift;
        final quickEnough =
            event.timeStamp - _startedAt <= _SwipeForActions.within;
        if (moved.dx * towardStart >= _SwipeForActions.distance &&
            verticalOk &&
            quickEnough) {
          widget.onSwipe?.call();
        } else if (widget.onSwipeReply != null &&
            moved.dx * towardEnd >= _SwipeForActions.replyDistance &&
            verticalOk &&
            quickEnough) {
          HapticFeedback.selectionClick();
          widget.onSwipeReply!();
        }
      },
      onPointerCancel: (event) {
        if (event.pointer == _pointer) {
          _pointer = null;
          if (_replyOffset != 0) setState(() => _replyOffset = 0);
        }
      },
      child: Stack(
        alignment: isLtr ? Alignment.centerLeft : Alignment.centerRight,
        children: <Widget>[
          if (_replyOffset != 0)
            Positioned(
              left: isLtr ? BoneSpacing.xs : null,
              right: isLtr ? null : BoneSpacing.xs,
              child: Opacity(
                opacity: progress,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.reply,
                    size: 16,
                    color: progress >= 0.85
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(_replyOffset, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.senderLabel,
    this.senderColorSeed,
    required this.showSender,
    this.groupedWithOlder = false,
    this.groupedWithNewer = false,
    this.local,
    this.replySender,
    this.replyPreview,
    this.onTapReply,
    this.reactions = const <({String reaction, int count, bool mine})>[],
    this.onToggleReaction,
    this.onReply,
    this.tick,
    this.onActions,
    this.onOpenAttachment,
    this.onLoadImagePreview,
    this.onLoadVoiceNote,
    this.onMention,
    this.starred = false,
    this.copiedHistory = false,
    this.formerMember = false,
    this.ownAccountId,
    this.pollMembers,
    this.onVote,
    this.onClosePoll,
  });

  /// For a poll bubble: who is looking, the roster whose votes count, and the
  /// vote sender (null when voting is unavailable).
  final String? ownAccountId;
  final Set<String>? pollMembers;
  final void Function(List<int> choices)? onVote;

  /// Closes a poll of yours; null when closing is unavailable.
  final VoidCallback? onClosePoll;

  /// Sent, delivered or read, for a message of yours; null otherwise.
  final MessageTick? tick;

  /// Opens the reply/edit/delete/react menu; null when none apply.
  final void Function({Offset? anchor})? onActions;

  /// Starts a quick reply to this message (swipe-right or desktop hover).
  final VoidCallback? onReply;

  /// Toggles an existing reaction pill or sends a desktop quick reaction.
  final ValueChanged<String>? onToggleReaction;

  /// Scrolls to the quoted message when the reply box is tapped.
  final VoidCallback? onTapReply;

  /// Opens one attachment of an attachment message.
  final void Function(AttachmentEntry entry)? onOpenAttachment;

  /// Loads decrypted image bytes for inline thumbnails on accepted chats.
  final Future<Uint8List> Function(AttachmentEntry entry)? onLoadImagePreview;

  /// Decrypts a voice note for inline playback, in memory when the player
  /// can take bytes and the note is small, else to a temporary file.
  final Future<DecryptedVoice> Function(AttachmentEntry entry, bool inMemory)?
      onLoadVoiceNote;
  final void Function(String accountId)? onMention;
  final bool starred;
  final bool copiedHistory;

  /// C7 (decision 8): an imported post whose signature was checked with the
  /// server's key for a device no longer in the group.
  final bool formerMember;

  final ReceivedMessageEnvelope message;

  /// The decrypted record, when this device could decrypt the envelope.
  final LocalMessage? local;
  final String? replySender;
  final String? replyPreview;
  final List<({String reaction, int count, bool mine})> reactions;
  final bool mine;
  final bool groupedWithOlder;
  final bool groupedWithNewer;
  final String senderLabel;

  /// Picks the colour of the sender's name in a group; null: the muted
  /// default.
  final String? senderColorSeed;
  final bool showSender;

  /// Horizontal padding inside the bubble, doubled — the amount the bars have
  /// to give back to the container.
  static const double _insetX = 28;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final deleted = message.deletedAt != null || local?.deletedAt != null;
    final unverifiable = local?.kind == LocalMessageKind.unverifiable;
    final isAttachment = local?.kind == LocalMessageKind.attachment;
    // An attachment row's body is its manifest list, never text to show.
    final placeholder = _isPlaceholder;
    // Placeholder rows hold no content to show; an unsupported row's body is
    // raw JSON kept for a later version.
    final text = deleted ||
            unverifiable ||
            isAttachment ||
            placeholder ||
            local?.kind == LocalMessageKind.poll
        ? null
        : local?.body;
    // Your own bubbles take the soft plum token (U14, D131); theirs stay on
    // the surface tone. Both keep a soft hairline.
    final background = mine
        ? BoneColors.ownBubble(theme.brightness)
        : scheme.surfaceContainerLow;
    final foreground = scheme.onSurface;
    final sender = mine ? context.l10n.chatSenderYou : senderLabel;
    final body = _SwipeForActions(
      onSwipe: onActions == null ? null : () => onActions!(),
      onSwipeReply: onReply,
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons & kSecondaryMouseButton != 0) {
            onActions?.call(anchor: event.position);
          }
        },
        child: GestureDetector(
          onLongPress: onActions == null ? null : () => onActions!(),
          child: _bubble(context, theme, scheme, background, foreground, sender,
              deleted, unverifiable, text),
        ),
      ),
    );
    if (!isDesktopPlatform ||
        (onToggleReaction == null && onReply == null && onActions == null)) {
      return body;
    }
    return _DesktopHoverActions(
      mine: mine,
      onReact: onToggleReaction,
      onReply: onReply,
      onMore: onActions == null ? null : (anchor) => onActions!(anchor: anchor),
      child: body,
    );
  }

  /// The poll of a live poll bubble, when its stored JSON reads.
  PollView? get _poll => local?.kind == LocalMessageKind.poll &&
          local?.deletedAt == null &&
          message.deletedAt == null
      ? parsePollBody(local?.body)
      : null;

  bool get _isPlaceholder =>
      local?.kind == LocalMessageKind.unsupported ||
      local?.kind == LocalMessageKind.invalid;

  /// L1: the sending device had been removed from its account's approved
  /// list when this arrived (recorded at entry, schema 40). The words are
  /// still shown, marked, so a device that is on its way out never speaks
  /// as the account unmarked.
  String? _removedSenderLabel(AppLocalizations l10n) =>
      local?.senderRemoved == true
          ? (mine
              ? l10n.chatSentFromOwnRemovedDevice
              : l10n.chatSentFromRemovedDevice(senderLabel))
          : formerMember
              ? l10n.channelHistoryFormerMember
              : null;

  /// A peer message this device can never decrypt (D54). The crypto service
  /// stores it as an `invalid` row, which holds no content and offers no
  /// action, keyed `undecryptable:<sync event>:<server id>`.
  bool get _isUndecryptable =>
      local?.kind == LocalMessageKind.invalid &&
      local!.key.startsWith(_undecryptableKeyPrefix);

  static const _undecryptableKeyPrefix = 'undecryptable:';

  /// A Welcome this device could not use: its key package is gone or
  /// expired (D74). The crypto service keys the `invalid` row
  /// `welcome-unavailable:<sync event>:<server id>`.
  bool get _isWelcomeUnavailable =>
      local?.kind == LocalMessageKind.invalid &&
      local!.key.startsWith(_welcomeUnavailableKeyPrefix);

  static const _welcomeUnavailableKeyPrefix = 'welcome-unavailable:';

  /// A message from a device that is not on its account's approved-device
  /// list (L1, D94): hidden, keyed `unapproved:<sync event>:<server id>`.
  bool get _isUnapprovedSender =>
      local?.kind == LocalMessageKind.invalid &&
      local!.key.startsWith(unapprovedSenderKeyPrefix);

  String _placeholderLabel(AppLocalizations l10n) => _isUndecryptable
      ? l10n.chatMessageUndecryptable
      : _isUnapprovedSender
          ? l10n.chatMessageUnapprovedDevice
          : _isWelcomeUnavailable
              ? l10n.chatMessageWelcomeUnavailable
              : local?.kind == LocalMessageKind.invalid
                  ? l10n.chatMessageInvalid
                  : l10n.chatMessageUnsupported;

  /// The sender's link preview (B2), re-validated against the text each time
  /// it is drawn. Nothing is fetched here.
  List<Widget> _linkPreviewCard(String text, Color foreground) {
    final preview = LinkPreview.fromWire(
        decodeDecoration(local?.formatJson)['link_preview'],
        text: text);
    if (preview == null) return const <Widget>[];
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: LinkPreviewCard(preview: preview, color: foreground),
      ),
    ];
  }

  /// The attachments of an attachment message. Entries that fail to parse,
  /// or name another conversation, are left out rather than shown.
  List<Widget> _attachmentTiles(BuildContext context) {
    final entries = AttachmentEntry.listFromBody(local?.body,
        conversationId: message.conversationId);
    if (entries.isEmpty) {
      return <Widget>[
        Text(
          // C7 (owner answer Q2): a pre-join attachment is never offered.
          local?.body == c7HiddenAttachmentBody
              ? context.l10n.channelHistoryAttachmentHidden
              : context.l10n.chatAttachmentUnopenable,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ];
    }
    return <Widget>[
      for (final entry in entries)
        if (entry.isVoiceNote && onLoadVoiceNote != null)
          VoiceNoteTile(
            key: ValueKey<String>('voice-${entry.id}'),
            entry: entry,
            load: (inMemory) => onLoadVoiceNote!(entry, inMemory),
          )
        else
          AttachmentTile(
            entry: entry,
            loadPreview: onLoadImagePreview != null &&
                    entry.isImage &&
                    entry.opensFromMemory
                ? () => onLoadImagePreview!(entry)
                : null,
            onOpen: onOpenAttachment == null
                ? null
                : () => onOpenAttachment!(entry),
          ),
    ];
  }

  Widget _bubble(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    Color background,
    Color foreground,
    String sender,
    bool deleted,
    bool unverifiable,
    String? text,
  ) {
    final l10n = context.l10n;
    final hairline = BoneColors.hairline(theme.brightness);
    final placeholder = _isPlaceholder;
    final time = formatTimeOfDay(context, message.createdAt);
    final showMeta = !groupedWithNewer ||
        message.editedAt != null ||
        local?.editedAt != null ||
        reactions.isNotEmpty ||
        starred ||
        copiedHistory;
    // An attachment bubble keeps its attachment tiles as nodes of their own
    // (file name, size and a tap action); excluding descendants would leave
    // the merged bubble with no way to open them. Everything else in such a
    // bubble stays covered by the bubble's label.
    final poll = _poll;
    final tileNodes = (local?.kind == LocalMessageKind.attachment &&
            !deleted &&
            !unverifiable &&
            onOpenAttachment != null &&
            AttachmentEntry.listFromBody(local?.body,
                    conversationId: message.conversationId)
                .isNotEmpty) ||
        (poll != null && !deleted && !unverifiable && !placeholder);
    Widget quiet(Widget child) =>
        tileNodes ? ExcludeSemantics(child: child) : child;
    final removedSender = deleted ? null : _removedSenderLabel(l10n);
    return Semantics(
      container: tileNodes,
      excludeSemantics: !tileNodes,
      onLongPress: onActions == null ? null : () => onActions!(),
      onLongPressHint: onActions == null ? null : l10n.chatMessageActions,
      label: (deleted
              ? l10n.chatDeletedSemantics(sender)
              : unverifiable
                  ? l10n.chatUnverifiedSemantics(time)
                  : placeholder
                      ? _placeholderLabel(l10n)
                      : text != null
                          ? (local?.formatJson?.contains('spoiler') == true
                              ? l10n.w8HiddenSpoiler
                              : l10n.chatMessageSemantics(sender, time, text))
                          : local?.kind == LocalMessageKind.attachment
                              ? l10n.chatAttachmentSemantics(sender, time)
                              : poll != null
                                  ? l10n.chatMessageSemantics(
                                      sender, time, poll.question)
                                  : l10n.chatEncryptedSemantics(sender, time)) +
          (removedSender == null ? '' : ', $removedSender') +
          (tick == null ? '' : ', ${messageTickLabel(l10n, tick!)}'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Taken from the layout rather than the window so the bubble is
          // sized to its pane in the wide master-detail layout too.
          final maxWidth = math.min(440.0, constraints.maxWidth * 0.82);
          return Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Container(
                margin: EdgeInsets.only(
                  top: groupedWithOlder ? 1.5 : 4.5,
                  bottom: groupedWithNewer ? 1.5 : 4.5,
                ),
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: _bubbleRadius(
                    mine: mine,
                    groupedWithOlder: groupedWithOlder,
                    groupedWithNewer: groupedWithNewer,
                  ),
                  border: Border.all(color: hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (starred) quiet(const Icon(Icons.star, size: 14)),
                    if (copiedHistory)
                      quiet(Text(l10n.k2CopiedHistory,
                          style: theme.textTheme.labelSmall)),
                    if (local?.forwardHops != null)
                      quiet(Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                              local!.forwardHops! >= 5
                                  ? l10n.w8ForwardedMany
                                  : l10n.w8Forwarded,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(fontStyle: FontStyle.italic)))),
                    if (showSender)
                      quiet(Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text(
                          senderLabel,
                          // Normal small text in the sender's own colour
                          // (U36), not the capitalised micro style.
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: senderColorSeed == null
                                ? scheme.onSurfaceVariant
                                : senderNameColor(
                                    senderColorSeed!, theme.brightness),
                          ),
                        ),
                      )),
                    // Shown whether or not the sender is (a DM hides it).
                    if (removedSender != null)
                      quiet(Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(Icons.phonelink_erase_outlined,
                                size: 14, color: scheme.error),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                removedSender,
                                style: theme.textTheme.labelSmall
                                    ?.copyWith(color: scheme.error),
                              ),
                            ),
                          ],
                        ),
                      )),
                    if (replyPreview != null && !deleted)
                      quiet(Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color: scheme.surfaceContainerHighest
                              .withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(BoneRadii.sm),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: const Key('bubble-reply-quote'),
                            onTap: onTapReply,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(9, 5, 10, 5),
                              decoration: BoxDecoration(
                                border: Border(
                                  left: BorderSide(
                                    color: scheme.primary,
                                    width: 3,
                                  ),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  if (replySender != null)
                                    Text(
                                      replySender!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: scheme.onSurface,
                                      ),
                                    ),
                                  Text(
                                    replyPreview!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )),
                    if (deleted)
                      Text(
                        l10n.chatMessageDeleted,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      )
                    else if (unverifiable)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          // Amber, not red (U17): the message is withheld
                          // and the words say why; nothing here is a
                          // threat in progress.
                          Icon(Icons.gpp_maybe_outlined,
                              size: 16,
                              color: VeritraStateColors.of(context).warning),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              l10n.chatSenderUnverified,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      )
                    else if (placeholder)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                              _isUndecryptable
                                  ? Icons.visibility_off_outlined
                                  : local?.kind == LocalMessageKind.invalid
                                      ? Icons.warning_amber_outlined
                                      : Icons.update_outlined,
                              size: 16,
                              color: scheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _placeholderLabel(l10n),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        ],
                      )
                    else if (poll != null)
                      PollCard(
                        poll: poll,
                        ownAccountId: ownAccountId,
                        members: pollMembers,
                        onVote: onVote,
                        onClose: onClosePoll,
                      )
                    else if (local?.kind == LocalMessageKind.attachment)
                      ..._attachmentTiles(context)
                    else if (text != null) ...<Widget>[
                      FormattedMessage(
                        text: text,
                        formatJson: local?.formatJson,
                        onMention: onMention,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: foreground),
                      ),
                      ..._linkPreviewCard(text, foreground),
                    ] else
                      _RedactedBars(
                        byteLength: message.ciphertext.length,
                        contentWidth: maxWidth - _insetX,
                        color: foreground,
                      ),
                    if (reactions.isNotEmpty && !deleted)
                      quiet(Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: <Widget>[
                            for (final item in reactions)
                              Material(
                                color: item.mine
                                    ? scheme.secondaryContainer
                                    : scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(12),
                                child: InkWell(
                                  onTap: onToggleReaction == null
                                      ? null
                                      : () => onToggleReaction!(item.reaction),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: item.mine
                                            ? scheme.primary
                                                .withValues(alpha: 0.45)
                                            : hairline,
                                      ),
                                    ),
                                    child: Text(
                                      item.count > 1
                                          ? l10n.chatReactionCount(
                                              item.reaction,
                                              item.count,
                                            )
                                          : item.reaction,
                                      style: theme.textTheme.labelSmall,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      )),
                    if (showMeta) ...<Widget>[
                      const SizedBox(height: 6),
                      quiet(_metaLine(context, scheme)),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // The raw crypto protocol identifier is debug info and stays out of the
  // reading surface. A bubble carries no padlock: the chat says it is
  // encrypted once, at its start (U13).
  Widget _metaLine(BuildContext context, ColorScheme scheme) {
    final theme = Theme.of(context);
    final parts = <String>[
      formatTimeOfDay(context, message.createdAt),
      if (message.editedAt != null || local?.editedAt != null)
        context.l10n.chatEdited,
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(parts.join(' · '), style: theme.textTheme.labelSmall),
        if (tick != null) ...<Widget>[
          const SizedBox(width: 4),
          MessageTickIcon(tick: tick!),
        ],
      ],
    );
  }
}

/// Reactions offered in the message menu.
const List<String> quickReactions = <String>[
  '👍',
  '❤️',
  '😂',
  '🎉',
  '😮',
  '😢'
];

/// Floating quick-action pill revealed on pointer hover over a message on
/// desktop platforms. Keeps reactions, reply, and more actions one click away
/// without cluttering the thread at rest.
class _DesktopHoverActions extends StatefulWidget {
  const _DesktopHoverActions({
    required this.mine,
    required this.child,
    this.onReact,
    this.onReply,
    this.onMore,
  });

  final bool mine;
  final Widget child;
  final ValueChanged<String>? onReact;
  final VoidCallback? onReply;
  final ValueChanged<Offset?>? onMore;

  @override
  State<_DesktopHoverActions> createState() => _DesktopHoverActionsState();
}

class _DesktopHoverActionsState extends State<_DesktopHoverActions> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          widget.child,
          if (_hovering)
            Positioned(
              top: -12,
              right: widget.mine ? BoneSpacing.xs : null,
              left: widget.mine ? null : BoneSpacing.xs,
              child: Material(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(BoneRadii.pill),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(BoneRadii.pill),
                    border: Border.all(
                      color: BoneColors.hairline(theme.brightness),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (widget.onReact != null)
                        for (final emoji in quickReactions.take(3))
                          InkWell(
                            borderRadius: BorderRadius.circular(BoneRadii.pill),
                            onTap: () => widget.onReact!(emoji),
                            child: Tooltip(
                              message: l10n.chatReact(emoji),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                child: Text(
                                  emoji,
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                            ),
                          ),
                      if (widget.onReply != null)
                        Tooltip(
                          message: l10n.chatReply,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(BoneRadii.pill),
                            onTap: widget.onReply,
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.reply,
                                size: 16,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      if (widget.onMore != null)
                        Builder(
                          builder: (buttonContext) => Tooltip(
                            message: l10n.chatMoreActions,
                            child: InkWell(
                              borderRadius:
                                  BorderRadius.circular(BoneRadii.pill),
                              onTap: () {
                                final box = buttonContext.findRenderObject()
                                    as RenderBox?;
                                final anchor = box?.localToGlobal(
                                  Offset(box.size.width / 2, box.size.height),
                                );
                                widget.onMore!(anchor);
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: Icon(
                                  Icons.more_horiz,
                                  size: 16,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Local-only @mention autocomplete bar above the composer in groups and
/// channels. Matches against the already-loaded conversation member roster;
/// nothing ever leaves the device.
class _MentionSuggestions extends StatelessWidget {
  const _MentionSuggestions({
    required this.controller,
    required this.members,
    required this.ownAccountId,
    required this.profiles,
  });

  final TextEditingController controller;
  final List<ConversationMember> members;
  final String? ownAccountId;
  final ProfileService? profiles;

  static final RegExp _trigger = RegExp(r'(?:^|\s)@([a-zA-Z0-9._-]{0,32})$');

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) return const SizedBox.shrink();
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final cursor = value.selection.baseOffset;
        if (cursor < 0 || cursor > value.text.length) {
          return const SizedBox.shrink();
        }
        final before = value.text.substring(0, cursor);
        final match = _trigger.firstMatch(before);
        if (match == null) return const SizedBox.shrink();
        final needle = match.group(1)!.toLowerCase();
        final matches = <ConversationMember>[];
        for (final member in members) {
          if (member.accountId == ownAccountId) continue;
          final handle = member.username;
          if (handle == null || handle.isEmpty) continue;
          final displayName =
              profiles?.account(member.accountId)?.name?.toLowerCase() ?? '';
          if (needle.isEmpty ||
              handle.toLowerCase().contains(needle) ||
              displayName.contains(needle)) {
            matches.add(member);
            if (matches.length == 5) break;
          }
        }
        if (matches.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        return Padding(
          key: const Key('composer-mention-suggestions'),
          padding: const EdgeInsets.fromLTRB(
            BoneSpacing.md,
            BoneSpacing.xs,
            BoneSpacing.md,
            0,
          ),
          child: SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: matches.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(width: BoneSpacing.xs),
              itemBuilder: (context, index) {
                final member = matches[index];
                final handle = member.username!;
                final display = profiles?.account(member.accountId)?.name;
                return ActionChip(
                  label: Text(
                    display == null ? '@$handle' : '$display (@$handle)',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                  onPressed: () {
                    final atStart = before.lastIndexOf('@');
                    final insertion = '@$handle ';
                    final nextText =
                        value.text.replaceRange(atStart, cursor, insertion);
                    controller.value = TextEditingValue(
                      text: nextText,
                      selection: TextSelection.collapsed(
                        offset: atStart + insertion.length,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Shown above the composer while a reply is being written.
class _ReplyBar extends StatelessWidget {
  const _ReplyBar({required this.preview, required this.onCancel});

  final String preview;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          BoneSpacing.lg, BoneSpacing.sm, BoneSpacing.sm, 0),
      child: Row(
        children: <Widget>[
          Icon(Icons.reply,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: BoneSpacing.sm),
          Expanded(
            child: Text(
              context.l10n.chatReplyingTo(preview),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            tooltip: context.l10n.chatCancelReply,
            onPressed: onCancel,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

/// The ciphertext, drawn honestly: bars where the text would be.
///
/// This replaces the identical lock icon + `Encrypted message` row that used
/// to render in every bubble and turned a thread into a stack of identical
/// grey blocks (`docs/design.md` §2). It degrades correctly — when the
/// mobile MLS path lands, real text replaces the bars in the same bubble and
/// nothing else about the layout moves.
class _RedactedBars extends StatelessWidget {
  const _RedactedBars({
    required this.byteLength,
    required this.contentWidth,
    required this.color,
  });

  final int byteLength;
  final double contentWidth;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fractions = redactedBarFractions(byteLength);
    // Scale the bar height with the text scale so the block keeps the
    // proportions of the text it stands in for at 200% scale.
    final scale = MediaQuery.textScalerOf(context).scale(14.5) / 14.5;
    final barHeight = 10.0 * scale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < fractions.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: 6.0 * scale),
          Container(
            width: math.max(24.0, contentWidth * fractions[i]),
            height: barHeight,
            decoration: BoxDecoration(
              color: color.withValues(alpha: isDark ? 0.20 : 0.16),
              borderRadius: BorderRadius.circular(barHeight / 2),
            ),
          ),
        ],
      ],
    );
  }
}

/// One rounded pill holding the attachment button, the field and send
/// (`docs/design.md` §4), rather than a bordered row of three separate
/// Material controls.

bool get _enterSends =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

class _Composer extends StatelessWidget {
  const _Composer({
    required this.enabled,
    required this.controller,
    required this.busy,
    required this.onSend,
    this.restricted = false,
    this.onEmoji,
    this.onAttach,
    this.attaching = false,
    this.onPasteFiles,
    this.onVoice,
    this.voiceListenable,
    this.onEditLast,
    this.onPoll,
    this.tray,
  });

  /// The files waiting to be sent. Send replaces the mic while there are any,
  /// as it does while there is text.
  final ComposerAttachments? tray;

  final bool enabled;
  final bool restricted;
  final TextEditingController controller;

  /// Opens the emoji picker to insert at the cursor.
  final VoidCallback? onEmoji;

  /// Opens the new-poll dialog; null where polls are unavailable.
  final VoidCallback? onPoll;
  final bool busy;
  final Future<void> Function() onSend;

  /// Picks and sends a file; null where attachments are unavailable.
  final VoidCallback? onAttach;
  final bool attaching;

  /// Ctrl+V attaches files or an image from the clipboard (desktop); the
  /// result is false when it held none.
  final Future<bool> Function()? onPasteFiles;

  /// Starts a voice note; null where attachments are unavailable. The
  /// button is disabled while [voiceListenable] (the recorder) is recording.
  final VoidCallback? onVoice;
  final VoiceRecorderController? voiceListenable;

  /// Up in an empty field edits the newest own message.
  final VoidCallback? onEditLast;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable:
          Listenable.merge(<Listenable>[controller, if (tray != null) tray!]),
      builder: (context, _) => _build(context, controller.text),
    );
  }

  /// Desktop input extras around the field: Enter to send, paste of files,
  /// Up to edit.
  Widget _wrapDesktopInput(Widget field, {required bool canSend}) {
    final paste = onPasteFiles;
    final editLast = onEditLast;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        // On desktop, Enter sends and Shift+Enter starts a new line. While an
        // IME is composing, Enter confirms the candidate instead, so the key
        // is left to the text field and the draft is not sent.
        if (_enterSends &&
            const SingleActivator(LogicalKeyboardKey.enter)
                .accepts(event, HardwareKeyboard.instance)) {
          final composing = controller.value.composing;
          if (composing.isValid && !composing.isCollapsed) {
            return KeyEventResult.ignored;
          }
          if (canSend) onSend();
          return KeyEventResult.handled;
        }
        if (editLast != null &&
            event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowUp &&
            controller.text.isEmpty) {
          editLast();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: paste == null
          ? field
          : PasteFilesInterceptor(onPaste: paste, child: field),
    );
  }

  /// The one + that holds what else a message can be: a file or a poll
  /// (U29). It keeps the reasons the two used to show on their own buttons.
  Widget _addButton(BuildContext context) {
    final l10n = context.l10n;
    if (restricted) {
      return IconButton(
        key: const Key('composer-add'),
        onPressed: null,
        icon: const Icon(Icons.add),
        tooltip: l10n.chatPostingRestricted,
      );
    }
    if (onAttach == null && onPoll == null) {
      // Attachments need the MLS path (demo builds); elsewhere the control
      // stays visible but disabled, and the reason is reachable by focus,
      // tap and screen reader.
      return GatedExplanation(
        message: l10n.gatedAttachmentsUnavailable,
        child: const IconButton(
          key: Key('composer-add'),
          onPressed: null,
          icon: Icon(Icons.add),
        ),
      );
    }
    return IconButton(
      key: const Key('composer-add'),
      onPressed: enabled && !attaching ? () => _openAddSheet(context) : null,
      icon: attaching
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.add),
      tooltip: attaching ? l10n.chatSendingFile : l10n.chatAddTooltip,
    );
  }

  Future<void> _openAddSheet(BuildContext context) async {
    final l10n = context.l10n;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              key: const Key('composer-add-file'),
              enabled: onAttach != null,
              leading: const Icon(Icons.attach_file),
              title: Text(l10n.chatAttachFile),
              subtitle: onAttach == null
                  ? Text(l10n.gatedAttachmentsUnavailable)
                  : null,
              onTap: onAttach == null
                  ? null
                  : () => Navigator.of(sheetContext).pop('file'),
            ),
            if (onPoll != null)
              ListTile(
                key: const Key('composer-add-poll'),
                enabled: !busy,
                leading: const Icon(Icons.poll_outlined),
                title: Text(l10n.pollComposerTitle),
                onTap: () => Navigator.of(sheetContext).pop('poll'),
              ),
          ],
        ),
      ),
    );
    if (choice == 'file') {
      onAttach?.call();
    } else if (choice == 'poll') {
      onPoll?.call();
    }
  }

  Widget _build(BuildContext context, String text) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final length = text.trim().length;
    final nearLimit = length > maxAppTextLength * 0.9;
    final overLimit = length > maxAppTextLength;
    final canSend = enabled && !restricted && !busy && !overLimit;
    // The mic and Send share one place (U29): the mic while there is nothing
    // to send, Send from the first character or file on. Where voice notes
    // are unavailable, Send is always there.
    final showMic = onVoice != null &&
        voiceListenable != null &&
        !restricted &&
        !busy &&
        text.trim().isEmpty &&
        !(tray?.isNotEmpty ?? false);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          BoneSpacing.md,
          BoneSpacing.sm,
          BoneSpacing.md,
          BoneSpacing.md,
        ),
        child: Container(
          padding: const EdgeInsets.all(BoneSpacing.xs),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(BoneRadii.pill),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              _addButton(context),
              Expanded(
                child: _wrapDesktopInput(
                    canSend: canSend,
                    TextField(
                      controller: controller,
                      enabled: enabled && !restricted,
                      minLines: 1,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      textCapitalization: TextCapitalization.sentences,
                      style: theme.textTheme.bodyMedium,
                      // The field's own fill and border are cleared: the pill
                      // around it is the input surface now, and the theme's
                      // `inputDecorationTheme` would otherwise draw a rounded box
                      // inside a rounded box.
                      decoration: InputDecoration(
                        prefixIcon: restricted
                            ? Icon(
                                Icons.lock_outline,
                                size: 20,
                                color: scheme.onSurfaceVariant,
                              )
                            : null,
                        hintText: restricted
                            ? context.l10n.chatPostingRestricted
                            : context.l10n.chatComposerHint,
                        filled: false,
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: BoneSpacing.xs,
                          vertical: 12,
                        ),
                        hintStyle: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        // Silent only until the draft nears the limit; past it
                        // the count turns into an error and Send disables.
                        // Nothing is truncated, so a long paste is never lost.
                        counterText: nearLimit
                            ? context.l10n
                                .chatComposerCounter(length, maxAppTextLength)
                            : null,
                        counterStyle: overLimit
                            ? theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.error)
                            : theme.textTheme.bodySmall,
                        errorText: overLimit
                            ? context.l10n.validationMessageTooLong
                            : null,
                      ),
                    )),
              ),
              if (onEmoji != null)
                IconButton(
                  key: const Key('composer-emoji'),
                  onPressed: enabled && !restricted ? onEmoji : null,
                  icon: const Icon(Icons.sentiment_satisfied_outlined),
                  tooltip: context.l10n.chatInsertEmoji,
                ),
              const SizedBox(width: BoneSpacing.xs),
              if (showMic)
                ListenableBuilder(
                  listenable: voiceListenable!,
                  builder: (context, _) => IconButton.filled(
                    key: const Key('composer-mic'),
                    onPressed: enabled && !voiceListenable!.isRecording
                        ? onVoice
                        : null,
                    icon: const Icon(Icons.mic_none),
                    tooltip: context.l10n.voiceNoteRecord,
                  ),
                )
              else
                IconButton.filled(
                  onPressed: canSend ? () => onSend() : null,
                  icon: busy
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.send),
                  tooltip: context.l10n.attachmentSend,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when an encryption update for this conversation failed for good
/// (I34): the server refused it or this device could not send it. The
/// update stays queued so later messages cannot overtake it, and sending
/// here waits until the person tries it again or discards it (D134).
class _PausedConversationNotice extends StatelessWidget {
  const _PausedConversationNotice({
    required this.state,
    required this.conversationId,
  });

  final AppState state;
  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = state.isBusy(Ops.mlsUpdate);
    // The update as the last outbox pass found it: Discard acts on that one
    // only, and is not offered for a group's first update (D134).
    final paused = state.pausedMlsUpdate(conversationId);
    final discardable = paused?.discardable ?? false;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const ValueKey('mls-paused-notice'),
        width: double.infinity,
        color: scheme.errorContainer,
        padding: const EdgeInsets.symmetric(
          horizontal: BoneSpacing.gutter,
          vertical: BoneSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              discardable
                  ? context.l10n.chatPausedNotice
                  : context.l10n.chatPausedNoticeRetryOnly,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            Wrap(
              spacing: BoneSpacing.sm,
              children: <Widget>[
                TextButton(
                  key: const ValueKey('mls-paused-retry'),
                  onPressed: busy ? null : () => _retry(context),
                  child: Text(context.l10n.bannerTryAgain),
                ),
                if (discardable)
                  TextButton(
                    key: const ValueKey('mls-paused-discard'),
                    onPressed: busy
                        ? null
                        : () => _discard(context, paused!.idempotencyKey),
                    child: Text(context.l10n.chatPausedDiscard),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _retry(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await state.retryMlsUpdate(conversationId);
    _showError(messenger);
  }

  Future<void> _discard(BuildContext context, String idempotencyKey) async {
    final messenger = ScaffoldMessenger.of(context);
    final note = context.l10n.chatPausedRoleChangeNotMade;
    final outcome =
        await state.discardMlsUpdate(conversationId, idempotencyKey);
    if (outcome == MlsUpdateDiscard.roleChangeNotMade) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(note)));
      return;
    }
    _showError(messenger);
  }

  void _showError(ScaffoldMessengerState messenger) {
    final error = state.errorFor(Ops.mlsUpdate);
    if (error == null) return;
    state.clearError(Ops.mlsUpdate);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error)));
  }
}

/// C1 prerequisite 1: this conversation's own encryption update could not
/// be applied, so only it is paused. Nothing was skipped, other
/// conversations keep syncing, and the user may retry or leave.
class _SyncPausedNotice extends StatelessWidget {
  const _SyncPausedNotice({required this.state, required this.conversationId});

  final AppState state;
  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pause = state.conversationPauseFor(conversationId);
    final choices = pause?.choices ?? const <SyncRecoveryChoice>[];
    // Messages that are only waiting for a confirmation are calm (U17): a
    // neutral strip with an amber icon. A paused conversation that needs a
    // choice keeps the error tone.
    final held = pause?.held == true;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const ValueKey('sync-paused-notice'),
        width: double.infinity,
        color: held ? scheme.surfaceContainerHigh : scheme.errorContainer,
        padding: const EdgeInsets.symmetric(
          horizontal: BoneSpacing.gutter,
          vertical: BoneSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (held)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.schedule,
                      size: 18, color: VeritraStateColors.of(context).warning),
                  const SizedBox(width: BoneSpacing.md),
                  Expanded(
                    child: Text(
                      context.l10n.chatSyncHeldNotice,
                      style: TextStyle(color: scheme.onSurface),
                    ),
                  ),
                ],
              )
            else
              Text(
                context.l10n.chatSyncPausedNotice,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            Wrap(
              spacing: BoneSpacing.sm,
              children: <Widget>[
                if (choices.contains(SyncRecoveryChoice.retry))
                  TextButton(
                    key: const ValueKey('sync-paused-retry'),
                    onPressed: state.busy
                        ? null
                        : () => state.retryConversationPause(conversationId),
                    child: Text(context.l10n.bannerTryAgain),
                  ),
                if (choices.contains(SyncRecoveryChoice.leaveConversation))
                  TextButton(
                    key: const ValueKey('sync-paused-leave'),
                    onPressed: state.busy ? null : () => _confirmLeave(context),
                    child: Text(context.l10n.detailsLeave),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLeave(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.detailsLeaveTitle),
        content: Text(context.l10n.detailsLeaveMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.detailsLeaveConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final left = await state.leaveConversation(conversationId);
    final error = state.errorFor(Ops.members);
    if (!left && error != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }
}

/// K0 step 8: a recovered device no one can add back to this conversation
/// reads its history but cannot send. It shows in place of the composer.
class _NoPeerReadOnlyNotice extends StatelessWidget {
  const _NoPeerReadOnlyNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey('no-peer-read-only'),
        width: double.infinity,
        color: scheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(
          horizontal: BoneSpacing.gutter,
          vertical: BoneSpacing.md,
        ),
        child: SafeArea(
          top: false,
          child: Row(
            children: <Widget>[
              Icon(Icons.lock_clock_outlined, color: scheme.onSurfaceVariant),
              const SizedBox(width: BoneSpacing.md),
              Expanded(
                child: Text(
                  context.l10n.chatNoPeerReadOnly,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sends wait for a removed member's MLS commit (D68).
class _RemovalHoldNotice extends StatelessWidget {
  const _RemovalHoldNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        color: scheme.secondaryContainer,
        padding: const EdgeInsets.symmetric(
          horizontal: BoneSpacing.gutter,
          vertical: BoneSpacing.sm,
        ),
        child: Text(
          context.l10n.chatRemovalHoldNotice,
          style: TextStyle(color: scheme.onSecondaryContainer),
        ),
      ),
    );
  }
}

/// One line naming an attachment message's files, for previews and pending
/// bubbles.
String _attachmentSummary(
  AppLocalizations l10n,
  LocalMessage message,
  String conversationId,
) {
  final entries = AttachmentEntry.listFromBody(message.body,
      conversationId: conversationId);
  if (entries.isEmpty) return l10n.chatAttachment;
  final first = entries.first.fileName;
  return entries.length == 1
      ? l10n.chatAttachmentOne(first)
      : l10n.chatAttachmentMany(first, entries.length - 1);
}

/// C7: the line a channel shows where its history setting changed
/// (decision 1). Local only, never sent.
class _HistoryLine extends StatelessWidget {
  const _HistoryLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
